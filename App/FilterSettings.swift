import Foundation

/// The switches of the control panel. All on by default.
struct FilterSettings: Equatable {
    /// Hide the Reels tab and suggested-reels shelves.
    var hideReels = true
    /// Stop every way into the endless Reels viewer (/reels/).
    var blockReelsFeed = true
    /// Keep an opened clip alone: swiping from it to the next reel is held back.
    var singleClip = true
    /// Show a native bottom bar in place of Instagram's own.
    var nativeBar = true
    /// A short slide when a page opens on top of another.
    var pageTransitions = true
    /// YouTube: hide the Shorts tab, shelves and cards, and refuse the Shorts viewer.
    var hideShorts = true
    /// A notification when Instagram's count of unread conversations rises.
    var notifyInstagram = false
    /// A notification when the count on YouTube's bell rises.
    var notifyYouTube = false

    var isProtecting: Bool { hideReels && blockReelsFeed && singleClip }

    /// The object `instagram.js` reads as its configuration. `nativeBarActive` is true while
    /// the native bar is in use (switched on, and signed in), which is when the page hides
    /// its own bar.
    func filterConfig(nativeBarActive: Bool) -> String {
        "{\"hideReels\":\(hideReels),\"blockReelsFeed\":\(blockReelsFeed),\"singleClip\":\(singleClip),"
            + "\"nativeBar\":\(nativeBarActive)}"
    }

    /// For the diagnostics log.
    var summary: String {
        "hideReels=\(hideReels) blockReelsFeed=\(blockReelsFeed) singleClip=\(singleClip) "
            + "nativeBar=\(nativeBar) pageTransitions=\(pageTransitions) hideShorts=\(hideShorts) "
            + "notify=\(notifyInstagram)/\(notifyYouTube)"
    }
}

/// The two sites the app shows, each in a web view of its own.
enum Platform: String, CaseIterable, Identifiable {
    case instagram, youtube
    var id: String { rawValue }
    var title: String { self == .instagram ? "Instagram" : "YouTube" }
    var symbol: String { self == .instagram ? "camera" : "play.rectangle" }
}

/// Keeps the switches in UserDefaults, so they are the same after the app restarts.
@MainActor
final class SettingsStore: ObservableObject {
    /// Which site is on screen; the app reopens on the one shown last.
    @Published var platform: Platform {
        didSet { defaults.set(platform.rawValue, forKey: Keys.platform) }
    }

    @Published var settings: FilterSettings {
        didSet {
            guard settings != oldValue else { return }
            defaults.set(settings.hideReels, forKey: Keys.hideReels)
            defaults.set(settings.blockReelsFeed, forKey: Keys.blockReelsFeed)
            defaults.set(settings.singleClip, forKey: Keys.singleClip)
            defaults.set(settings.nativeBar, forKey: Keys.nativeBar)
            defaults.set(settings.pageTransitions, forKey: Keys.pageTransitions)
            defaults.set(settings.hideShorts, forKey: Keys.hideShorts)
            defaults.set(settings.notifyInstagram, forKey: Keys.notifyInstagram)
            defaults.set(settings.notifyYouTube, forKey: Keys.notifyYouTube)
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let hideReels = "hideReels"
        static let blockReelsFeed = "blockReelsFeed"
        static let singleClip = "singleClip"
        static let nativeBar = "nativeBar"
        static let pageTransitions = "pageTransitions"
        static let hideShorts = "hideShorts"
        static let notifyInstagram = "notifyInstagram"
        static let notifyYouTube = "notifyYouTube"
        static let platform = "platform"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A switch that was never touched has no stored value and stays on.
        func stored(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        settings = FilterSettings(hideReels: stored(Keys.hideReels),
                                  blockReelsFeed: stored(Keys.blockReelsFeed),
                                  singleClip: stored(Keys.singleClip),
                                  nativeBar: stored(Keys.nativeBar),
                                  pageTransitions: stored(Keys.pageTransitions),
                                  hideShorts: stored(Keys.hideShorts),
                                  // Off until asked for: turning one on asks iOS for permission.
                                  notifyInstagram: defaults.bool(forKey: Keys.notifyInstagram),
                                  notifyYouTube: defaults.bool(forKey: Keys.notifyYouTube))
        platform = Platform(rawValue: defaults.string(forKey: Keys.platform) ?? "") ?? .instagram
    }
}
