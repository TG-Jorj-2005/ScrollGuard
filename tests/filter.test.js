// Tests for Web/instagram.js, run in jsdom against tests/fixtures. They check the filter's own
// logic. They cannot tell whether the real instagram.com still has the shapes the fixture
// assumes: that is checked on the iPhone (the app's Diagnostics screen).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM, VirtualConsole } = require('jsdom');

const root = path.join(__dirname, '..');
const filterSource = fs.readFileSync(path.join(root, 'Web/instagram.js'), 'utf8');
const css = fs.readFileSync(path.join(root, 'Web/instagram.css'), 'utf8');
const feedHTML = fs.readFileSync(path.join(__dirname, 'fixtures/feed.html'), 'utf8');

const ALL_ON = { hideReels: true, blockReelsFeed: true, singleClip: true };
const ALL_OFF = { hideReels: false, blockReelsFeed: false, singleClip: false };

// A stand-in for the page of one opened clip: a video that fills the screen, and a comments
// sheet over it.
const clipHTML = `<!doctype html><html><head></head><body>
  <div id="viewer"><div id="item"><video id="clip"></video><button id="like">Like</button></div></div>
  <div id="sheet" role="dialog"><p id="comment">a comment</p></div>
</body></html>`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Every page a test opened is closed after it, pass or fail: the filter's timers would otherwise
// keep the test process alive.
const openWindows = [];
test.afterEach(() => {
  while (openWindows.length) openWindows.pop().close();
});

/** Plain copy of a value made inside the page, so it compares equal to one made here. */
const plain = (value) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)));

/** Loads the fixture at `url` and runs the filter in it, with the app's message handler faked. */
function open({ url = 'https://www.instagram.com/', html = feedHTML, config = ALL_ON } = {}) {
  // A silent console: jsdom cannot load another page and says so each time the filter asks.
  const dom = new JSDOM(html, {
    url, runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole: new VirtualConsole()
  });
  const { window } = dom;
  openWindows.push(window);
  const messages = [];
  window.webkit = { messageHandlers: { scrollGuard: { postMessage: (m) => messages.push(plain(m)) } } };
  const source = filterSource
    .replace('__SG_CONFIG__', JSON.stringify(config))
    .replace('__SG_CSS__', JSON.stringify(css));
  window.eval(source);
  return { window, document: window.document, messages, close: () => {} };
}

function isHidden(document, id) {
  const element = document.getElementById(id);
  assert.ok(element, `fixture has #${id}`);
  return document.documentElement.hasAttribute('data-sg-hide') && element.closest('[data-sg-hidden]') !== null;
}

function tap(window, id) {
  const event = new window.MouseEvent('click', { bubbles: true, cancelable: true });
  window.document.getElementById(id).dispatchEvent(event);
  return event;
}

test('classify: which paths are the Reels viewer, a single clip, or neither', () => {
  const page = open();
  const classify = page.window.__scrollGuard.classify;
  const cases = [
    ['/reels/', { kind: 'feed' }],
    ['/reels', { kind: 'feed' }],
    ['/REELS/', { kind: 'feed' }],
    ['/reels/audio/123456789/', { kind: 'feed' }],
    ['/reels/audio/', { kind: 'feed' }],
    ['/reel/', { kind: 'feed' }],
    ['/reels/Cabc123_-XY/', { kind: 'clip', id: 'Cabc123_-XY' }],
    ['/reel/Cabc123_-XY/', { kind: 'clip', id: 'Cabc123_-XY' }],
    ['/reel/Cabc123_-XY', { kind: 'clip', id: 'Cabc123_-XY' }],
    ['/', null],
    ['/p/Cabc123_-XY/', null],
    ['/explore/', null],
    ['/direct/inbox/', null],
    ['/accounts/login/', null],
    ['/alice/', null],
    ['/alice/reels/', null],
    ['/reelsfan/', null],
    ['/stories/alice/123/', null]
  ];
  for (const [input, expected] of cases) {
    assert.deepEqual(plain(classify(input)), expected, input);
  }
  page.close();
});

