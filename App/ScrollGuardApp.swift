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
        let browserModel = BrowserModel(store: store)
        let youtubeModel = YouTubeModel(store: store)
        let notifierModel = Notifier()
        browserModel.notifier = notifierModel
        youtubeModel.notifier = notifierModel
        // A tapped notification: the site it came from, on the page it is about.
        notifierModel.onOpen = { platform, path in
            store.platform = platform
            if platform == .instagram { browserModel.open(path: path) } else { youtubeModel.open(path: path) }
        }
        _browser = StateObject(wrappedValue: browserModel)
        _youtube = StateObject(wrappedValue: youtubeModel)
        _notifier = StateObject(wrappedValue: notifierModel)
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
