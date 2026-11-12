import SafariServices
import SwiftUI
import UIKit
import WebKit

/// The whole screen: Instagram, edge to edge, with nothing of a browser around it. No address
/// bar, no toolbar, no second tab bar — Instagram's own bar at the bottom is the only one.
///
/// The strip behind the clock and the Dynamic Island belongs to the app:
///   - tap it to scroll to the top;
///   - touch and hold it to open the ScrollGuard panel (the round button at the right edge does too).
struct RootView: View {
    @EnvironmentObject private var browser: BrowserModel
    @EnvironmentObject private var youtube: YouTubeModel
    /// Observed so that flipping a switch in the panel redraws this view (the native bar).
    @EnvironmentObject private var store: SettingsStore
    @State private var showPanel = false
    @State private var showHint = false

    private var onYouTube: Bool { store.platform == .youtube }
    // The state of whichever site is on screen.
    private var progress: Double { onYouTube ? youtube.progress : browser.progress }
    private var isLoading: Bool { onYouTube ? youtube.isLoading : browser.isLoading }
    private var failure: BrowserModel.Failure? { onYouTube ? youtube.failure : browser.failure }
    private var hasShownFirstPage: Bool { onYouTube ? youtube.hasShownFirstPage : browser.hasShownFirstPage }
    private var toast: BrowserModel.Toast? { onYouTube ? youtube.toast : browser.toast }
    private var topEdgeColor: UIColor { onYouTube ? .black : browser.topEdgeColor }
    private var bottomEdgeColor: UIColor { onYouTube ? .black : browser.bottomEdgeColor }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                StatusStrip(color: Color(uiColor: topEdgeColor),
                            onTap: { onYouTube ? youtube.scrollToTop() : browser.scrollToTop() },
                            onHold: openPanel, onSwipe: { switchPlatform() })
                    .frame(height: geometry.safeAreaInsets.top)

                ZStack(alignment: .top) {
                    // Both web views stay in the layout, so switching never reloads either.
                    WebContainer(webView: browser.webView)
                        .opacity(onYouTube ? 0 : 1)
                        .scaleEffect(onYouTube ? 0.96 : 1)
                        .allowsHitTesting(!onYouTube)
                    WebContainer(webView: youtube.webView)
                        .opacity(onYouTube ? 1 : 0)
                        .scaleEffect(onYouTube ? 1 : 0.96)
                        .allowsHitTesting(onYouTube)

                    if let failure {
                        FailureView(site: store.platform.title, failure: failure,
                                    retry: { onYouTube ? youtube.reload() : browser.reload() })
                            .transition(.opacity)
                    }
                    if !hasShownFirstPage {
                        LaunchCover(image: onYouTube ? nil : browser.launchImage)
                            .transition(.opacity)
                    }

                    ProgressLine(progress: progress, isLoading: isLoading)

                    VStack(spacing: 8) {
                        if let toast {
                            Pill(text: toast.text, symbol: toast.symbol)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                        if showHint {
                            // Which build this is, for a few seconds after launch. Tapping it
                            // opens the panel, like touching and holding the top edge.
                            Button(action: openPanel) {
                                Pill(text: "ScrollGuard \(DeviceInfo.appVersion) · the round button opens the panel",
                                     symbol: "shield.lefthalf.filled")
                            }
                            .buttonStyle(.plain)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 10)
                }
                .overlay { MenuButton(action: openPanel) }

                if !onYouTube, browser.showsNativeBar {
                    NativeBar(active: browser.activeTab, unread: browser.unreadMessages,
                              color: Color(uiColor: browser.bottomEdgeColor)) { tab in
                        browser.select(tab)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .animation(.spring(response: 0.32, dampingFraction: 0.9), value: browser.showsNativeBar)
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: store.platform)
        }
        // What shows under the home indicator: the colour of the page's bottom edge.
        .background(Color(uiColor: bottomEdgeColor).ignoresSafeArea())
        // Like Safari: the keyboard covers the page instead of squeezing it; Instagram's own
        // layout already moves the message box above the keyboard.
        .ignoresSafeArea(.keyboard)
        .animation(.easeOut(duration: 0.25), value: topEdgeColor)
        .animation(.easeOut(duration: 0.25), value: bottomEdgeColor)
        .animation(.easeOut(duration: 0.35), value: hasShownFirstPage)
        .animation(.easeOut(duration: 0.25), value: failure)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toast)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showHint)
        .onChange(of: showPanel) { _, shown in DiagnosticsLog.shared.add("ui", shown ? "panel opened" : "panel closed") }
        .onChange(of: browser.externalLink?.id) { _, id in
            DiagnosticsLog.shared.add("ui", id == nil ? "safari sheet closed" : "safari sheet for \(browser.externalLink?.url.host ?? "?")")
        }
        .sheet(isPresented: $showPanel) {
            ControlPanel()
        }
        .sheet(item: $browser.externalLink) { link in
            SafariView(url: link.url)
                .ignoresSafeArea()
        }
        .sheet(item: $youtube.externalLink) { link in
            SafariView(url: link.url)
                .ignoresSafeArea()
        }
        .task(id: browser.toast?.id) {
            guard browser.toast != nil else { return }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { browser.toast = nil }
        }
        .task(id: youtube.toast?.id) {
            guard youtube.toast != nil else { return }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { youtube.toast = nil }
        }
        .onChange(of: store.platform, initial: true) { _, platform in
            if platform == .youtube { youtube.start() }
        }
        .task(id: browser.hasShownFirstPage) {
            // On the first start after an update, briefly: which version this is, and the way
            // into the panel.
            guard browser.hasShownFirstPage, browser.showsVersionLabel else { return }
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

    /// A swipe across the top edge: the other site, with its page as it was left.
    private func switchPlatform() {
        UISelectionFeedbackGenerator().selectionChanged()
        store.platform = onYouTube ? .instagram : .youtube
    }
}

/// The way into the panel from any page: a small button at the right edge, over the page. It
/// can be dragged up or down, out of the way of whatever it covers, and stays where it was put.
private struct MenuButton: View {
    let action: () -> Void
    /// Where it rests, as a fraction of the page's height. Low on the right by default: above
    /// the bars at the bottom, below where YouTube's player and Instagram's stories are.
    @AppStorage("menuButtonY") private var restingFraction: Double = 0.7
    @State private var dragOffset: CGFloat = 0
    @GestureState private var isDragging = false

