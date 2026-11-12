import UIKit
import UserNotifications

/// Local notifications for what the two sites show while the app runs: Instagram's count of
/// unread conversations and YouTube's count on its bell. Nothing is fetched for them: the pages
/// are read only as they are on screen, so they arrive while the app is open (or for the few
/// seconds iOS lets a page run after the app leaves the front). There is no push: WKWebView has
/// no Web Push, and a free Apple account, as SideStore signs with, has no push entitlement.
///
/// The notifications carry counts only: no names, no message text.
@MainActor
final class Notifier: NSObject, ObservableObject {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// Set by the app: switches site and opens a path when a notification is tapped.
    var onOpen: ((Platform, String) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let log = DiagnosticsLog.shared
    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        center.delegate = self
        refreshAuthorization()
    }

    func refreshAuthorization() {
        center.getNotificationSettings { settings in
            Task { @MainActor [weak self] in self?.authorization = settings.authorizationStatus }
        }
    }

    /// Asked when a notifications switch is turned on. iOS asks once; after that, Settings.
    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                self?.log.add("notify", granted ? "allowed" : "not allowed \(error?.localizedDescription ?? "")")
                self?.refreshAuthorization()
            }
        }
    }

    var canNotify: Bool { authorization == .authorized || authorization == .provisional }

    // MARK: - Events

    /// Instagram's count of unread conversations changed. `onScreen`: the inbox is in front,
    /// where a banner would only repeat what is already visible.
    func instagramUnread(_ count: Int, enabled: Bool, onScreen: Bool) {
        announce(platform: .instagram, count: count, enabled: enabled, onScreen: onScreen,
                 body: count == 1 ? "1 unread conversation" : "\(count) unread conversations",
                 path: "/direct/inbox/")
        setBadge(enabled ? count : 0)
    }

    /// The count on YouTube's bell changed: new videos, live streams, replies, all together.
    func youtubeActivity(_ count: Int, enabled: Bool, onScreen: Bool) {
        announce(platform: .youtube, count: count, enabled: enabled, onScreen: onScreen,
                 body: count == 1 ? "1 new notification" : "\(count) new notifications",
                 path: "/feed/notifications")
    }

    /// One notification per site at a time, replaced rather than piled up, and only when the
    /// count rose above what was last announced; the announced count is remembered between
    /// launches, so opening the app does not repeat an old one.
    private func announce(platform: Platform, count: Int, enabled: Bool, onScreen: Bool, body: String, path: String) {
        let key = "announced.\(platform.rawValue)"
        let announced = defaults.integer(forKey: key)
        if count == 0 {
            defaults.set(0, forKey: key)
            center.removeDeliveredNotifications(withIdentifiers: [platform.rawValue])
            return
        }
        guard enabled, canNotify, count > announced else { return }
        defaults.set(count, forKey: key)
        if onScreen { return }
        let content = UNMutableNotificationContent()
        content.title = platform.title
        content.body = body
        content.sound = .default
        content.threadIdentifier = platform.rawValue
        content.userInfo = ["platform": platform.rawValue, "path": path]
        let request = UNNotificationRequest(identifier: platform.rawValue, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.log.add("notify", "\(platform.rawValue): \(count)\(error.map { " failed: \($0.localizedDescription)" } ?? "")")
            }
        }
    }

    private func setBadge(_ count: Int) {
        guard canNotify else { return }
        center.setBadgeCount(count) { _ in }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Shown as a banner in the front too: that is where these are useful, on the other site.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info["platform"] as? String, let platform = Platform(rawValue: raw),
              let path = info["path"] as? String, path.hasPrefix("/") else { return }
        log.add("notify", "opened \(raw)")
        onOpen?(platform, path)
    }
}
