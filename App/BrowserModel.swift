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
    /// nil until the cookies were looked at once.
    @Published private(set) var isSignedIn: Bool?
    @Published private(set) var hiddenCount = 0
    @Published private(set) var blockedCount = 0
    @Published var toast: Toast?
    /// A link to another website, shown in a Safari sheet.
    @Published var externalLink: ExternalLink?

    private let store: SettingsStore
    private let log = DiagnosticsLog.shared
    private var subscriptions = Set<AnyCancellable>()
    private let refreshControl = UIRefreshControl()
    private var started = false
    private var userAgent = ""
    private var recentBlocks: [Date] = []
    private var rewrittenClips: [String: Date] = [:]
    private var bouncedClips = Set<String>()

    private static let messageHandlerName = "scrollGuard"

    init(store: SettingsStore) {
        self.store = store

        let configuration = WKWebViewConfiguration()
        // The persistent store: cookies and site data stay between launches, as in Safari.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        // As in Safari: silent video may start by itself, sound needs a tap.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        // The User-Agent is left exactly as WebKit sets it.
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.overrideUserInterfaceStyle = .dark
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.underPageBackgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // The view is laid out inside the safe area already; no extra insets.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
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
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &subscriptions)
    }

    // MARK: - Commands from the views

    /// Loads Instagram once, when the main view first appears.
    func start() {
        guard !started else { return }
        started = true
        log.add("app", "ScrollGuard \(DeviceInfo.appVersion), \(DeviceInfo.system), \(DeviceInfo.model)")
        log.add("app", "settings \(store.settings.json)")
        loadHome()
    }

    func loadHome() {
        failure = nil
        webView.load(URLRequest(url: Routes.home))
    }

    func reload() {
        failure = nil
        if webView.url == nil { loadHome() } else { webView.reload() }
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
        isSignedIn = false
        loadHome()
    }

    /// Whether Instagram's session cookie exists. Only the cookie's name and site are looked at.
    func refreshSignInState() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let signedIn = cookies.contains { cookie in
                cookie.name == "sessionid" && cookie.domain.hasSuffix("instagram.com") && !cookie.value.isEmpty
            }
            Task { @MainActor [weak self] in
                guard let self, self.isSignedIn != signedIn else { return }
                self.isSignedIn = signedIn
                self.log.add("app", "instagram session cookie: \(signedIn ? "present" : "absent")")
            }
        }
    }

    /// The text behind "Copy report" in Diagnostics.
    func report() -> String {
        var lines = [
            "ScrollGuard \(DeviceInfo.appVersion)",
            "\(DeviceInfo.system) · \(DeviceInfo.model)",
            "User-Agent: \(userAgent.isEmpty ? "(not read yet)" : userAgent)",
            "Signed in: \(isSignedIn.map { $0 ? "yes" : "no" } ?? "unknown")",
            "Settings: \(store.settings.json)",
            "Page: \(webView.url?.redacted ?? "(none)")",
            "Hidden elements: \(hiddenCount) · Blocked: \(blockedCount)"
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
    private static func filterSource(settings: FilterSettings) -> String? {
        guard let scriptURL = Bundle.main.url(forResource: "instagram", withExtension: "js"),
              let styleURL = Bundle.main.url(forResource: "instagram", withExtension: "css"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let style = try? String(contentsOf: styleURL, encoding: .utf8),
              let styleData = try? JSONEncoder().encode(style),
              let styleLiteral = String(data: styleData, encoding: .utf8) else { return nil }
        return script
            .replacingOccurrences(of: "__SG_CONFIG__", with: settings.json)
            .replacingOccurrences(of: "__SG_CSS__", with: styleLiteral)
    }

    private func installFilterScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        guard let source = Self.filterSource(settings: store.settings) else {
            log.add("error", "filter files are missing from the app bundle")
            return
        }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// A switch changed: pages loaded from now on get the new values, and the page on screen is
    /// updated in place, without a reload.
    private func settingsChanged() {
        log.add("app", "settings \(store.settings.json)")
        installFilterScript()
        let update = "window.__scrollGuard && window.__scrollGuard.configure(\(store.settings.json)); true;"
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

    /// In-page navigation never reaches the navigation delegate; the page script handles it.
    /// This is the safety net: if the script did not leave a Reels page within a moment (it is
    /// missing, or Instagram changed under it), the app leaves it.
    private func urlChanged(_ url: URL?) {
        guard let url, store.settings.blockReelsFeed, Routes.classify(url) == .feed else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.store.settings.blockReelsFeed,
                  let current = self.webView.url, Routes.classify(current) == .feed else { return }
            self.registerBlock(path: current.path, via: "native")
            if self.webView.canGoBack { self.webView.goBack() } else { self.loadHome() }
        }
    }

    @objc private func pulledToRefresh() {
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
            // instagram://, itms-apps://, mailto:, tel: — attempts to leave for another app.
            log.add("nav", "ignored \(scheme): link")
            decisionHandler(.cancel)
            return
        }
        // Only the page itself is steered. Frames inside it (players, security checks) are the site's.
        guard navigationAction.targetFrame?.isMainFrame ?? true else {
            decisionHandler(.allow)
            return
        }

        guard Routes.isFamily(url) else {
            log.add("nav", "external \(url.redacted)")
            decisionHandler(.cancel)
            externalLink = ExternalLink(url: url)
            return
        }

        let settings = store.settings
        switch Routes.classify(url) {
        case .feed? where settings.blockReelsFeed:
            decisionHandler(.cancel)
            registerBlock(path: url.path, via: "load")
            if webView.url == nil { loadHome() }
            return
        case .clip(let id)? where settings.clipsAsPosts && !bouncedClips.contains(id):
            if let rewrittenAt = rewrittenClips[id], Date().timeIntervalSince(rewrittenAt) < 5 {
                // Instagram sent the post page straight back to the reel page: leave this clip alone.
                bouncedClips.insert(id)
                log.add("nav", "clip \(id) came back from /p/: left as a reel page")
            } else {
                rewrittenClips[id] = Date()
                log.add("nav", "clip as post \(url.redacted)")
                decisionHandler(.cancel)
                webView.load(URLRequest(url: Routes.postURL(clipID: id)))
                return
            }
        default:
            break
        }

        log.add("nav", "allow \(url.redacted)")
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        failure = nil
        hasShownFirstPage = true
        log.add("page", "commit \(webView.url?.redacted ?? "?")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        log.add("page", "finish \(webView.url?.redacted ?? "?")")
        refreshSignInState()
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

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS reclaimed the page's memory while the app was in the background: load it again.
        log.add("page", "web content process ended: reloading")
        reload()
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
        let path = String((body["path"] as? String ?? "").prefix(120))
        let via = String((body["via"] as? String ?? "").prefix(20))

        switch type {
        case "ready":
            log.add("filter", "running on \(path)")
        case "route":
            log.add("route", "\(path) (\(via))")
        case "blocked":
            registerBlock(path: path, via: via)
        case "rewrite":
            log.add("filter", "clip as post \(path) (\(via))")
        case "hidden":
            if let count = body["n"] as? Int, count > 0, count < 1000 {
                hiddenCount += count
                log.add("filter", "hid \(count) element\(count == 1 ? "" : "s")")
            }
        case "log":
            log.add("filter", body["text"] as? String ?? "")
        default:
            break
        }
    }
}