    private let size: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let lowest = max(size / 2 + 70, height - size / 2 - 80)
            let restingY = min(max(height * restingFraction, size / 2 + 70), lowest)
            Button(action: action) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14)))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .scaleEffect(isDragging ? 1.1 : 1)
            }
            .buttonStyle(.plain)
            .opacity(0.9)
            .position(x: geometry.size.width - size / 2 - 10, y: restingY + dragOffset)
            // Only the button itself is dragged: the page around it is never touched.
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in dragOffset = value.translation.height }
                    .onEnded { value in
                        let y = min(max(restingY + value.translation.height, size / 2 + 70), lowest)
                        restingFraction = height > 0 ? y / height : restingFraction
                        dragOffset = 0
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDragging)
            .accessibilityLabel("ScrollGuard")
            .accessibilityHint("Opens the ScrollGuard panel")
        }
    }
}

/// The area behind the status bar, in the colour of the page under it.
private struct StatusStrip: View {
    let color: Color
    let onTap: () -> Void
    let onHold: () -> Void
    let onSwipe: () -> Void

    var body: some View {
        color
            .contentShape(Rectangle())
            .onTapGesture {
                DiagnosticsLog.shared.add("ui", "top edge tapped")
                onTap()
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                DiagnosticsLog.shared.add("ui", "top edge held")
                onHold()
            }
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                if abs(dx) > 50, abs(dx) > abs(dy) * 2 {
                    DiagnosticsLog.shared.add("ui", "top edge swiped: other site")
                    onSwipe()
                }
            })
            .accessibilityLabel("ScrollGuard")
            .accessibilityHint("Touch and hold to open the ScrollGuard panel")
    }
}

/// The native bottom bar: Instagram's destinations without Reels. It is drawn in the colour of
/// the page's bottom edge, so it reads as part of the page, but it never flickers or jumps when
/// the page changes, and its buttons answer at once.
private struct NativeBar: View {
    let active: BrowserModel.Tab?
    /// Unread conversations, as Instagram's own button counts them.
    let unread: Int
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
                        .overlay(alignment: .topTrailing) {
                            if tab == .messages, unread > 0 {
                                Text(unread > 9 ? "9+" : "\(unread)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 17, minHeight: 17)
                                    .background(Color.red, in: Capsule())
                                    .offset(x: 10, y: -6)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
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

/// Covers the web view from launch until the first page has something to show. With a picture
/// of the feed from last time, the app opens on its content at once and the live page fades in
/// over it; without one (first run, signed out) it shows the mark.
private struct LaunchCover: View {
    let image: UIImage?
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
            } else {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .opacity(pulse ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { pulse = true }
    }
}

/// Shown instead of the page when nothing could be loaded at all.
private struct FailureView: View {
    let site: String
    let failure: BrowserModel.Failure
    let retry: () -> Void

    private var title: String {
        switch failure {
        case .offline: return "No connection"
        case .http: return "\(site) isn't answering"
        case .other: return "Couldn't open \(site)"
        }
    }

    private var detail: String {
        switch failure {
        case .offline:
            return "Check Wi-Fi or mobile data, then try again."
        case .http(429):
            return "\(site) is limiting requests from this connection (error 429). Wait a minute, then try again."
        case .http(let status):
            return "\(site) answered with error \(status). Try again in a moment."
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
