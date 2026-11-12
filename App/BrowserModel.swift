import Combine
import UIKit
import WebKit

/// The one web view of the app, kept for the app's whole life, and everything around it: the
/// filter script, the navigation rules, and the state the SwiftUI views show.
///
/// Sign-in happens on Instagram's own pages inside the web view. This class never reads what is
/// typed there, and never reads a cookie's value: it only checks whether a session cookie exists.
@MainActor
final class BrowserModel: NSObject, ObservableObject {
    enum Failure: Equatable {
        case offline
        /// Instagram answered with an error status and an empty page (429: too many requests).
        case http(Int)
        case other(String)
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let symbol: String
    }

    struct ExternalLink: Identifiable {
        let id = UUID()
        let url: URL
    }

    let webView: WKWebView

    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    /// False until the first page is on screen: the launch cover hides the empty web view.
    @Published private(set) var hasShownFirstPage = false
    @Published private(set) var failure: Failure?
    /// nil until the cookies were looked at once (on this or an earlier run).
    @Published private(set) var isSignedIn: Bool?
    @Published private(set) var hiddenCount = 0
    @Published private(set) var blockedCount = 0
    @Published var toast: Toast?
    /// A link to another website, shown in a Safari sheet.
    @Published var externalLink: ExternalLink?
    /// The colours of the page's top and bottom edges, reported by the filter. The strips behind
    /// the status bar and the home indicator take them, so they join the page without a seam.
    @Published private(set) var topEdgeColor: UIColor = .black
    @Published private(set) var bottomEdgeColor: UIColor = .black
    /// The path of the page on screen, kept up to date through in-page navigation too. It
    /// decides whether the native bar shows and which of its buttons is lit. Never logged.
    @Published private(set) var currentPath = "/"
    @Published private(set) var isOnInstagram = true
    /// True once the filter has found Instagram's own bottom bar, on this or an earlier run.
    /// Until then the native bar stays away, so there are never two bars.
    @Published private(set) var barDetected: Bool
    /// The number Instagram shows on its own messages button, for the badge on the native one.
    @Published private(set) var unreadMessages = 0
    /// Told when the count of unread conversations changes. Set by the app.
    weak var notifier: Notifier?
    /// A picture of the feed as it last looked. Shown at launch until the live page is drawn,
    /// so the app opens on its content instead of an empty screen. Stays on the phone.
    @Published private(set) var launchImage: UIImage?
    /// True on the first start after an update: the version label is shown for a moment.
    @Published private(set) var showsVersionLabel = false

    /// The buttons of the native bar: the destinations of Instagram's own bar, without Reels.
    enum Tab: String, CaseIterable {
        case home, search, messages, profile
    }

    private let store: SettingsStore
    private let log = DiagnosticsLog.shared
    private var subscriptions = Set<AnyCancellable>()
    private let refreshControl = UIRefreshControl()
    private var started = false
    /// The web content process ended while the app was in the background: the page is loaded
    /// again when the app is back in front, not while it cannot be seen.
    private var reloadWhenActive = false
    /// Where each running download is written, until it finishes.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    private var userAgent = ""
    private var mainFrameStatus = 200
    private var recentBlocks: [Date] = []
    /// The signed-in account's own page, e.g. "/name/", read by the filter from Instagram's bar.
    /// Needed for the Profile button. Kept in memory only, never logged.
    private var profilePath: String?
    private var lastTransition = Date.distantPast
    private var transitionsPausedUntil = Date.distantPast
    /// For the simulator check only: show the native bar although nobody is signed in.
    private let forceBar = UserDefaults.standard.bool(forKey: "debugForceBar")

    private static let messageHandlerName = "scrollGuard"
    private static let signedInKey = "wasSignedIn"
    private static let barDetectedKey = "barDetected"
    private static let edgeColorsKey = "launchEdgeColors"
    private static let launchImageURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("launch-feed.jpg")

