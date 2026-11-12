import Combine
import UIKit
import WebKit

/// The YouTube web view, kept for the app's whole life next to Instagram's: m.youtube.com with
/// the Shorts filter (Web/youtube.js). A smaller twin of BrowserModel: the same page states for
/// the views, its own cookies and history, nothing shared with Instagram.
///
/// Google sign-in is left entirely to Google's own pages. The User-Agent is never changed.
@MainActor
final class YouTubeModel: NSObject, ObservableObject {
    typealias Failure = BrowserModel.Failure
    typealias Toast = BrowserModel.Toast
    typealias ExternalLink = BrowserModel.ExternalLink

    static let home = URL(string: "https://m.youtube.com/")!

    let webView: WKWebView

    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var hasShownFirstPage = false
    @Published private(set) var failure: Failure?
    @Published private(set) var hiddenCount = 0
    @Published private(set) var blockedCount = 0
    @Published var toast: Toast?
    @Published var externalLink: ExternalLink?

    private let store: SettingsStore
    private let log = DiagnosticsLog.shared
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var reloadWhenActive = false
    private let refreshControl = UIRefreshControl()
    private static let messageHandlerName = "scrollGuard"
    /// A store of its own, kept between launches: YouTube's cookies never meet Instagram's.
    private static let dataStoreID = UUID(uuidString: "8C0F4C5E-5B0B-4C8A-9D6A-2B7E2C9A1F10")!

    /// Sites that stay inside the app: YouTube and what its pages, players and sign-in use.
    private static let familyDomains = [
        "youtube.com", "youtu.be", "youtube-nocookie.com", "google.com", "googleusercontent.com",
        "googlevideo.com", "ggpht.com", "ytimg.com", "gstatic.com", "googleapis.com", "youtube.googleapis.com"
    ]

