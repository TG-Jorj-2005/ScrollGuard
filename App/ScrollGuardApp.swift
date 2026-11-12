import SwiftUI

/// The two web views and everything around them. Made once the first window is on screen, not
/// with the app: a WKWebView created before the window exists aborts in UIKit's touch delivery
/// (-[UIGestureRecognizer _delayTouchesForEvent:inPhase:]) at the first tap on its page, with
/// builds from the iOS 26 SDK on iOS 26 and 27. Nothing of the app is on the stack then, and
/// the log just stops: that is what tapping Instagram's activity link did.
@MainActor
final class AppModels {
    let browser: BrowserModel
    let youtube: YouTubeModel

    init(store: SettingsStore, notifier: Notifier) {
        browser = BrowserModel(store: store)
        youtube = YouTubeModel(store: store)
        browser.notifier = notifier
        youtube.notifier = notifier
        // A tapped notification: the site it came from, on the page it is about.
        let browser = browser, youtube = youtube
        notifier.onOpen = { platform, path in
            store.platform = platform
            if platform == .instagram { browser.open(path: path) } else { youtube.open(path: path) }
        }
    }
}

@main
struct ScrollGuardApp: App {
    @StateObject private var store = SettingsStore()
    /// Made with the app, so a tapped notification that starts it is received.
    @StateObject private var notifier = Notifier()
    @State private var models: AppModels?

    var body: some Scene {
        WindowGroup {
            Group {
                if let models {
                    RootView()
                        .environmentObject(store)
                        .environmentObject(models.browser)
                        .environmentObject(models.youtube)
                        .environmentObject(notifier)
                        .environmentObject(DiagnosticsLog.shared)
                } else {
                    // One frame at launch, the colour of the launch screen.
                    Color.black.ignoresSafeArea()
                }
            }
            .preferredColorScheme(.dark)
            .tint(Color.accentColor)
            .onAppear {
                if models == nil { models = AppModels(store: store, notifier: notifier) }
            }
        }
    }
}