    init(store: SettingsStore) {
        self.store = store
        // What was true when the app last ran, so the first page already gets the right bar.
        // It is checked again as soon as the page is there.
        barDetected = UserDefaults.standard.bool(forKey: Self.barDetectedKey)

        let configuration = WKWebViewConfiguration()
        // The persistent store: cookies and site data stay between launches, as in Safari.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        // As in Safari: silent video may start by itself, sound needs a tap.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        // The User-Agent is left exactly as WebKit sets it.
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        // Likewise remembered from the last run, and checked again in start().
        isSignedIn = UserDefaults.standard.object(forKey: Self.signedInKey) as? Bool
        // The feed as it last looked, and the colours of its edges, for the launch.
        if isSignedIn == true {
            launchImage = UIImage(contentsOfFile: Self.launchImageURL.path)
            if launchImage != nil, let saved = UserDefaults.standard.array(forKey: Self.edgeColorsKey), saved.count == 6 {
                topEdgeColor = Self.edgeColor(Array(saved[0..<3]))
                bottomEdgeColor = Self.edgeColor(Array(saved[3..<6]))
            }
        }
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.captureLaunchImage() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.becameActive() }
            .store(in: &subscriptions)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.overrideUserInterfaceStyle = .dark
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // The view is laid out inside the safe area already; no extra insets.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // As in Messages: dragging a conversation down takes the keyboard with it.
        webView.scrollView.keyboardDismissMode = .interactive
        // Lets Safari on a Mac inspect the page, should a Mac ever be available.
        webView.isInspectable = true

        refreshControl.tintColor = UIColor(white: 1, alpha: 0.6)
        refreshControl.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        webView.configuration.userContentController.add(self, name: Self.messageHandlerName)
        installFilterScript()
        observeWebView()