test('the Reels tab leaves the navigation bar; the other tabs stay', async () => {
  const page = open();
  await sleep(250);
  assert.equal(isHidden(page.document, 'tab-reels'), true);
  for (const id of ['tab-home', 'tab-search', 'tab-messages', 'tab-profile']) {
    assert.equal(isHidden(page.document, id), false, id);
  }
  assert.equal(page.document.getElementById('tab-reels').getAttribute('data-sg-hidden'), 'nav');
  page.close();
});

test('a suggested-reels shelf is hidden; posts are not, including a post that is a clip', async () => {
  const page = open();
  await sleep(250);
  assert.equal(isHidden(page.document, 'reels-shelf'), true);
  for (const id of ['photo-post', 'clip-post', 'last-post', 'feed']) {
    assert.equal(isHidden(page.document, id), false, id);
  }
  const hidden = page.messages.filter((m) => m.t === 'hidden').reduce((sum, m) => sum + m.n, 0);
  assert.equal(hidden, 2, 'the tab slot and the shelf, each counted once');
  page.close();
});

test('content added later (infinite scroll) is filtered too', async () => {
  const page = open();
  await sleep(250);
  const shelf = page.document.createElement('div');
  shelf.id = 'late-shelf';
  shelf.innerHTML = '<div><a href="/reels/LATE1234567/">late</a></div>';
  const post = page.document.createElement('article');
  post.id = 'late-post';
  post.innerHTML = '<a href="/p/LATE7654321/">late post</a>';
  page.document.getElementById('feed').append(shelf, post);
  await sleep(300);
  assert.equal(isHidden(page.document, 'late-shelf'), true);
  assert.equal(isHidden(page.document, 'late-post'), false);
  page.close();
});

test('a tap on the Reels tab is stopped and reported; other taps go through', async () => {
  const page = open();
  await sleep(50);
  const blocked = tap(page.window, 'reels-tab-link');
  assert.equal(blocked.defaultPrevented, true);
  assert.deepEqual(page.messages.filter((m) => m.t === 'blocked'), [{ t: 'blocked', path: '/reels/', via: 'tap' }]);

  const allowed = tap(page.window, 'messages-link');
  assert.equal(allowed.defaultPrevented, false);
  page.close();
});

test('a tap on a clip goes through: a single clip is allowed to open', async () => {
  const page = open();
  await sleep(50);
  const event = tap(page.window, 'clip-link');
  assert.equal(event.defaultPrevented, false);
  assert.equal(page.messages.filter((m) => m.t === 'blocked').length, 0);
});

/** Opens the page of one clip, with a video that fills the 768-point-high test screen. */
function openClip({ url = 'https://www.instagram.com/reel/CLIP1234567/', config = ALL_ON, videoHeight = 700 } = {}) {
  const page = open({ url, html: clipHTML, config });
  page.document.getElementById('clip').getBoundingClientRect = () => (
    { top: 0, left: 0, right: 400, bottom: videoHeight, width: 400, height: videoHeight }
  );
  return page;
}

/** A finger going down on #id and moving by (dx, dy). Returns the move event. */
function swipe(page, id, dx, dy) {
  const target = page.document.getElementById(id);
  const fire = (type, x, y) => {
    const event = new page.window.Event(type, { bubbles: true, cancelable: true });
    Object.defineProperty(event, 'touches', { value: type === 'touchend' ? [] : [{ clientX: x, clientY: y }] });
    target.dispatchEvent(event);
    return event;
  };
  fire('touchstart', 200, 400);
  const move = fire('touchmove', 200 + dx, 400 + dy);
  fire('touchend', 0, 0);
  return move;
}

/** True when the page's own listener, registered after the filter, got to see the move. */
function pageSawMove(page, action) {
  let seen = false;
  page.document.addEventListener('touchmove', () => { seen = true; }, true);
  action();
  return seen;
}

test('on an opened clip, a swipe up or down is held back and reported once', async () => {
  for (const dy of [-120, 120]) {
    const page = openClip();
    let move;
    const seen = pageSawMove(page, () => { move = swipe(page, 'clip', 5, dy); });
    assert.equal(move.defaultPrevented, true, `the scroll is stopped (dy ${dy})`);
    assert.equal(seen, false, `the page's own swipe handling never sees it (dy ${dy})`);
    assert.deepEqual(page.messages.filter((m) => m.t === 'held'), [{ t: 'held', path: '/reel/CLIP1234567/' }]);
  }
});

