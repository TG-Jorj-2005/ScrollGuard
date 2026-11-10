/*
 * ScrollGuard filter for instagram.com.
 *
 * Injected by the app at document start, in the page's own JavaScript world (it has to wrap the
 * page's history functions to see in-page navigation). The app replaces the two placeholders
 * below before injecting.
 *
 * What it does:
 *   1. Hides the Reels entry of the navigation bar and suggested-reels shelves in the feed.
 *   2. Stops taps and in-page navigation that lead to the endless Reels viewer (/reels/).
 *   3. Opens a single clip (/reel/<id>/, /reels/<id>/) as a normal post page (/p/<id>/), which
 *      shows that one clip and nothing to scroll into.
 *
 * Never hidden: posts in the feed (<article>), profiles, messages, search, stories.
 */
(function () {
  'use strict';

  var cfg = __SG_CONFIG__; // { hideReels, blockReelsFeed, clipsAsPosts }
  var css = __SG_CSS__;

  var INSTAGRAM = /(^|\.)instagram\.com$/i;
  if (!INSTAGRAM.test(location.hostname)) return; // sign-in hops through facebook.com: untouched
  if (window.__scrollGuard) return;

  var CLIP_ID = /^[A-Za-z0-9_-]{5,}$/;
  var BOUNCE_WINDOW_MS = 8000;

  function post(message) {
    try {
      window.webkit.messageHandlers.scrollGuard.postMessage(message);
    } catch (e) { /* not inside the app (tests, a desktop browser) */ }
  }

  // The page's first script errors and failed resources go to the app's diagnostics log: with
  // no Mac there is no Web Inspector, and "the page is blank" needs a reason.
  var reportedErrors = 0;
  window.addEventListener('error', function (event) {
    if (reportedErrors >= 8) return;
    reportedErrors++;
    var target = event.target;
    var what;
    if (target && target !== window && (target.src || target.href)) {
      what = 'failed to load ' + String(target.src || target.href).split('?')[0].slice(-90);
    } else {
      var file = event.filename ? ' @ ' + String(event.filename).split('?')[0].slice(-60) + ':' + event.lineno : '';
      what = 'script error: ' + String(event.message || 'unknown').slice(0, 140) + file;
    }
    post({ t: 'log', text: what });
  }, true);

  // ---------------------------------------------------------------- routes

  /**
   * What a path on instagram.com is, as far as Reels go:
   *   null                      nothing to do
   *   { kind: 'feed' }          the endless Reels viewer
   *   { kind: 'clip', id }      one clip, which can be shown as the post page /p/<id>/
   */
  function classify(pathname) {
    var parts = String(pathname).split('/').filter(Boolean);
    if (!parts.length) return null;
    var head = parts[0].toLowerCase();
    if (head === 'reels') {
      if (parts.length === 2 && isClipId(parts[1])) return { kind: 'clip', id: parts[1] };
      return { kind: 'feed' };
    }
    if (head === 'reel') {
      if (parts.length >= 2 && isClipId(parts[1])) return { kind: 'clip', id: parts[1] };
      return { kind: 'feed' };
    }
    return null;
  }

  function isClipId(text) {
    return CLIP_ID.test(text) && text.toLowerCase() !== 'audio';
  }

  // A clip that Instagram sends straight back from /p/<id>/ to /reel/<id>/ is left alone
  // afterwards, so the page can never ping-pong. Kept in sessionStorage: it has to survive the
  // page load that the rewrite itself causes.
  function readStore(key) {
    try { return JSON.parse(sessionStorage.getItem(key)) || {}; } catch (e) { return {}; }
  }
  function writeStore(key, value) {
    try { sessionStorage.setItem(key, JSON.stringify(value)); } catch (e) { /* private mode */ }
  }
  function hasBounced(id) {
    return readStore('sg-bounced')[id] === 1;
  }
  function noteRewrite(id) {
    var rewrites = readStore('sg-rewrites');
    rewrites[id] = Date.now();
    writeStore('sg-rewrites', rewrites);
  }
  /** True when this clip was rewritten moments ago and the site has brought us back to it. */
  function checkBounce(id) {
    var at = readStore('sg-rewrites')[id];
    if (!at || Date.now() - at > BOUNCE_WINDOW_MS) return false;
    var bounced = readStore('sg-bounced');
    bounced[id] = 1;
    writeStore('sg-bounced', bounced);
    post({ t: 'log', text: 'clip ' + id + ' came back from /p/: left as a reel page' });
    return true;
  }

  // ---------------------------------------------------------------- navigation

  var lastPath = location.pathname;
  var previousPath = null; // the page we were on before the current one, inside this document

  /** Acts on the page we are on now. `via`: load, pushState, replaceState, popstate, poll. */
  function enforce(via) {
    var route = classify(location.pathname);
    if (!route) return;

    if (route.kind === 'clip') {
      if (!cfg.clipsAsPosts || hasBounced(route.id) || checkBounce(route.id)) return;
      noteRewrite(route.id);
      post({ t: 'rewrite', path: location.pathname, via: via });
      location.replace('/p/' + route.id + '/');
      return;
    }

    if (!cfg.blockReelsFeed) return;
    post({ t: 'blocked', path: location.pathname, via: via });
    leaveBlockedPage();
  }

  function leaveBlockedPage() {
    var blockedPath = location.pathname;
    if (previousPath !== null && !classify(previousPath) && history.length > 1) {
      history.back();
      // If going back did nothing (no entry to go back to), go home instead.
      setTimeout(function () {
        if (location.pathname === blockedPath) location.replace('/');
      }, 600);
    } else {
      location.replace('/');
    }
  }

  function onRouteChange(via) {
    var path = location.pathname;
    if (path === lastPath) return;
    previousPath = lastPath;
    lastPath = path;
    post({ t: 'route', path: path, via: via });
    enforce(via);
    scheduleScan();
  }

  ['pushState', 'replaceState'].forEach(function (name) {
    var original = history[name];
    if (typeof original !== 'function') return;
    history[name] = function () {
      var result = original.apply(this, arguments);
      setTimeout(function () { onRouteChange(name); }, 0);
      return result;
    };
  });
  window.addEventListener('popstate', function () {
    setTimeout(function () { onRouteChange('popstate'); }, 0);
  });
  // Safety net for navigation that uses neither (the Navigation API, a future router).
  setInterval(function () { onRouteChange('poll'); }, 500);

  // Taps: stopped before Instagram's own handlers see them (capture phase, registered first).
  document.addEventListener('click', function (event) {
    var target = event.target;
    var link = target && target.closest ? target.closest('a[href]') : null;
    if (!link) return;
    var url;
    try { url = new URL(link.getAttribute('href'), location.href); } catch (e) { return; }
    if (!INSTAGRAM.test(url.hostname)) return;
    var route = classify(url.pathname);
    if (!route) return;

    if (route.kind === 'clip') {
      if (!cfg.clipsAsPosts || hasBounced(route.id)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      noteRewrite(route.id);
      post({ t: 'rewrite', path: url.pathname, via: 'tap' });
      location.assign('/p/' + route.id + '/');
      return;
    }

    if (!cfg.blockReelsFeed) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    post({ t: 'blocked', path: url.pathname, via: 'tap' });
  }, true);

  // ---------------------------------------------------------------- hiding

  var INTERACTIVE = 'a[href], button, [role="link"], [role="button"]';

  function isInteractive(element) {
    return element.matches(INTERACTIVE) || element.querySelector(INTERACTIVE) !== null;
  }

  /**
   * The navigation bar's slot for a link: the smallest ancestor that sits beside at least two
   * other entries. Hiding the slot (not only the link) lets the bar close the gap.
   */
  function navigationSlot(link) {
    var element = link;
    for (var depth = 0; depth < 6; depth++) {
      var parent = element.parentElement;
      if (!parent || parent === document.body || parent === document.documentElement) return null;
      if (parent.children.length >= 3) {
        var peers = 0;
        for (var i = 0; i < parent.children.length; i++) {
          var sibling = parent.children[i];
          if (sibling !== element && isInteractive(sibling)) peers++;
        }
        if (peers >= 2) return element;
      }
      element = parent;
    }
    return null;
  }

  /**
   * The feed unit around a link to the Reels viewer (a "suggested reels" shelf): the smallest
   * ancestor that sits beside feed posts. Returns null inside a post, or when no such ancestor
   * exists: a post (<article>) is never hidden.
   */
  function feedUnit(link) {
    if (link.closest('article')) return null;
    var element = link;
    for (var depth = 0; depth < 14; depth++) {
      var parent = element.parentElement;
      if (!parent || parent === document.body || parent === document.documentElement) return null;
      if (element.querySelector('article')) return null;
      for (var i = 0; i < parent.children.length; i++) {
        var sibling = parent.children[i];
        if (sibling === element) continue;
        if (sibling.tagName === 'ARTICLE' || sibling.querySelector('article')) return element;
      }
      element = parent;
    }
    return null;
  }

  function mark(element, why) {
    if (!element || element.hasAttribute('data-sg-hidden')) return 0;
    element.setAttribute('data-sg-hidden', why);
    return 1;
  }

  function scan() {
    var root = document.documentElement;
    if (!root) return;
    if (!cfg.hideReels) {
      root.removeAttribute('data-sg-hide');
      return;
    }
    root.setAttribute('data-sg-hide', '');
    if (!document.body) return;

    var hidden = 0;
    var links = document.querySelectorAll('a[href^="/reels/"]');
    for (var i = 0; i < links.length; i++) {
      var link = links[i];
      var href = link.getAttribute('href') || '';
      var isTab = href === '/reels/' || href.indexOf('/reels/?') === 0;
      if (isTab) {
        hidden += mark(navigationSlot(link), 'nav');
      } else {
        hidden += mark(feedUnit(link), 'shelf');
      }
    }
    if (hidden) post({ t: 'hidden', n: hidden });
  }

  var scanTimer = null;
  function scheduleScan() {
    if (scanTimer !== null) return;
    scanTimer = setTimeout(function () {
      scanTimer = null;
      scan();
    }, 120);
  }

  function installStyle() {
    if (document.getElementById('scrollguard-style')) return;
    var parent = document.head || document.documentElement;
    if (!parent) return;
    var style = document.createElement('style');
    style.id = 'scrollguard-style';
    style.textContent = css;
    parent.appendChild(style);
  }

  // ---------------------------------------------------------------- start

  Object.defineProperty(window, '__scrollGuard', {
    enumerable: false,
    value: {
      /** Called by the app when a switch changes: applies to the page on screen, no reload. */
      configure: function (next) {
        cfg = next;
        scan();
        enforce('settings');
      },
      classify: classify
    }
  });

  installStyle();
  if (cfg.hideReels && document.documentElement) document.documentElement.setAttribute('data-sg-hide', '');
  enforce('load');

  new MutationObserver(function () {
    installStyle();
    scheduleScan();
  }).observe(document.documentElement || document, { childList: true, subtree: true });

  // The observer only reports changes from now on: also look at what is already there, and
  // again when the page is complete or comes back from the back/forward cache.
  scheduleScan();
  document.addEventListener('DOMContentLoaded', scheduleScan);
  window.addEventListener('pageshow', scheduleScan);

  post({ t: 'ready', path: location.pathname });
})();
