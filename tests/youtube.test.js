// Tests for Web/youtube.js, run in jsdom against tests/fixtures/youtube-home.html. Same
// limits as filter.test.js: the filter's own logic, not the live site.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM, VirtualConsole } = require('jsdom');

const root = path.join(__dirname, '..');
const filterSource = fs.readFileSync(path.join(root, 'Web/youtube.js'), 'utf8');
const css = fs.readFileSync(path.join(root, 'Web/youtube.css'), 'utf8');
const homeHTML = fs.readFileSync(path.join(__dirname, 'fixtures/youtube-home.html'), 'utf8');
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const plain = (value) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)));

const openWindows = [];
test.afterEach(() => {
  while (openWindows.length) openWindows.pop().close();
});

function open({ url = 'https://m.youtube.com/', html = homeHTML, config = { hideShorts: true } } = {}) {
  const dom = new JSDOM(html, {
    url, runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole: new VirtualConsole()
  });
  const { window } = dom;
  openWindows.push(window);
  const messages = [];
  window.webkit = { messageHandlers: { scrollGuard: { postMessage: (m) => messages.push(plain(m)) } } };
  window.eval(filterSource.replace('__SG_CONFIG__', JSON.stringify(config)).replace('__SG_CSS__', JSON.stringify(css)));
  return { window, document: window.document, messages };
}

function isHidden(document, id) {
  const element = document.getElementById(id);
  assert.ok(element, `fixture has #${id}`);
  return document.documentElement.hasAttribute('data-sg-hide') && element.closest('[data-sg-hidden]') !== null;
}

const KEPT = ['video-long', 'video-45s', 'mixed-watch', 'playlist', 'video-last', 'grid', 'mixed-shelf',
  'tab-videos', 'tab-playlists', 'pivot-home', 'pivot-subs', 'pivot-library', 'bar'];
const HIDDEN = ['shorts-shelf', 'short-1', 'short-2', 'mixed-short', 'tab-shorts', 'pivot-shorts'];

test('isShortsPath: only /shorts/ is the Shorts viewer', () => {
  const page = open();
  const { isShortsPath } = page.window.__scrollGuard;
  for (const p of ['/shorts', '/shorts/', '/shorts/abc123', '/SHORTS/abc']) assert.equal(isShortsPath(p), true, p);
  for (const p of ['/', '/watch?v=abc', '/@someone/shorts', '/feed/subscriptions', '/results?search_query=shorts',
    '/shortsfan', '/playlist?list=x']) assert.equal(isShortsPath(p), false, p);
});

test('Shorts shelf, cards, channel tab and bar entry are hidden; every normal item stays', async () => {
  const page = open();
  await sleep(250);
  for (const id of HIDDEN) assert.equal(isHidden(page.document, id), true, `${id} hidden`);
  for (const id of KEPT) assert.equal(isHidden(page.document, id), false, `${id} kept`);
  // A mixed row loses only its Short, not the row.
  assert.equal(page.document.getElementById('mixed-short').getAttribute('data-sg-hidden'), 'card');
  assert.equal(page.document.getElementById('pivot-shorts').getAttribute('data-sg-hidden'), 'nav');
  assert.equal(page.document.getElementById('shorts-shelf').getAttribute('data-sg-hidden'), 'shelf');
});

test('with the switch off nothing is hidden, and switching it on later hides again', async () => {
  const page = open({ config: { hideShorts: false } });
  await sleep(250);
  for (const id of HIDDEN.concat(KEPT)) assert.equal(isHidden(page.document, id), false, id);
  page.window.__scrollGuard.configure({ hideShorts: true });
  for (const id of HIDDEN) assert.equal(isHidden(page.document, id), true, id);
  page.window.__scrollGuard.configure({ hideShorts: false });
  assert.equal(page.document.querySelectorAll('[data-sg-hidden]').length, 0);
});

test('a Shorts card added later (more results) is hidden; a video added later is not', async () => {
  const page = open();
  await sleep(250);
  const grid = page.document.getElementById('grid');
  grid.insertAdjacentHTML('beforeend', `
    <ytm-rich-item-renderer id="late-short"><a href="/shorts/s9s9s9s9s9s">Late short</a></ytm-rich-item-renderer>
    <ytm-rich-item-renderer id="late-video"><a href="/watch?v=eeeeeeeeeee">Late video</a></ytm-rich-item-renderer>`);
  await sleep(300);
  assert.equal(isHidden(page.document, 'late-short'), true);
  assert.equal(isHidden(page.document, 'late-video'), false);
});

test('a tap on a Shorts link is stopped and reported; a tap on a video is not', async () => {
  const page = open();
  await sleep(250);
  const tap = (id) => {
    const event = new page.window.MouseEvent('click', { bubbles: true, cancelable: true });
    page.document.querySelector(`#${id} a`).dispatchEvent(event);
    return event;
  };
  assert.equal(tap('short-1').defaultPrevented, true);
  assert.equal(tap('video-long').defaultPrevented, false);
  assert.equal(page.messages.filter((m) => m.t === 'blocked' && m.via === 'tap').length, 1);
});

test('arriving on /shorts/ by in-page navigation is reported as blocked', async () => {
  const page = open();
  await sleep(100);
  page.window.history.pushState({}, '', '/shorts/s1s1s1s1s1s');
  assert.ok(page.messages.some((m) => m.t === 'blocked' && m.via === 'pushState'));
  page.window.history.pushState({}, '', '/watch?v=aaaaaaaaaaa');
  assert.equal(page.messages.filter((m) => m.t === 'blocked').length, 1);
});

test('the count on the bell is reported once, and again when it changes', async () => {
  const page = open();
  await sleep(250);
  const bells = () => page.messages.filter((m) => m.t === 'bell').map((m) => m.n);
  assert.deepEqual(bells(), [3]);
  page.document.getElementById('bell-count').textContent = '5';
  await sleep(1700);
  assert.deepEqual(bells(), [3, 5]);
  // The bell itself is never hidden: it is not a Short.
  assert.equal(isHidden(page.document, 'bell'), false);
});
