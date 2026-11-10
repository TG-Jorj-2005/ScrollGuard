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

const ALL_ON = { hideReels: true, blockReelsFeed: true, clipsAsPosts: true };
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

test('a tap on a clip is turned into its post page', async () => {
  const page = open();
  await sleep(50);
  const event = tap(page.window, 'clip-link');
  assert.equal(event.defaultPrevented, true);
  assert.deepEqual(page.messages.filter((m) => m.t === 'rewrite'), [
    { t: 'rewrite', path: '/reel/CLIP1234567/', via: 'tap' }
  ]);
  page.close();
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
  assert.equal(page.messages.filter((m) => m.t === 'blocked' || m.t === 'rewrite').length, 0);
  page.close();
});

test('with every switch off, nothing is hidden, stopped or rewritten', async () => {
  const page = open({ config: { hideReels: false, blockReelsFeed: false, clipsAsPosts: false } });
  await sleep(250);
  assert.equal(page.document.documentElement.hasAttribute('data-sg-hide'), false);
  assert.equal(tap(page.window, 'reels-tab-link').defaultPrevented, false);
  assert.equal(tap(page.window, 'clip-link').defaultPrevented, false);
  page.window.history.pushState({}, '', '/reels/');
  await sleep(30);
  assert.equal(page.window.location.pathname, '/reels/');
  assert.equal(page.messages.filter((m) => m.t === 'blocked' || m.t === 'rewrite' || m.t === 'hidden').length, 0);
  page.close();
});

test('turning a switch off and on again updates the page without a reload', async () => {
  const page = open();
  await sleep(250);
  assert.equal(isHidden(page.document, 'tab-reels'), true);

  page.window.__scrollGuard.configure({ hideReels: false, blockReelsFeed: true, clipsAsPosts: true });
  assert.equal(isHidden(page.document, 'tab-reels'), false);
  assert.equal(isHidden(page.document, 'reels-shelf'), false);

  page.window.__scrollGuard.configure(ALL_ON);
  assert.equal(isHidden(page.document, 'tab-reels'), true);
  assert.equal(isHidden(page.document, 'reels-shelf'), true);
  page.close();
});

test('a clip that the site sends back from /p/ to /reel/ is then left alone (no ping-pong)', async () => {
  const page = open({ url: 'https://www.instagram.com/p/CLIP1234567/' });
  await sleep(30);
  // The filter rewrote this clip a moment ago (recorded before the page load it caused).
  page.window.sessionStorage.setItem('sg-rewrites', JSON.stringify({ CLIP1234567: Date.now() }));
  // Instagram's own script now moves the page back to the reel URL.
  page.window.history.replaceState({}, '', '/reel/CLIP1234567/');
  await sleep(50);
  assert.equal(page.window.location.pathname, '/reel/CLIP1234567/');
  assert.equal(page.messages.filter((m) => m.t === 'rewrite').length, 0);
  assert.equal(JSON.parse(page.window.sessionStorage.getItem('sg-bounced')).CLIP1234567, 1);
  page.close();
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
