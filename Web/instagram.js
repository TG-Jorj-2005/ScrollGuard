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
 *   3. Keeps an opened clip (/reel/<id>/, /reels/<id>/) alone: swiping up or down over it, which
 *      would bring the next reel, is held back.
 *
 * Never hidden: posts in the feed (<article>), profiles, messages, search, stories.
 */
(function () {
  'use strict';

  var cfg = __SG_CONFIG__; // { hideReels, blockReelsFeed, singleClip, nativeBar }
  var css = __SG_CSS__;

  var INSTAGRAM = /(^|\.)instagram\.com$/i;
  if (!INSTAGRAM.test(location.hostname)) return; // sign-in hops through facebook.com: untouched
  if (window.__scrollGuard) return;

  var CLIP_ID = /^[A-Za-z0-9_-]{5,}$/;

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
      // Which server and what kind of file, not the address itself.
      var source = String(target.src || target.href).split('?')[0];
      var host = '?';
      try { host = new URL(source, location.href).hostname; } catch (e) { /* keep '?' */ }
      var extension = /\.[a-z0-9]{1,5}$/i.exec(source);
      what = 'failed to load a ' + (extension ? extension[0] : target.tagName.toLowerCase()) + ' from ' + host;
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
   *   { kind: 'clip', id }      one clip, opened from a post, a profile or a conversation
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
    // A clip under its author's name, /<name>/reel/<id>/: the form signed-in pages link to.
    if (parts.length >= 3 && parts[1].toLowerCase() === 'reel' && isClipId(parts[2])) {
      return { kind: 'clip', id: parts[2] };
    }
    return null;
  }

  function isClipId(text) {
    return CLIP_ID.test(text) && text.toLowerCase() !== 'audio';
  }

  function onClipPage() {
    var route = classify(location.pathname);
    return route !== null && route.kind === 'clip';
  }

  // ---------------------------------------------------------------- shapes

  // For diagnostics, an address is reduced to its shape: "/direct/t/*/", "/<name>/", "/p/*/".
  // Account names, conversation numbers and post ids never enter the log or the report.
  var KNOWN_HEADS = ['reels', 'reel', 'p', 'explore', 'direct', 'stories', 'accounts', 'tv',
    'challenge', 'notifications', 'your_activity', 'legal', 'about', 'web'];
  var KNOWN_WORDS = ['p', 'reel', 'inbox', 't', 'new', 'requests', 'tagged', 'reels', 'saved', 'audio', 'login',
    'onetap', 'edit', 'tags', 'locations', 'search', 'people', 'highlights', 'comments', 'liked_by',
    'followers', 'following', 'activity', 'signup', 'password', 'reset'];

  function shape(href) {
    var url;
    try { url = new URL(href, location.href); } catch (e) { return '?'; }
    if (!INSTAGRAM.test(url.hostname)) return 'external';
    var parts = url.pathname.split('/').filter(Boolean);
    if (!parts.length) return '/';
    var out = parts.map(function (part, index) {
      var word = part.toLowerCase();
      if (index === 0) return KNOWN_HEADS.indexOf(word) >= 0 ? word : '<name>';
      return KNOWN_WORDS.indexOf(word) >= 0 ? word : '*';
    });
    return '/' + out.join('/') + '/';
  }

  /** One element in a few words: tag, role, how it is positioned, whether it scrolls, its size. */
  function describe(element) {
    var style = getComputedStyle(element);
    var box = element.getBoundingClientRect();
    var text = element.tagName.toLowerCase();
    var role = element.getAttribute('role');
    if (role) text += '[' + role + ']';
    if (style.position === 'fixed' || style.position === 'sticky') text += ' ' + style.position;
    if (scrollsVertically(element, style)) text += ' scrolls';
    if (style.scrollSnapType && style.scrollSnapType !== 'none') text += ' snap(' + style.scrollSnapType + ')';
    return text + ' ' + Math.round(box.width) + 'x' + Math.round(box.height) + '@' + Math.round(box.top);
  }

  function scrollsVertically(element, style) {
    return /(auto|scroll)/.test(style.overflowY) && element.scrollHeight > element.clientHeight + 40;
  }

  function linkShapes(root, limit) {
    var counts = {};
    var links = root.querySelectorAll('a[href]');
    for (var i = 0; i < links.length && i < limit; i++) {
      var key = shape(links[i].getAttribute('href'));
      counts[key] = (counts[key] || 0) + 1;
    }
    return counts;
  }

  /**
   * The structure of the page on screen, for the diagnostics report: bars, scrolling areas,
   * videos, dialogs and the shapes of links. No text, no names, no addresses.
   */
  function snapshot() {
    var result = {
      page: shape(location.pathname),
      viewport: window.innerWidth + 'x' + window.innerHeight,
      links: linkShapes(document, 3000),
      videos: [],
      dialogs: [],
      bars: [],
      scrollers: []
    };
    if (!document.body) return JSON.stringify(result);

    var videos = document.querySelectorAll('video');
    result.videoCount = videos.length;
    for (var v = 0; v < videos.length && result.videos.length < 3; v++) {
      var box = videos[v].getBoundingClientRect();
      if (box.height < 50 || box.bottom < 0 || box.top > window.innerHeight) continue;
      var chain = [];
      for (var el = videos[v], depth = 0; el && el !== document.body && depth < 12; el = el.parentElement, depth++) {
        chain.push(describe(el));
      }
      result.videos.push(chain);
    }

    var dialogs = document.querySelectorAll('[role="dialog"]');
    for (var d = 0; d < dialogs.length && d < 5; d++) result.dialogs.push(describe(dialogs[d]));

    var all = document.body.getElementsByTagName('*');
    for (var i = 0; i < all.length && i < 5000; i++) {
      var element = all[i];
      var style = getComputedStyle(element);
      var rect = element.getBoundingClientRect();
      var wide = rect.width >= window.innerWidth * 0.8;
      if ((style.position === 'fixed' || style.position === 'sticky') && wide && rect.height > 20 && rect.height < 200) {
        if (result.bars.length < 8) result.bars.push(describe(element) + ' links ' + JSON.stringify(linkShapes(element, 40)));
      }
      if (scrollsVertically(element, style) && rect.height > window.innerHeight * 0.4) {
        if (result.scrollers.length < 8) result.scrollers.push(describe(element));
      }
    }
    return JSON.stringify(result);
  }

  // ---------------------------------------------------------------- navigation

  var lastPath = location.pathname;
  var previousPath = null; // the page we were on before the current one, inside this document

  /** Acts on the page we are on now. `via`: load, pushState, replaceState, popstate, poll. */
  function enforce(via) {
    var route = classify(location.pathname);
    // A single clip is allowed to open; the single-clip guard below keeps it alone.
    if (!route || route.kind !== 'feed') return;
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

  /**
   * Tells the app that a new page is about to open, so it can animate the change. Only for a
   * page opened on top of the current one; going back and Instagram's own animated screens
   * (stories) are left alone.
   */
  function announcePush(target) {
    var url;
    try { url = new URL(String(target), location.href); } catch (e) { return; }
    if (!INSTAGRAM.test(url.hostname) || url.pathname === location.pathname) return;
    if (url.pathname.indexOf('/stories/') === 0) return;
    post({ t: 'transition', kind: 'push' });
  }

  ['pushState', 'replaceState'].forEach(function (name) {
    var original = history[name];
    if (typeof original !== 'function') return;
    history[name] = function () {
      if (name === 'pushState' && arguments.length > 2 && arguments[2] != null) announcePush(arguments[2]);
      var result = original.apply(this, arguments);
      setTimeout(function () { onRouteChange(name); }, 0);
      return result;
    };
  });
  window.addEventListener('popstate', function () {
    setTimeout(function () { onRouteChange('popstate'); }, 0);
  });
  // Newer WebKit has the Navigation API, and Instagram uses it where it exists: some page
  // changes then call neither pushState nor popstate, and were only noticed by the poll below.
  if (window.navigation && typeof window.navigation.addEventListener === 'function') {
    window.navigation.addEventListener('navigate', function (event) {
      if (event.navigationType === 'push' && event.destination && !event.hashChange) {
        announcePush(event.destination.url);
      }
    });
    window.navigation.addEventListener('currententrychange', function (event) {
      var kind = (event && event.navigationType) || 'navigation';
      setTimeout(function () { onRouteChange(kind); }, 0);
    });
  }
  window.addEventListener('pageshow', function () {
    setTimeout(function () { onRouteChange('pageshow'); }, 0);
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
    if (!route || route.kind !== 'feed' || !cfg.blockReelsFeed) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    post({ t: 'blocked', path: url.pathname, via: 'tap' });
  }, true);

  // ---------------------------------------------------------------- single clip

  // A clip opened from a post, a profile or a conversation fills the screen, and swiping up
  // brings the next reel, then the next: the endless viewer by another door. While such a clip
  // is on screen, vertical swipes over it are held back, before the page or the browser sees
  // them. Taps (pause, like, sound), horizontal swipes (back) and anything inside a sheet over
  // the clip (comments, sharing) work as usual.

  /**
   * The video that fills the screen, if one does: most of the height, around the middle.
   * `fullWidth` also asks for the whole width, which tells an opened clip from a video that
   * merely sits in the page (a message bubble).
   */
  function screenFillingVideo(fullWidth) {
    var width = window.innerWidth;
    var height = window.innerHeight;
    var videos = document.querySelectorAll('video');
    for (var i = 0; i < videos.length; i++) {
      var box = videos[i].getBoundingClientRect();
      if (fullWidth && box.width < width * 0.9) continue;
      if (box.height >= height * 0.6 && box.top < height * 0.5 && box.bottom > height * 0.5) return videos[i];
    }
    return null;
  }

  /**
   * The opened clip to keep alone, if there is one on this page:
   *   - on a clip's own page, the video that fills the screen;
   *   - in a conversation, the same, at full width: a clip sent there opens over the
   *     conversation, and the address does not change.
   * Nowhere else: in the feed, tall videos are posts to scroll past.
   */
  function openedClip() {
    if (onClipPage()) return screenFillingVideo(false);
    if (location.pathname.indexOf('/direct/') === 0) return screenFillingVideo(true);
    return null;
  }

  var swipe = null; // the touch being followed: where it began, whether it was reported

  document.addEventListener('touchstart', function (event) {
    swipe = null;
    if (!cfg.singleClip || !event.touches || event.touches.length !== 1) return;
    var clip = openedClip();
    if (!clip) return;
    // A sheet over the clip scrolls as usual. A dialog that holds the clip itself is the viewer.
    var target = event.target;
    var dialog = target && target.closest ? target.closest('[role="dialog"]') : null;
    if (dialog && !dialog.contains(clip)) return;
    swipe = { x: event.touches[0].clientX, y: event.touches[0].clientY, reported: false };
  }, { capture: true, passive: true });

  // With no Mac to inspect the page, the first full-screen video seen on each kind of page is
  // described in the log: what it sits in, what scrolls. Structure only, no content.
  var describedPages = {};
  function describeFullScreenVideo() {
    var video = screenFillingVideo(true);
    if (!video) return;
    var page = shape(location.pathname);
    if (describedPages[page]) return;
    describedPages[page] = true;
    var chain = [];
    for (var element = video, depth = 0; element && element !== document.body && depth < 14; element = element.parentElement, depth++) {
      chain.push(describe(element));
    }
    var kept = cfg.singleClip && openedClip() !== null;
    post({ t: 'structure', text: 'full-screen video on ' + page + (kept ? ' (kept alone)' : ' (not held)') + ': ' + chain.join(' < ') });
  }
  setInterval(describeFullScreenVideo, 700);

  function holdBack(event, x, y) {
    if (!swipe) return;
    var dx = x - swipe.x;
    var dy = y - swipe.y;
    if (Math.abs(dy) <= Math.abs(dx)) return;
    if (event.cancelable) event.preventDefault();
    event.stopImmediatePropagation();
    if (!swipe.reported && Math.abs(dy) > 40) {
      swipe.reported = true;
      post({ t: 'held', path: location.pathname });
    }
  }

  // passive: false, or the browser would not let the listener stop the scroll.
  document.addEventListener('touchmove', function (event) {
    if (!swipe || !event.touches || event.touches.length !== 1) return;
    holdBack(event, event.touches[0].clientX, event.touches[0].clientY);
  }, { capture: true, passive: false });

  // The same for a viewer that follows the finger through pointer events.
  document.addEventListener('pointermove', function (event) {
    if (!swipe || event.pointerType !== 'touch') return;
    holdBack(event, event.clientX, event.clientY);
  }, { capture: true, passive: false });

  ['touchend', 'touchcancel'].forEach(function (name) {
    document.addEventListener(name, function () { swipe = null; }, { capture: true, passive: true });
  });

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

  // ---------------------------------------------------------------- Instagram's own bar

  // The app can show a native bar in place of Instagram's bottom bar. Instagram's bar is then
  // hidden, not removed: a tap on a native button clicks the matching link inside it, so
  // Instagram changes page in place, as if its own button had been tapped.

  var TAB_PATHS = { home: '/', search: '/explore/', messages: '/direct/inbox/' };
  var barElement = null;
  var profilePath = null; // the signed-in account's own page, read from the bar's last link
  try { profilePath = localStorage.getItem('sg-profile-path'); } catch (e) { /* storage blocked */ }
  var lastBarReport = '';

  /** Instagram's bottom bar: the fixed element at the bottom that holds the search and messages links. */
  function findBar() {
    if (barElement && barElement.isConnected) return barElement;
    var links = document.querySelectorAll('a[href="/direct/inbox/"]');
    for (var i = 0; i < links.length; i++) {
      var element = links[i].parentElement;
      for (var depth = 0; element && element !== document.body && depth < 12; element = element.parentElement, depth++) {
        if (!element.querySelector('a[href="/explore/"]')) continue;
        var position = getComputedStyle(element).position;
        if (position !== 'fixed' && position !== 'sticky') continue;
        if (element.hasAttribute('data-sg-bar')) return element;
        var box = element.getBoundingClientRect();
        if (box.height > 20 && box.height < 140 && box.top > window.innerHeight * 0.5) return element;
        break; // fixed, but not a bar at the bottom (a side menu): not this link
      }
    }
    return null;
  }

  function watchBar() {
    var root = document.documentElement;
    if (!root || !document.body) return;
    barElement = findBar();
    if (barElement) {
      if (!barElement.hasAttribute('data-sg-bar')) barElement.setAttribute('data-sg-bar', '');
      var anchors = barElement.querySelectorAll('a[href]');
      for (var i = 0; i < anchors.length; i++) {
        var href = anchors[i].getAttribute('href');
        if (/^\/[A-Za-z0-9._]+\/$/.test(href) && shape(href) === '/<name>/' && href !== profilePath) {
          profilePath = href;
          try { localStorage.setItem('sg-profile-path', href); } catch (e) { /* storage blocked */ }
        }
      }
    }
    if (cfg.nativeBar) root.setAttribute('data-sg-native-bar', '');
    else root.removeAttribute('data-sg-native-bar');

    var report = JSON.stringify([barElement !== null, profilePath]);
    if (report !== lastBarReport) {
      lastBarReport = report;
      post({ t: 'bar', present: barElement !== null, profile: profilePath });
    }
  }

  /** Goes back through this page's history to the nearest earlier visit of `path`, if any. */
  function goBackTo(path) {
    try {
      var api = window.navigation;
      if (api && typeof api.entries === 'function' && api.currentEntry) {
        var entries = api.entries();
        for (var i = api.currentEntry.index - 1; i >= 0; i--) {
          if (!entries[i].sameDocument) break;
          if (new URL(entries[i].url).pathname === path) {
            api.traverseTo(entries[i].key);
            return true;
          }
        }
        return false;
      }
    } catch (e) { /* fall through to the plain history */ }
    // Without the Navigation API only the page just before this one is known.
    if (previousPath === path && history.length > 1) {
      history.back();
      return true;
    }
    return false;
  }

  /**
   * A native bar button was tapped. Returns how the page is being changed: 'click' (Instagram's
   * own link, in place), 'back' (back to an earlier visit, in place), 'load' (a full page
   * load), 'already', 'unknown'.
   */
  function go(tab) {
    var path = tab === 'profile' ? profilePath : TAB_PATHS[tab];
    if (!path) return 'unknown';
    if (location.pathname === path) return 'already';
    var selector = 'a[href="' + path + '"]';
    var link = barElement && barElement.isConnected ? barElement.querySelector(selector) : null;
    if (!link) link = document.querySelector(selector);
    if (!link) {
      // No link to it on this page (the messages screen has none). If the page was visited on
      // the way here, go back to it, which Instagram does in place; otherwise load it.
      if (goBackTo(path)) return 'back';
      location.assign(path);
      return 'load';
    }
    link.click();
    // If the click changed nothing (a link that was only decoration), load the page.
    setTimeout(function () {
      if (location.pathname !== path) location.assign(path);
    }, 600);
    return 'click';
  }

  function scan() {
    var root = document.documentElement;
    if (!root) return;
    watchBar();
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

  // ---------------------------------------------------------------- edge colours

  // The app paints the strips behind the status bar and the home indicator in the colours of
  // the page's top and bottom edges, so the page seems to reach the edges of the screen.

  /** The solid background colour under a point, as [r, g, b], or null. */
  function colourAt(x, y) {
    for (var element = document.elementFromPoint(x, y); element; element = element.parentElement) {
      var match = /^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)$/.exec(getComputedStyle(element).backgroundColor);
      if (match && (match[4] === undefined || parseFloat(match[4]) > 0.9)) {
        return [Number(match[1]), Number(match[2]), Number(match[3])];
      }
    }
    return null;
  }

  var lastEdges = '';
  function reportEdgeColours() {
    var width = window.innerWidth;
    var height = window.innerHeight;
    if (!width || !height || !document.body) return;
    var top = colourAt(width / 2, 1);
    var bottom = colourAt(width / 2, height - 2);
    var key = JSON.stringify([top, bottom]);
    if (key === lastEdges) return;
    lastEdges = key;
    post({ t: 'edges', top: top, bottom: bottom });
  }
  setInterval(reportEdgeColours, 600);

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
      classify: classify,
      shape: shape,
      snapshot: snapshot,
      go: go
    }
  });

  installStyle();
  if (cfg.hideReels && document.documentElement) document.documentElement.setAttribute('data-sg-hide', '');
  enforce('load');

  // Scan at once, in the same turn in which Instagram added something and before the browser
  // paints it. A tab that is hidden a moment after it was drawn is seen: the bar shows a gap,
  // then its buttons jump together. Instagram redraws the bar on every page change.
  new MutationObserver(function (records) {
    installStyle();
    for (var i = 0; i < records.length; i++) {
      if (records[i].addedNodes.length) {
        scan();
        return;
      }
    }
  }).observe(document.documentElement || document, { childList: true, subtree: true });

  // The observer only reports changes from now on: also look at what is already there, and
  // again when the page is complete or comes back from the back/forward cache.
  scheduleScan();
  document.addEventListener('DOMContentLoaded', scheduleScan);
  window.addEventListener('pageshow', scheduleScan);

  post({ t: 'ready', path: location.pathname });
})();