        // `$settings` fires just before the value changes; one main-loop turn later it is set.
        store.$settings
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyFilterConfig() }
            .store(in: &subscriptions)
    }

    // MARK: - Native bar

    /// The native bar replaces Instagram's own while it is switched on and someone is signed in.
    private var nativeBarActive: Bool {
        forceBar || (store.settings.nativeBar && isSignedIn == true)
    }

    /// Whether the native bar is on screen now. Like in a native app, it steps aside where the
    /// whole screen belongs to one thing: a story, a conversation, signing in.
    var showsNativeBar: Bool {
        if forceBar { return true }
        guard nativeBarActive, barDetected, failure == nil, isOnInstagram else { return false }
        let parts = currentPath.split(separator: "/").map { $0.lowercased() }
        guard let head = parts.first else { return true }
        if head == "stories" || head == "accounts" || head == "challenge" { return false }
        if head == "direct", parts.count >= 2, parts[1] == "t" { return false }
        return true
    }

    var activeTab: Tab? {
        if currentPath == "/" { return .home }
        if currentPath.hasPrefix("/explore") { return .search }
        if currentPath.hasPrefix("/direct") { return .messages }
        if let profilePath, currentPath.hasPrefix(profilePath) { return .profile }
        return nil
    }

    /// A button of the native bar was tapped.
    func select(_ tab: Tab) {
        UISelectionFeedbackGenerator().selectionChanged()
        if activeTab == tab {
            scrollToTop()
            return
        }
        // Changing tab is instant in a native app too: no slide for this page change.
        transitionsPausedUntil = Date().addingTimeInterval(0.8)
        let script = "window.__scrollGuard ? window.__scrollGuard.go('\(tab.rawValue)') : 'no filter'"
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            let result = value as? String ?? "failed"
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log.add("bar", "\(tab.rawValue): \(result)")
                // The filter could not do it (it is not running on this page): load the page.
                if !["click", "back", "load", "already"].contains(result) { self.load(tab) }
            }
        }
    }

    private func load(_ tab: Tab) {
        let path: String?
        switch tab {
        case .home: path = "/"
        case .search: path = "/explore/"
        case .messages: path = "/direct/inbox/"
        case .profile: path = profilePath
        }
        guard let path, let url = URL(string: path, relativeTo: Routes.home) else { return }
        webView.load(URLRequest(url: url))
    }

    /// A page is opening on top of the current one: let it arrive with a short slide, instead of
    /// replacing the old one in a single frame.
    private func animatePush() {
        let now = Date()
        guard store.settings.pageTransitions, !UIAccessibility.isReduceMotionEnabled,
              now > transitionsPausedUntil, now.timeIntervalSince(lastTransition) > 0.35 else { return }
        lastTransition = now
        log.add("anim", "slide for a page opening")
        webView.alpha = 0.25
        webView.transform = CGAffineTransform(translationX: 28, y: 0)
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
            self.webView.alpha = 1
            self.webView.transform = .identity
        }
    }

    // MARK: - Commands from the views

    /// Loads Instagram once, when the main view first appears.
    func start() {
        guard !started else { return }
        started = true
        log.add("app", "ScrollGuard \(DeviceInfo.appVersion), \(DeviceInfo.system), \(DeviceInfo.model)")
        log.add("app", "settings \(store.settings.summary)")
        // How many times the app started since it was installed, and which version ran before.
        // After an update the count goes on if the app was updated in place, and starts again
        // at 1 if it was removed and installed anew, which also signs out of Instagram.
        let defaults = UserDefaults.standard
        let launches = defaults.integer(forKey: "launchCount") + 1
        let previousVersion = defaults.string(forKey: "lastVersion") ?? "none"
        defaults.set(launches, forKey: "launchCount")
        defaults.set(DeviceInfo.appVersion, forKey: "lastVersion")
        log.add("app", "start \(launches) of this install, version before: \(previousVersion)")
        showsVersionLabel = previousVersion != DeviceInfo.appVersion

        // For the simulator check in GitHub Actions (.github/scripts/smoke.sh): start on a given
        // page, passed as a launch argument. Never set on the phone.
        if let text = UserDefaults.standard.string(forKey: "debugStartURL"), let url = URL(string: text) {
            log.add("app", "debug start page \(url.redacted)")
            webView.load(URLRequest(url: url))
            refreshSignInState()
            return
        }
        // The cookies first, then the page: the feed when signed in, the sign-in page when not.
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let signedIn = cookies.contains { cookie in
                cookie.name == "sessionid" && cookie.domain.hasSuffix("instagram.com") && !cookie.value.isEmpty
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setSignedIn(signedIn)
                self.loadHome()
            }
        }
    }

    /// The feed, or Instagram's sign-in page when nobody is signed in.
    /// Opens a page of Instagram, from a tapped notification.
    func open(path: String) {
        guard let url = URL(string: path, relativeTo: Routes.home), Routes.isInstagram(url) else { return }
        if webView.url?.path != url.path { webView.load(URLRequest(url: url)) }
    }

    func loadHome() {
        failure = nil
        webView.load(URLRequest(url: isSignedIn == false ? Routes.login : Routes.home))
    }

    // MARK: - Launch image

    /// Keeps a picture of the top of the feed for the next launch. Only the feed, only at its
    /// top, only while signed in: that is what the next launch will open on.
    private func captureLaunchImage() {
        guard isSignedIn == true, isOnInstagram, currentPath == "/", failure == nil, hasShownFirstPage,
              webView.bounds.width > 0, webView.scrollView.contentOffset.y < 80 else { return }
        let colors = [topEdgeColor, bottomEdgeColor].flatMap { color -> [Double] in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            _ = color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [Double(red) * 255, Double(green) * 255, Double(blue) * 255]
        }
        let file = Self.launchImageURL
        let colorsKey = Self.edgeColorsKey
        webView.takeSnapshot(with: nil) { image, _ in
            guard let data = image?.jpegData(compressionQuality: 0.72) else { return }
            try? data.write(to: file, options: .atomic)
            UserDefaults.standard.set(colors, forKey: colorsKey)
        }
    }

    private func forgetLaunchImage() {
        launchImage = nil
        try? FileManager.default.removeItem(at: Self.launchImageURL)
        UserDefaults.standard.removeObject(forKey: Self.edgeColorsKey)
    }

    /// Takes the launch cover away. The page says when it has something to show; a page that
    /// never says so is shown after a few seconds anyway.
    private func revealPage() {
        if !hasShownFirstPage { hasShownFirstPage = true }
    }

    /// Pulling down reloads the page only where the page itself scrolls. In a conversation, a
    /// story or an opened clip the page stands still and something inside it scrolls: there a
    /// pull is just scrolling up, and must not reload anything.
    private var allowsPullToRefresh: Bool {
        guard isOnInstagram else { return true }
        let parts = currentPath.split(separator: "/").map { $0.lowercased() }
        guard let head = parts.first else { return true }
        if ["direct", "stories", "accounts", "challenge", "reel", "reels"].contains(head) { return false }
        if parts.count >= 2, parts[1] == "reel" { return false }
        return true
    }

    func reload() {
        failure = nil
        if webView.url == nil { loadHome() } else { webView.reload() }
    }

    private func becameActive() {
        guard reloadWhenActive else { return }
        reloadWhenActive = false
        log.add("page", "back in front: reloading the page lost in the background")
        reload()
    }

    func scrollToTop() {
        let scrollView = webView.scrollView
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: true)
    }

    /// Cookies, caches and site storage: signs out of Instagram. The switches are kept.
    func clearBrowsingData() async {
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                      modifiedSince: .distantPast)
        log.add("app", "browsing data cleared")
        setSignedIn(false)
        loadHome()
    }

    private func setSignedIn(_ signedIn: Bool) {
        guard isSignedIn != signedIn else { return }
        isSignedIn = signedIn
        UserDefaults.standard.set(signedIn, forKey: Self.signedInKey)
        log.add("app", "instagram session cookie: \(signedIn ? "present" : "absent")")
        if !signedIn {
            forgetLaunchImage()
            unreadMessages = 0
        }
        // Signing in or out switches between the native bar and Instagram's own.
        applyFilterConfig()
    }

    /// Whether Instagram's session cookie exists. Only the cookie's name and site are looked at.
    func refreshSignInState() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let signedIn = cookies.contains { cookie in
                cookie.name == "sessionid" && cookie.domain.hasSuffix("instagram.com") && !cookie.value.isEmpty
            }
            Task { @MainActor [weak self] in
                self?.setSignedIn(signedIn)
            }
        }
    }

    /// The structure of the page on screen, from the filter: bars, scrolling areas, videos.
    private func pageSnapshot() async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let script = "window.__scrollGuard ? window.__scrollGuard.snapshot() : 'the filter is not running on this page'"
            webView.evaluateJavaScript(script) { value, error in
                continuation.resume(returning: value as? String ?? "unavailable: \(error?.localizedDescription ?? "no result")")
            }
        }
    }

    /// The text behind "Copy report" in Diagnostics.
    func makeReport() async -> String {
        let snapshot = await pageSnapshot()
        var lines = [
            "ScrollGuard \(DeviceInfo.appVersion)",
            "\(DeviceInfo.system) · \(DeviceInfo.model)",
            "User-Agent: \(userAgent.isEmpty ? "(not read yet)" : userAgent)",
            "Signed in: \(isSignedIn.map { $0 ? "yes" : "no" } ?? "unknown")",
            "Settings: \(store.settings.summary)",
            "Page: \(webView.url?.redacted ?? "(none)")",
            "Hidden elements: \(hiddenCount) · Blocked: \(blockedCount)",
            "Native bar: \(showsNativeBar ? "shown" : "not shown") · Instagram's bar found: \(barDetected ? "yes" : "no")"
                + " · own page known: \(profilePath == nil ? "no" : "yes")",
            "",
            "--- page on screen ---",
            snapshot
        ]
        if !log.previousSession.isEmpty {
            lines.append("")
            lines.append("--- previous session, last lines ---")
            lines.append(contentsOf: log.previousSession)
        }
        lines.append("")
        lines.append("--- this session ---")
        lines.append(contentsOf: log.entries.map { log.line($0) })
        return lines.joined(separator: "\n")
    }

    // MARK: - Filter script

    /// instagram.js with its two placeholders filled in: the switches and the stylesheet.
    private static func filterSource(config: String) -> String? {
        guard let scriptURL = Bundle.main.url(forResource: "instagram", withExtension: "js"),
              let styleURL = Bundle.main.url(forResource: "instagram", withExtension: "css"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let style = try? String(contentsOf: styleURL, encoding: .utf8),
              let styleData = try? JSONEncoder().encode(style),
              let styleLiteral = String(data: styleData, encoding: .utf8) else { return nil }
        return script
            .replacingOccurrences(of: "__SG_CONFIG__", with: config)
            .replacingOccurrences(of: "__SG_CSS__", with: styleLiteral)
    }

    private func installFilterScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        // For the simulator check only: the plain site, to compare against.
        if UserDefaults.standard.bool(forKey: "debugNoFilter") {
            log.add("app", "debug: filter not installed")
            return
        }
        let config = store.settings.filterConfig(nativeBarActive: nativeBarActive)
        guard let source = Self.filterSource(config: config) else {
            log.add("error", "filter files are missing from the app bundle")
            return
        }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// A switch changed, or someone signed in or out: pages loaded from now on get the new
    /// values, and the page on screen is updated in place, without a reload.
    private func applyFilterConfig() {
        log.add("app", "settings \(store.settings.summary)")
        installFilterScript()
        let config = store.settings.filterConfig(nativeBarActive: nativeBarActive)
        let update = "window.__scrollGuard && window.__scrollGuard.configure(\(config)); true;"
        webView.evaluateJavaScript(update) { _, _ in }
    }

    // MARK: - Web view state

    private func observeWebView() {
        webView.publisher(for: \.estimatedProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.progress = value }
            .store(in: &subscriptions)
        webView.publisher(for: \.isLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.isLoading = value
                if !value { self?.refreshControl.endRefreshing() }
            }
            .store(in: &subscriptions)
        webView.publisher(for: \.url)
            .receive(on: RunLoop.main)
            .sink { [weak self] url in self?.urlChanged(url) }
            .store(in: &subscriptions)
    }

    /// A colour sent by the filter as [r, g, b]. Only dark ones are taken: the status bar's text
    /// is white and has to stay readable. Anything else gives black.
    private static func edgeColor(_ value: Any?) -> UIColor {
        guard let parts = value as? [Any], parts.count == 3 else { return .black }
        let channels = parts.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard channels.count == 3, channels.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return .black }
        let red = channels[0] / 255, green = channels[1] / 255, blue = channels[2] / 255
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance < 0.25 ? UIColor(red: red, green: green, blue: blue, alpha: 1) : .black
    }

    /// What is actually in the page, for the diagnostics log: sizes and counts, no content.
    private static let pageProbe = """
        (function () {
          var d = document, b = d.body;
          return JSON.stringify({
            ready: d.readyState,
            html: d.documentElement ? d.documentElement.outerHTML.length : 0,
            text: b ? b.innerText.length : 0,
            children: b ? b.children.length : 0,
            scripts: d.scripts.length,
            inputs: d.querySelectorAll('input').length,
            links: d.links.length
          });
        })()
        """

    private func probePage(_ label: String) {
        webView.evaluateJavaScript(Self.pageProbe) { [weak self] value, error in
            let text = value as? String ?? "failed: \(error?.localizedDescription ?? "no result")"
            Task { @MainActor [weak self] in self?.log.add("page", "\(label) \(text)") }
        }
    }

    /// In-page navigation never reaches the navigation delegate; the page script handles it.
    /// This is the safety net: if the script did not leave a Reels page within a moment (it is
    /// missing, or Instagram changed under it), the app leaves it.
    private func urlChanged(_ url: URL?) {
        guard let url else { return }
        let path = url.path.hasSuffix("/") ? url.path : url.path + "/"
        if path != currentPath { currentPath = path }
        let onInstagram = Routes.isInstagram(url)
        if onInstagram != isOnInstagram { isOnInstagram = onInstagram }
        let wanted = allowsPullToRefresh ? refreshControl : nil
        if webView.scrollView.refreshControl !== wanted { webView.scrollView.refreshControl = wanted }

        guard store.settings.blockReelsFeed, Routes.classify(url) == .feed else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.store.settings.blockReelsFeed,
                  let current = self.webView.url, Routes.classify(current) == .feed else { return }
            self.registerBlock(path: Routes.shape(path: current.path), via: "native")
            if self.webView.canGoBack { self.webView.goBack() } else { self.loadHome() }
        }
    }

    @objc private func pulledToRefresh() {
        log.add("app", "pulled to refresh")
        reload()
    }

    private func registerBlock(path: String, via: String) {
        blockedCount += 1
        log.add("block", "\(via) \(path)")
        toast = Toast(text: "Reels are hidden", symbol: "shield.lefthalf.filled")
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()

        // Never a loop: many blocks in a few seconds mean something keeps sending us back.
        let now = Date()
        recentBlocks = recentBlocks.filter { now.timeIntervalSince($0) < 5 } + [now]
        if recentBlocks.count >= 6 {
            recentBlocks.removeAll()
            log.add("block", "too many in 5 s: going to the feed")
            loadHome()
        }
    }

    private func showLoadError(_ error: Error, stage: String) {
        refreshControl.endRefreshing()
        let nsError = error as NSError
        log.add("error", "\(stage): \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
        // Not failures: a load replaced by a newer one, or one the app itself cancelled.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204) { return }

        let offlineCodes = [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
            NSURLErrorInternationalRoamingOff, NSURLErrorTimedOut, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed
        ]
        let offline = nsError.domain == NSURLErrorDomain && offlineCodes.contains(nsError.code)
        if webView.url == nil {
            // Nothing on screen to fall back to: the native error screen.
            failure = offline ? .offline : .other(nsError.localizedDescription)
            hasShownFirstPage = true
        } else {
            // The previous page is still there: leave it, just say so.
            toast = Toast(text: offline ? "No connection" : "Couldn't open the page", symbol: "wifi.slash")
        }
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - WKNavigationDelegate

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "blob" || scheme == "data" {
            decisionHandler(.allow)
            return
        }
        guard scheme == "https" || scheme == "http" else {
            decisionHandler(.cancel)
            if ["mailto", "tel", "sms", "facetime"].contains(scheme) {
                // The Email and Call buttons of a business profile: Mail, Phone, Messages.
                log.add("nav", "\(scheme): link handed to the system")
                UIApplication.shared.open(url)
            } else {
                // instagram://, itms-apps:// — attempts to leave for another app.
                log.add("nav", "ignored \(scheme): link")
            }
            return
        }
        // Only the page itself is steered. Frames inside it (players, security checks) are the site's.
        guard navigationAction.targetFrame?.isMainFrame ?? true else {
            decisionHandler(.allow)
            return
        }

        // "Open Instagram" and "Get the app" lead to the Instagram app or the App Store. Here
        // they lead nowhere useful: signed out, the sign-in page is what was wanted.
        let host = url.host?.lowercased() ?? ""
        if host == "applink.instagram.com" || host == "apps.apple.com" || host == "itunes.apple.com" {
            log.add("nav", "ignored a link to the Instagram app")
            decisionHandler(.cancel)
            if isSignedIn != true, webView.url?.path.hasPrefix("/accounts") != true {
                webView.load(URLRequest(url: Routes.login))
            }
            return
        }

        guard Routes.isFamily(url) else {
            log.add("nav", "external \(url.redacted)")
            decisionHandler(.cancel)
            externalLink = ExternalLink(url: url)
            return
        }

        // The endless viewer is refused. A single clip loads; the filter keeps it alone.
        if store.settings.blockReelsFeed, Routes.classify(url) == .feed {
            decisionHandler(.cancel)
            registerBlock(path: Routes.shape(path: url.path), via: "load")
            if webView.url == nil { loadHome() }
            return
        }

        // A tapped link to another host of the family (instagram.com without www, l.instagram.com)
        // is a universal link: WebKit would hand it to the Instagram app, if installed, and the
        // app would leave the front. Loaded by the app itself, it stays here.
        if navigationAction.navigationType == .linkActivated,
           let host = url.host?.lowercased(), host != webView.url?.host?.lowercased() {
            log.add("nav", "link to another host, loaded here: \(url.redacted)")
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
            return
        }

        log.add("nav", "allow \(url.redacted) (\(navigationAction.navigationType.rawValue))")
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            let type = response.value(forHTTPHeaderField: "Content-Type") ?? "?"
            log.add("page", "response \(response.statusCode) \(response.url?.redacted ?? "?") (\(type))")
            mainFrameStatus = response.statusCode
        }
        // A file the page cannot show (a data export, an attachment): download it and offer it
        // to share or save, instead of a blank page.
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType {
            log.add("page", "download \(navigationResponse.response.mimeType ?? "?")")
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        failure = nil
        // The launch cover stays until the page reports something to show ("drawn"); this is
        // the limit for a page that never does.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.revealPage()
        }
        // Off Instagram (a sign-in step on facebook.com) the filter does not run: plain black.
        if let url = webView.url, !Routes.isInstagram(url) {
            topEdgeColor = .black
            bottomEdgeColor = .black
        }
        log.add("page", "commit \(webView.url?.redacted ?? "?")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        log.add("page", "finish \(webView.url?.redacted ?? "?")")
        refreshSignInState()
        // An error status with nothing in the page would be a blank screen: say what happened.
        if mainFrameStatus >= 400 {
            let status = mainFrameStatus
            webView.evaluateJavaScript("document.body ? document.body.children.length : 0") { [weak self] value, _ in
                let isEmpty = (value as? NSNumber)?.intValue ?? 0 == 0
                Task { @MainActor [weak self] in
                    guard isEmpty, let self else { return }
                    self.failure = .http(status)
                    self.revealPage()
                }
            }
        }
        // Instagram draws its pages with JavaScript after the load finishes: look twice.
        probePage("content at finish")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.probePage("content 4 s later")
        }
        if userAgent.isEmpty {
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
                let text = value as? String ?? ""
                Task { @MainActor [weak self] in self?.userAgent = text }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, stage: "load")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, stage: "connect")
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS reclaimed the page's memory. In front: load it again now. In the background: wait
        // for the app to come back, so that nothing loads while it cannot be seen, and once.
        mainFrameStatus = 200
        if UIApplication.shared.applicationState == .active {
            log.add("page", "web content process ended: reloading")
            reload()
        } else {
            log.add("page", "web content process ended in the background: reloading when back in front")
            reloadWhenActive = true
        }
    }
}

