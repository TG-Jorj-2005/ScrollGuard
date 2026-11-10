import SafariServices
import SwiftUI
import UIKit
import WebKit

/// The whole screen: Instagram, edge to edge, with nothing of a browser around it. No address
/// bar, no toolbar, no second tab bar — Instagram's own bar at the bottom is the only one.
///
/// The strip behind the clock and the Dynamic Island belongs to the app:
///   - tap it to scroll to the top;
///   - touch and hold it to open the ScrollGuard panel.
struct RootView: View {
    @EnvironmentObject private var browser: BrowserModel
    /// Observed so that flipping a switch in the panel redraws this view (the native bar).
    @EnvironmentObject private var store: SettingsStore
    @State private var showPanel = false
    @State private var showHint = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                StatusStrip(color: Color(uiColor: browser.topEdgeColor),
                            onTap: { browser.scrollToTop() }, onHold: openPanel)
                    .frame(height: geometry.safeAreaInsets.top)

                ZStack(alignment: .top) {
                    WebContainer(webView: browser.webView)

                    if let failure = browser.failure {
                        FailureView(failure: failure, retry: { browser.reload() })
                            .transition(.opacity)
                    }
                    if !browser.hasShownFirstPage {
                        LaunchCover()
                            .transition(.opacity)
                    }

                    ProgressLine(progress: browser.progress, isLoading: browser.isLoading)

                    VStack(spacing: 8) {
                        if let toast = browser.toast {
                            Pill(text: toast.text, symbol: toast.symbol)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                        if showHint {
                            // Which build this is, for a few seconds after launch. Tapping it
                            // opens the panel, like touching and holding the top edge.
                            Button(action: openPanel) {
                                Pill(text: "ScrollGuard \(DeviceInfo.appVersion) · tap for the panel",
                                     symbol: "shield.lefthalf.filled")
                            }
                            .buttonStyle(.plain)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 10)
                }

                if browser.showsNativeBar {
                    NativeBar(active: browser.activeTab, color: Color(uiColor: browser.bottomEdgeColor)) { tab in
                        browser.select(tab)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .animation(.spring(response: 0.32, dampingFraction: 0.9), value: browser.showsNativeBar)
        }
        // What shows under the home indicator: the colour of the page's bottom edge.
        .background(Color(uiColor: browser.bottomEdgeColor).ignoresSafeArea())
        // Like Safari: the keyboard covers the page instead of squeezing it; Instagram's own
        // layout already moves the message box above the keyboard.
        .ignoresSafeArea(.keyboard)
        .animation(.easeOut(duration: 0.25), value: browser.topEdgeColor)
        .animation(.easeOut(duration: 0.25), value: browser.bottomEdgeColor)
        .animation(.easeOut(duration: 0.35), value: browser.hasShownFirstPage)
        .animation(.easeOut(duration: 0.25), value: browser.failure)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: browser.toast)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showHint)
        .sheet(isPresented: $showPanel) {
            ControlPanel()
        }
        .sheet(item: $browser.externalLink) { link in
            SafariView(url: link.url)
                .ignoresSafeArea()
        }
        .task(id: browser.toast?.id) {
            guard browser.toast != nil else { return }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { browser.toast = nil }
        }
        .task(id: browser.hasShownFirstPage) {
            // After each launch, briefly: the build that is running and the way into the panel.
            guard browser.hasShownFirstPage else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            showHint = true
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            showHint = false
        }
        .onAppear {
            browser.start()
            // For the simulator check in GitHub Actions: a launch argument opens the panel, so a
            // screenshot can show it. Never set on the phone.
            if UserDefaults.standard.bool(forKey: "debugShowPanel") { showPanel = true }
        }
    }

    private func openPanel() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showHint = false
        showPanel = true
    }
}

/// The area behind the status bar, in the colour of the page under it.
private struct StatusStrip: View {
    let color: Color
    let onTap: () -> Void
    let onHold: () -> Void

    var body: some View {
        color
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.35, perform: onHold)
            .accessibilityLabel("ScrollGuard")
            .accessibilityHint("Touch and hold to open the ScrollGuard panel")
    }
}

/// The native bottom bar: Instagram's destinations without Reels. It is drawn in the colour of
/// the page's bottom edge, so it reads as part of the page, but it never flickers or jumps when
/// the page changes, and its buttons answer at once.
private struct NativeBar: View {
    let active: BrowserModel.Tab?
    let color: Color
    let select: (BrowserModel.Tab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BrowserModel.Tab.allCases, id: \.self) { tab in
                Button {
                    select(tab)
                } label: {
                    Image(systemName: symbol(for: tab))
                        .font(.system(size: 23, weight: tab == active ? .semibold : .regular))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(for: tab))
            }
        }
        .foregroundStyle(.white)
        .frame(height: 49)
        .background(color)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 0.5)
        }
    }

    private func symbol(for tab: BrowserModel.Tab) -> String {
        let isActive = tab == active
        switch tab {
        case .home: return isActive ? "house.fill" : "house"
        case .search: return "magnifyingglass"
        case .messages: return isActive ? "paperplane.fill" : "paperplane"
        case .profile: return isActive ? "person.crop.circle.fill" : "person.crop.circle"
        }
    }

    private func label(for tab: BrowserModel.Tab) -> String {
        switch tab {
        case .home: return "Home"
        case .search: return "Search"
        case .messages: return "Messages"
        case .profile: return "Profile"
        }
    }
}

/// A two-point line under the status strip while a page loads, instead of a spinner.
private struct ProgressLine: View {
    let progress: Double
    let isLoading: Bool

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: max(0, geometry.size.width * progress))
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2)
        .opacity(isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: isLoading)
        .allowsHitTesting(false)
    }
}

/// A short message that floats over the page and leaves by itself.
private struct Pill: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

/// Covers the empty web view from launch until the first page is on screen.
private struct LaunchCover: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
                .opacity(pulse ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        }
        .onAppear { pulse = true }
    }
}

/// Shown instead of the page when nothing could be loaded at all.
private struct FailureView: View {
    let failure: BrowserModel.Failure
    let retry: () -> Void

    private var title: String {
        switch failure {
        case .offline: return "No connection"
        case .http: return "Instagram isn't answering"
        case .other: return "Couldn't open Instagram"
        }
    }

    private var detail: String {
        switch failure {
        case .offline:
            return "Check Wi-Fi or mobile data, then try again."
        case .http(429):
            return "Instagram is limiting requests from this connection (error 429). Wait a minute, then try again."
        case .http(let status):
            return "Instagram answered with error \(status). Try again in a moment."
        case .other(let message):
            return message
        }
    }

    private var symbol: String {
        if case .http = failure { return "hourglass" }
        return "wifi.slash"
    }

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            .padding(32)
        }
    }
}

/// Places the model's web view into the SwiftUI layout. The web view itself is created once, by
/// BrowserModel; if SwiftUI rebuilds this container, the same web view moves into the new one.
struct WebContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

/// A link that leaves Instagram opens here, in Apple's in-app Safari, and closes back to the app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