    init(store: SettingsStore) {
        self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.overrideUserInterfaceStyle = .dark
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.isInspectable = true

        refreshControl.tintColor = UIColor(white: 1, alpha: 0.6)
        refreshControl.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        webView.configuration.userContentController.add(self, name: Self.messageHandlerName)
        installFilterScript()

        webView.publisher(for: \.estimatedProgress).receive(on: RunLoop.main)
            .sink { [weak self] value in self?.progress = value }
            .store(in: &subscriptions)
        webView.publisher(for: \.isLoading).receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.isLoading = value
                if !value { self?.refreshControl.endRefreshing() }
            }
            .store(in: &subscriptions)
        webView.publisher(for: \.url).receive(on: RunLoop.main)
            .sink { [weak self] url in self?.urlChanged(url) }
            .store(in: &subscriptions)
        store.$settings.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyFilterConfig() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.becameActive() }
            .store(in: &subscriptions)
    }

    // MARK: - Commands from the views

    /// Loads YouTube the first time it is shown; nothing is loaded while it is not wanted.
    func start() {
        guard !started else { return }
        started = true
        log.add("yt", "start")
        loadHome()
    }

    func loadHome() {
        webView.load(URLRequest(url: Self.home))
    }

    func reload() {
        failure = nil
        if webView.url == nil { loadHome() } else { webView.reload() }
    }

    func scrollToTop() {
        let scrollView = webView.scrollView
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: true)
    }

    /// Cookies, caches and site storage of YouTube only: signs out of Google here.
    func clearBrowsingData() async {
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                                 modifiedSince: .distantPast)
        log.add("yt", "browsing data cleared")
        loadHome()
    }

    // MARK: - Filter

    private var filterConfig: String { "{\"hideShorts\":\(store.settings.hideShorts)}" }

    private func installFilterScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        guard let scriptURL = Bundle.main.url(forResource: "youtube", withExtension: "js"),
              let styleURL = Bundle.main.url(forResource: "youtube", withExtension: "css"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let style = try? String(contentsOf: styleURL, encoding: .utf8),
              let styleData = try? JSONEncoder().encode(style),
              let styleLiteral = String(data: styleData, encoding: .utf8) else {
            log.add("error", "youtube filter files are missing from the app bundle")
            return
        }
        let source = script
            .replacingOccurrences(of: "__SG_CONFIG__", with: filterConfig)
            .replacingOccurrences(of: "__SG_CSS__", with: styleLiteral)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    private func applyFilterConfig() {
        installFilterScript()
        let update = "window.__scrollGuard && window.__scrollGuard.configure(\(filterConfig)); true;"
        webView.evaluateJavaScript(update) { _, _ in }
    }

    // MARK: - State

    static func isYouTube(_ url: URL) -> Bool { host(url, isIn: ["youtube.com", "youtu.be"]) }
    static func isFamily(_ url: URL) -> Bool { host(url, isIn: familyDomains) }

    private static func host(_ url: URL, isIn domains: [String]) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The Shorts viewer: /shorts and anything under it. The same rule as `isShortsPath` in
    /// Web/youtube.js: this copy handles full page loads, the script handles in-page navigation.
    static func isShorts(_ url: URL) -> Bool {
        guard isYouTube(url) else { return false }
        let parts = url.path.split(separator: "/")
        return parts.first?.lowercased() == "shorts"
    }

    /// Where a pull reloads: the page itself scrolls everywhere but on a video page, where the
    /// player stands still and pulling would stop it.
    private var allowsPullToRefresh: Bool {
        guard let url = webView.url, Self.isYouTube(url) else { return true }
        return url.path != "/watch"
    }

    private func urlChanged(_ url: URL?) {
        guard let url else { return }
        let wanted = allowsPullToRefresh ? refreshControl : nil
        if webView.scrollView.refreshControl !== wanted { webView.scrollView.refreshControl = wanted }
        // The safety net under the script: a page that is still the Shorts viewer after a
        // moment is left.
        guard store.settings.hideShorts, Self.isShorts(url) else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.store.settings.hideShorts, let current = self.webView.url, Self.isShorts(current) else { return }
            self.registerBlock(via: "native")
            if self.webView.canGoBack { self.webView.goBack() } else { self.loadHome() }
        }
    }

    @objc private func pulledToRefresh() {
        log.add("yt", "pulled to refresh")
        reload()
    }

    private func becameActive() {
        guard reloadWhenActive else { return }
        reloadWhenActive = false
        log.add("yt", "back in front: reloading the page lost in the background")
        reload()
    }

    private func registerBlock(via: String) {
        blockedCount += 1
        log.add("block", "shorts (\(via))")
        toast = Toast(text: "Shorts are hidden", symbol: "shield.lefthalf.filled")
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    private func showLoadError(_ error: Error, stage: String) {
        refreshControl.endRefreshing()
        let nsError = error as NSError
        log.add("error", "yt \(stage): \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204) { return }
        let offlineCodes = [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
            NSURLErrorInternationalRoamingOff, NSURLErrorTimedOut, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed
        ]
        let offline = nsError.domain == NSURLErrorDomain && offlineCodes.contains(nsError.code)
        if webView.url == nil {
            failure = offline ? .offline : .other(nsError.localizedDescription)
            hasShownFirstPage = true
        } else {
            toast = Toast(text: offline ? "No connection" : "Couldn't open the page", symbol: "wifi.slash")
        }
    }
}

// MARK: - WKNavigationDelegate

extension YouTubeModel: WKNavigationDelegate {
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
            // youtube://, itms-apps:// and the like: attempts to leave for another app.
            decisionHandler(.cancel)
            log.add("yt", "ignored \(scheme): link")
            return
        }
        guard navigationAction.targetFrame?.isMainFrame ?? true else {
            decisionHandler(.allow)
            return
        }
        let host = url.host?.lowercased() ?? ""
        if host == "apps.apple.com" || host == "itunes.apple.com" {
            log.add("yt", "ignored a link to the App Store")
            decisionHandler(.cancel)
            return
        }
        guard Self.isFamily(url) else {
            log.add("yt", "external \(host)")
            decisionHandler(.cancel)
            externalLink = ExternalLink(url: url)
            return
        }
        if store.settings.hideShorts, Self.isShorts(url) {
            decisionHandler(.cancel)
            registerBlock(via: "load")
            if webView.url == nil { loadHome() }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        failure = nil
        // The site and, on YouTube, the path's first part: no video ids, no search terms.
        let url = webView.url
        let head = url.map { Self.isYouTube($0) ? "/" + ($0.path.split(separator: "/").first.map(String.init) ?? "") : "" } ?? ""
        log.add("yt", "commit \(url?.host ?? "?")\(head)")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.revealPage()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        revealPage()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, stage: "load")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, stage: "connect")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if UIApplication.shared.applicationState == .active {
            log.add("yt", "web content process ended: reloading")
            reload()
        } else {
            log.add("yt", "web content process ended in the background: reloading when back in front")
            reloadWhenActive = true
        }
    }

    private func revealPage() {
        if !hasShownFirstPage { hasShownFirstPage = true }
    }
}

// MARK: - WKUIDelegate

extension YouTubeModel: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if Self.isFamily(url) {
            webView.load(navigationAction.request)
        } else if url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" {
            externalLink = ExternalLink(url: url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let presenter = Self.topViewController() else {
                continuation.resume()
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume() })
            presenter.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            guard let presenter = Self.topViewController() else {
                continuation.resume(returning: false)
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - WKScriptMessageHandler

extension YouTubeModel: WKScriptMessageHandler {
    /// Messages from youtube.js: counted and logged only, never trusted to do anything.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["t"] as? String else { return }
        switch type {
        case "blocked":
            registerBlock(via: String((body["via"] as? String ?? "").prefix(20)))
        case "hidden":
            if let count = body["n"] as? Int, count > 0, count < 1000 {
                hiddenCount += count
                log.add("filter", "yt hid \(count) element\(count == 1 ? "" : "s")")
            }
        case "drawn":
            revealPage()
        default:
            break
        }
    }
}
