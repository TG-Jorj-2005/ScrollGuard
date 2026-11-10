import SwiftUI

@main
struct ScrollGuardApp: App {
    @StateObject private var store: SettingsStore
    @StateObject private var browser: BrowserModel

    init() {
        // One settings store and one browser for the whole life of the app.
        let store = SettingsStore()
        _store = StateObject(wrappedValue: store)
        _browser = StateObject(wrappedValue: BrowserModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(browser)
                .environmentObject(DiagnosticsLog.shared)
                .preferredColorScheme(.dark)
                .tint(Color.accentColor)
        }
    }
}
