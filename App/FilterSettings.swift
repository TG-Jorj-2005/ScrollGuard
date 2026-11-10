import Foundation

/// The three switches of the control panel. All on by default.
struct FilterSettings: Equatable {
    /// Hide the Reels tab and suggested-reels shelves.
    var hideReels = true
    /// Stop every way into the endless Reels viewer (/reels/).
    var blockReelsFeed = true
    /// Open a single clip as a normal post page, which has nothing to scroll into.
    var clipsAsPosts = true

    var isProtecting: Bool { hideReels && blockReelsFeed }

    /// The same values as the object `instagram.js` reads as its configuration.
    var json: String {
        "{\"hideReels\":\(hideReels),\"blockReelsFeed\":\(blockReelsFeed),\"clipsAsPosts\":\(clipsAsPosts)}"
    }
}

/// Keeps the switches in UserDefaults, so they are the same after the app restarts.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: FilterSettings {
        didSet {
            guard settings != oldValue else { return }
            defaults.set(settings.hideReels, forKey: Keys.hideReels)
            defaults.set(settings.blockReelsFeed, forKey: Keys.blockReelsFeed)
            defaults.set(settings.clipsAsPosts, forKey: Keys.clipsAsPosts)
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let hideReels = "hideReels"
        static let blockReelsFeed = "blockReelsFeed"
        static let clipsAsPosts = "clipsAsPosts"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A switch that was never touched has no stored value and stays on.
        func stored(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        settings = FilterSettings(hideReels: stored(Keys.hideReels),
                                  blockReelsFeed: stored(Keys.blockReelsFeed),
                                  clipsAsPosts: stored(Keys.clipsAsPosts))
    }
}
