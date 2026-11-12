import SwiftUI

@main
struct ScrollGuardApp: App {
    @StateObject private var store: SettingsStore
    @StateObject private var browser: BrowserModel
    @StateObject private var youtube: YouTubeModel
    @StateObject private var notifier: Notifier

    init() {
        // One settings store and one browser for the whole life of the app.
        let store = SettingsStore()
        _store = StateObject(wrappedValue: store)
        _browser = StateObject(wrappedValue: browser)
        let browser = BrowserModel(store: store)
        let youtube = YouTubeModel(store: store)
        let notifier = Notifier()
        browser.notifier = notifier
        youtube.notifier = notifier
        // A tapped notification: the site it came from, on the page it is about.
        notifier.onOpen = { platform, path in
            store.platform = platform
            if platform == .instagram { browser.open(path: path) } else { youtube.open(path: path) }
        }
        _youtube = StateObject(wrappedValue: youtube)
        _notifier = StateObject(wrappedValue: notifier)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(browser)
                .environmentObject(youtube)
                .environmentObject(notifier)
                .environmentObject(DiagnosticsLog.shared)
                .preferredColorScheme(.dark)
                .tint(Color.accentColor)
        }
    }
}