test('the same holds for a clip opened at /reels/<id>/, as from a conversation', async () => {
  const page = openClip({ url: 'https://www.instagram.com/reels/CLIP1234567/' });
  assert.equal(swipe(page, 'clip', 0, -150).defaultPrevented, true);
});

test('on an opened clip, taps, horizontal swipes and the comments sheet work as usual', async () => {
  const page = openClip();
  assert.equal(tap(page.window, 'like').defaultPrevented, false, 'a tap');
  assert.equal(swipe(page, 'clip', 150, 10).defaultPrevented, false, 'a horizontal swipe (back)');
  assert.equal(swipe(page, 'comment', 0, -150).defaultPrevented, false, 'scrolling the comments sheet');
  assert.equal(page.messages.filter((m) => m.t === 'held').length, 0);
});

test('swipes are not held back elsewhere: the feed, a post page, a small video', async () => {
  const feed = openClip({ url: 'https://www.instagram.com/' });
  assert.equal(swipe(feed, 'clip', 0, -150).defaultPrevented, false, 'the feed scrolls');

  const post = openClip({ url: 'https://www.instagram.com/p/PHOTO12345/' });
  assert.equal(swipe(post, 'clip', 0, -150).defaultPrevented, false, 'a post page scrolls');

  const small = openClip({ videoHeight: 300 });
  assert.equal(swipe(small, 'clip', 0, -150).defaultPrevented, false, 'a clip page laid out as a post scrolls');
});

test('with "one clip at a time" off, an opened clip scrolls on as on the plain site', async () => {
  const page = openClip({ config: { hideReels: true, blockReelsFeed: true, singleClip: false } });
  assert.equal(swipe(page, 'clip', 0, -150).defaultPrevented, false);
  page.window.__scrollGuard.configure(ALL_ON);
  assert.equal(swipe(page, 'clip', 0, -150).defaultPrevented, true, 'and holds again once switched on');
});

test('in-page navigation to the Reels viewer is reported and left', async () => {
  const page = open();
  await sleep(50);
  page.window.history.pushState({}, '', '/explore/');
  await sleep(30);
  page.window.history.pushState({}, '', '/reels/');
  await sleep(30);
  const blocked = page.messages.filter((m) => m.t === 'blocked');
  assert.deepEqual(blocked, [{ t: 'blocked', path: '/reels/', via: 'pushState' }]);
  await sleep(200); // history.back() is asynchronous
  assert.equal(page.window.location.pathname, '/explore/');
  assert.equal(page.messages.filter((m) => m.t === 'blocked').length, 1, 'no loop');
  page.close();
});

test('in-page navigation between normal pages is never blocked', async () => {
  const page = open();
  await sleep(50);
  for (const target of ['/explore/', '/direct/inbox/', '/alice/', '/p/PHOTO12345/', '/alice/reels/']) {
    page.window.history.pushState({}, '', target);
    await sleep(20);
    assert.equal(page.window.location.pathname, target);
  }
  assert.equal(page.messages.filter((m) => m.t === 'blocked' || m.t === 'held').length, 0);
  page.close();
});

test('with every switch off, nothing is hidden, stopped or held back', async () => {
  const page = open({ config: ALL_OFF });
  await sleep(250);
  assert.equal(page.document.documentElement.hasAttribute('data-sg-hide'), false);
  assert.equal(tap(page.window, 'reels-tab-link').defaultPrevented, false);
  assert.equal(tap(page.window, 'clip-link').defaultPrevented, false);
  page.window.history.pushState({}, '', '/reels/');
  await sleep(30);
  assert.equal(page.window.location.pathname, '/reels/');
  assert.equal(page.messages.filter((m) => m.t === 'blocked' || m.t === 'held' || m.t === 'hidden').length, 0);
  page.close();
});

