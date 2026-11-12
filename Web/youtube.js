/*
 * ScrollGuard filter for m.youtube.com: YouTube without Shorts.
 *
 * Installed by YouTubeModel.swift at document start. Two placeholders are filled in before:
 *   the switches (SG_CONFIG), as an object: { hideShorts }
 *   the stylesheet (SG_CSS): youtube.css, as a string
 *
 * What it does:
 *   - hides the Shorts entry of the bottom bar, Shorts shelves, and every card that opens a
 *     Short, wherever they appear (home, search, a channel, under a video);
 *   - refuses navigation to /shorts/...: a tap on a Short goes nowhere, and a page that still
 *     ends up there is left again.
 * A normal video is never touched, however short it is: only links to /shorts/ count.
 */
(function () {
  'use strict';
  var cfg = __SG_CONFIG__; // { hideShorts }
  var css = __SG_CSS__;
  var root = document.documentElement;

  if (window.__scrollGuard) return;

  function post(message) {
    try {
      window.webkit.messageHandlers.scrollGuard.postMessage(message);
    } catch (error) { /* not inside the app */ }
  }

  /** /shorts/ and anything under it: the Shorts viewer. Nothing else. */
  function isShortsPath(pathname) {
    return /^\/shorts(\/|$)/i.test(pathname || '');
  }

  function isShortsLink(href) {
    if (!href) return false;
    try {
      var url = new URL(href, location.href);
      return /(^|\.)youtube\.com$/i.test(url.hostname) && isShortsPath(url.pathname);
    } catch (error) {
      return false;
    }
  }

  /** A channel's Shorts tab: /@name/shorts, /channel/<id>/shorts, /c/<name>/shorts. */
  function isChannelShortsTab(href) {
    if (!href) return false;
    try {
      var url = new URL(href, location.href);
      return /^\/(@[^/]+|channel\/[^/]+|c\/[^/]+|user\/[^/]+)\/shorts\/?$/i.test(url.pathname);
    } catch (error) {
      return false;
    }
  }

  // The elements of m.youtube.com that hold one card. A Shorts link inside one of these hides
  // the card; a link anywhere else hides only the link.
  var CARD = [
    'ytm-shorts-lockup-view-model', 'ytm-shorts-lockup-view-model-v2', 'ytm-reel-item-renderer',
    'ytm-video-with-context-renderer', 'ytm-compact-video-renderer', 'ytm-rich-item-renderer',
    'ytm-media-item', 'ytm-item-section-renderer > div > ytm-video-with-context-renderer'
  ].join(',');
  // Rows of cards. A row is hidden whole when every video in it is a Short.
  var SHELF = 'ytm-reel-shelf-renderer,ytm-rich-section-renderer,ytm-shelf-renderer,ytm-horizontal-card-list-renderer';
  // The bottom bar's entries, and a channel's tab strip.
  var NAV = 'ytm-pivot-bar-item-renderer,ytm-pivot-bar-item,ytm-c4-tabbed-header-renderer a,ytm-tab-renderer,.tab-content a';

  function mark(element, why) {
    if (!element || element.hasAttribute('data-sg-hidden')) return 0;
    element.setAttribute('data-sg-hidden', why);
    return 1;
  }

  function textOf(element) {
    return (element.textContent || '').replace(/\s+/g, ' ').trim();
  }

  function hideShelves(scope) {
    var count = 0;
    var shelves = scope.querySelectorAll(SHELF);
    for (var i = 0; i < shelves.length; i++) {
      var shelf = shelves[i];
      if (shelf.hasAttribute('data-sg-hidden')) continue;
      var shorts = shelf.querySelectorAll('a[href^="/shorts/"]').length;
      if (!shorts) continue;
      var watch = shelf.querySelectorAll('a[href^="/watch"],a[href^="/playlist"]').length;
      if (watch === 0) count += mark(shelf, 'shelf');
    }
    return count;
  }

  function hideNav(scope) {
    var count = 0;
    var items = scope.querySelectorAll(NAV);
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      if (item.hasAttribute('data-sg-hidden')) continue;
      var link = item.matches('a') ? item : item.querySelector('a');
      var href = link ? link.getAttribute('href') : null;
      // The Shorts entry: its link goes to /shorts, or (bottom bar, no link) it says "Shorts".
      if ((href && (isShortsLink(href) || isChannelShortsTab(href))) || (!href && /^shorts$/i.test(textOf(item)))) {
        count += mark(item, 'nav');
      }
    }
    return count;
  }

  function hideCards(scope) {
    var count = 0;
    var links = scope.querySelectorAll('a[href^="/shorts/"]');
    for (var i = 0; i < links.length; i++) {
      var link = links[i];
      if (link.closest('[data-sg-hidden]')) continue;
      var card = link.closest(CARD);
      count += mark(card || link, card ? 'card' : 'link');
    }
    return count;
  }

  function scan() {
    if (!cfg.hideShorts) {
      root.removeAttribute('data-sg-hide');
      return 0;
    }
    root.setAttribute('data-sg-hide', '');
    var count = hideNav(document) + hideShelves(document) + hideCards(document);
    if (count > 0) post({ t: 'hidden', n: count, path: location.pathname });
    return count;
  }

  var scanTimer = null;
  function scheduleScan() {
    if (scanTimer) return;
    scanTimer = setTimeout(function () {
      scanTimer = null;
      scan();
    }, 120);
  }

  // --- Navigation ---

  var lastPath = null;
  function leaveShorts(via) {
    post({ t: 'blocked', path: location.pathname, via: via });
    if (history.length > 1) history.back();
    else location.replace('/');
  }

  function onRouteChange(via) {
    var path = location.pathname;
    if (path === lastPath) return;
    lastPath = path;
    post({ t: 'route', path: path, via: via });
    if (cfg.hideShorts && isShortsPath(path)) leaveShorts(via);
    scheduleScan();
  }

  function patchHistory(name) {
    var original = history[name];
    if (typeof original !== 'function') return;
    history[name] = function () {
      var result = original.apply(this, arguments);
      onRouteChange(name);
      return result;
    };
  }
  patchHistory('pushState');
  patchHistory('replaceState');
  window.addEventListener('popstate', function () { onRouteChange('pop'); });
  setInterval(function () { onRouteChange('poll'); }, 500);

  // A tap on a Short, wherever it was missed by the filter: stopped before YouTube sees it.
  document.addEventListener('click', function (event) {
    if (!cfg.hideShorts) return;
    var link = event.target && event.target.closest ? event.target.closest('a[href]') : null;
    if (!link || !isShortsLink(link.getAttribute('href'))) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    post({ t: 'blocked', path: '/shorts/', via: 'tap' });
  }, true);

  // --- Set-up ---

  function installStyle() {
    var style = document.createElement('style');
    style.id = 'sg-style';
    style.textContent = css;
    (document.head || root).appendChild(style);
  }

  function configure(next) {
    cfg = next || cfg;
    if (!cfg.hideShorts) {
      var marked = document.querySelectorAll('[data-sg-hidden]');
      for (var i = 0; i < marked.length; i++) marked[i].removeAttribute('data-sg-hidden');
    }
    scan();
  }

  function snapshot() {
    return 'youtube ' + location.pathname + ' hidden=' + document.querySelectorAll('[data-sg-hidden]').length;
  }

  Object.defineProperty(window, '__scrollGuard', {
    value: Object.freeze({ isShortsPath: isShortsPath, configure: configure, scan: scan, snapshot: snapshot }),
    writable: false, configurable: false
  });

  installStyle();
  if (cfg.hideShorts) root.setAttribute('data-sg-hide', '');
  onRouteChange('load');

  function start() {
    new MutationObserver(function () { scheduleScan(); })
      .observe(document.body || root, { childList: true, subtree: true });
    scan();
    post({ t: 'drawn', path: location.pathname });
  }
  if (document.body) start();
  else document.addEventListener('DOMContentLoaded', start);

  post({ t: 'ready', path: location.pathname });
})();