// MARK: - WKUIDelegate

extension BrowserModel: WKUIDelegate {
    /// Links that ask for a new window open in this one, or in the Safari sheet if they leave
    /// Instagram. A second web view is never created.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if Routes.isFamily(url) {
            log.add("nav", "new window, opened here: \(url.redacted)")
            webView.load(navigationAction.request)
        } else if url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" {
            log.add("nav", "new window, external: \(url.redacted)")
            externalLink = ExternalLink(url: url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let presenter = topViewController() else {
                continuation.resume()
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume() })
            presenter.present(alert, animated: true)
        }
    }

    /// Camera and microphone, for a story, a voice message or a call. Instagram's own pages get
    /// them without WebKit's extra dialog; iOS still asks its own permission the first time,
    /// and the switches in Settings still apply. Any other site asks.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let host = origin.host.lowercased()
        let trusted = host == "instagram.com" || host.hasSuffix(".instagram.com")
        log.add("media", "\(trusted ? "granted" : "asked") capture (\(type.rawValue)) for \(host)")
        return trusted ? .grant : .prompt
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            guard let presenter = topViewController() else {
                continuation.resume(returning: nil)
                return
            }
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                continuation.resume(returning: alert?.textFields?.first?.text ?? "")
            })
            presenter.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            guard let presenter = topViewController() else {
                continuation.resume(returning: false)
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
    }
}

