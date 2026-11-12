import SwiftUI

@main
struct ScrollGuardApp: App {
    @StateObject private var store: SettingsStore
    @StateObject private var browser: BrowserModel
    @StateObject private var youtube: YouTubeModel

    init() {
        // One settings store and one browser for the whole life of the app.
        let store = SettingsStore()
        _store = StateObject(wrappedValue: store)
        _browser = StateObject(wrappedValue: BrowserModel(store: store))
        _youtube = StateObject(wrappedValue: YouTubeModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(browser)
                .environmentObject(youtube)
                .environmentObject(DiagnosticsLog.shared)
                .preferredColorScheme(.dark)
                .tint(Color.accentColor)
        }
    }
}