test('turning a switch off and on again updates the page without a reload', async () => {
  const page = open();
  await sleep(250);
  assert.equal(isHidden(page.document, 'tab-reels'), true);

  page.window.__scrollGuard.configure({ hideReels: false, blockReelsFeed: true, singleClip: true });
  assert.equal(isHidden(page.document, 'tab-reels'), false);
  assert.equal(isHidden(page.document, 'reels-shelf'), false);

  page.window.__scrollGuard.configure(ALL_ON);
  assert.equal(isHidden(page.document, 'tab-reels'), true);
  assert.equal(isHidden(page.document, 'reels-shelf'), true);
  page.close();
});

test('in-page navigation to a single clip is allowed and the page stays on it', async () => {
  const page = open();
  await sleep(50);
  page.window.history.pushState({}, '', '/reel/CLIP1234567/');
  await sleep(100);
  assert.equal(page.window.location.pathname, '/reel/CLIP1234567/');
  assert.equal(page.messages.filter((m) => m.t === 'blocked').length, 0);
});

test('a tab that Instagram draws again is hidden in the same turn, before it can be painted', async () => {
  const page = open();
  await sleep(250);
  // Instagram redraws its bar on a page change: the old one goes, a new one arrives.
  page.document.getElementById('bottom-bar').remove();
  const bar = page.document.createElement('div');
  bar.id = 'new-bar';
  bar.innerHTML = '<div id="new-home"><a href="/">Home</a></div>' +
    '<div id="new-search"><a href="/explore/">Search</a></div>' +
    '<div id="new-reels"><a href="/reels/">Reels</a></div>' +
    '<div id="new-profile"><a href="/me/">Profile</a></div>';
  page.document.body.appendChild(bar);
  // Mutation observers run in the microtask right after the change; a timer would be later.
  await Promise.resolve();
  assert.equal(isHidden(page.document, 'new-reels'), true);
  assert.equal(isHidden(page.document, 'new-home'), false);
});

test('diagnostics: addresses are reduced to shapes, with no names or ids', async () => {
  const page = open();
  const shape = page.window.__scrollGuard.shape;
  const cases = [
    ['/', '/'],
    ['/alice/', '/<name>/'],
    ['/alice/reels/', '/<name>/reels/'],
    ['/alice/tagged/', '/<name>/tagged/'],
    ['/p/PHOTO12345/', '/p/*/'],
    ['/reel/CLIP1234567/', '/reel/*/'],
    ['/reels/', '/reels/'],
    ['/direct/inbox/', '/direct/inbox/'],
    ['/direct/t/340282366841710300949128/', '/direct/t/*/'],
    ['/stories/alice/3141592653/', '/stories/*/*/'],
    ['/accounts/login/?next=%2Falice%2F', '/accounts/login/'],
    ['https://example.com/alice', 'external']
  ];
  for (const [input, expected] of cases) assert.equal(shape(input), expected, input);

  const snapshot = page.window.__scrollGuard.snapshot();
  const parsed = JSON.parse(snapshot);
  assert.equal(parsed.page, '/');
  assert.deepEqual(parsed.links, {
    '/<name>/': 4, '/p/*/': 2, '/reel/*/': 1, '/reels/*/': 2, '/': 1, '/explore/': 1, '/reels/': 1, '/direct/inbox/': 1
  });
  for (const secret of ['alice', 'bob', 'carol', 'PHOTO12345', 'CLIP1234567', 'Suggested']) {
    assert.equal(snapshot.includes(secret), false, `the snapshot must not contain "${secret}"`);
  }
});

test('the filter does nothing on other sites (sign-in passes through facebook.com)', async () => {
  const page = open({ url: 'https://www.facebook.com/reels/' });
  await sleep(100);
  assert.equal(page.window.__scrollGuard, undefined);
  assert.equal(page.messages.length, 0);
  assert.equal(page.document.getElementById('scrollguard-style'), null);
  page.close();
});

test('the stylesheet is injected once and survives the head being rebuilt', async () => {
  const page = open();
  await sleep(50);
  assert.equal(page.document.querySelectorAll('#scrollguard-style').length, 1);
  page.document.getElementById('scrollguard-style').remove();
  page.document.body.appendChild(page.document.createElement('div'));
  await sleep(50);
  assert.equal(page.document.querySelectorAll('#scrollguard-style').length, 1);
  page.close();
});