// MARK: - WKScriptMessageHandler

extension BrowserModel: WKScriptMessageHandler {
    /// Messages from instagram.js. The page could send these too, so they are only ever counted
    /// and logged, never trusted to do anything.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["t"] as? String else { return }
        let path = Routes.shape(path: String((body["path"] as? String ?? "").prefix(200)))
        let via = String((body["via"] as? String ?? "").prefix(20))

        switch type {
        case "ready":
            log.add("filter", "running on \(path)")
        case "route":
            log.add("route", "\(path) (\(via))")
        case "blocked":
            registerBlock(path: path, via: via)
        case "held":
            // A swipe from an opened clip towards the next reel was held back.
            blockedCount += 1
            log.add("block", "swipe held on \(path)")
            toast = Toast(text: "Other reels are hidden", symbol: "shield.lefthalf.filled")
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case "hidden":
            if let count = body["n"] as? Int, count > 0, count < 1000 {
                hiddenCount += count
                log.add("filter", "hid \(count) element\(count == 1 ? "" : "s")")
            }
        case "bar":
            // The account's own page arrives here for the Profile button: kept, never logged.
            if let profile = body["profile"] as? String, profile.hasPrefix("/"), profile.hasSuffix("/"), profile.count < 64 {
                profilePath = profile
            }
            if (body["present"] as? Bool) == true, !barDetected {
                barDetected = true
                UserDefaults.standard.set(true, forKey: Self.barDetectedKey)
                log.add("bar", "Instagram's bar found: the native bar takes its place")
            }
            if let unread = (body["unread"] as? NSNumber)?.intValue, unread >= 0, unread < 1000, unread != unreadMessages {
                unreadMessages = unread
                let inboxInFront = store.platform == .instagram && currentPath.hasPrefix("/direct")
                    && UIApplication.shared.applicationState == .active
                notifier?.instagramUnread(unread, enabled: store.settings.notifyInstagram, onScreen: inboxInFront)
                log.add("bar", "unread on the messages button: \(unread)")
            }
        case "drawn":
            revealPage()
            // A moment later the feed has its pictures: keep how it looks for the next launch.
            if path == "/" {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    self?.captureLaunchImage()
                }
            }
        case "transition":
            if (body["kind"] as? String) == "push" { animatePush() }
        case "structure":
            // What a full-screen video sits in: tags, roles, sizes. Long, so in several lines.
            var rest = Substring((body["text"] as? String ?? "").prefix(1800))
            while !rest.isEmpty {
                log.add("clip", String(rest.prefix(280)))
                rest = rest.dropFirst(280)
            }
        case "edges":
            let top = Self.edgeColor(body["top"])
            let bottom = Self.edgeColor(body["bottom"])
            if top != topEdgeColor { topEdgeColor = top }
            if bottom != bottomEdgeColor { bottomEdgeColor = bottom }
        case "log":
            log.add("filter", body["text"] as? String ?? "")
        default:
            break
        }
    }
}

// MARK: - WKDownloadDelegate

extension BrowserModel: WKDownloadDelegate {
    private static var downloadsFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let folder = Self.downloadsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let destination = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        downloadDestinations[ObjectIdentifier(download)] = destination
        toast = Toast(text: "Downloading \(name)", symbol: "arrow.down.circle")
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        log.add("page", "download finished")
        // The file is only in the app's temporary folder: the share sheet is the way to keep it
        // (Save to Files, AirDrop, another app).
        guard let presenter = topViewController() else { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        presenter.present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        log.add("error", "download: \((error as NSError).localizedDescription)")
        toast = Toast(text: "Download failed", symbol: "exclamationmark.circle")
    }
}
