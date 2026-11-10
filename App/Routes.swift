import Foundation

/// What an instagram.com address is, as far as Reels go. The same rules as `classify` in
/// Web/instagram.js: this copy handles full page loads, the script handles in-page navigation.
enum ReelsRoute: Equatable {
    /// The endless Reels viewer.
    case feed
    /// One clip, opened from a post, a profile or a conversation.
    case clip(id: String)
}

enum Routes {
    static let home = URL(string: "https://www.instagram.com/")!

    /// Sites that stay inside the app: Instagram itself, plus the Meta sites its sign-in,
    /// security checks and media go through. Any other site opens in a Safari sheet.
    private static let familyDomains = [
        "instagram.com", "cdninstagram.com", "facebook.com", "fb.com", "fbcdn.net", "fbsbx.com",
        "meta.com", "messenger.com"
    ]

    static func isInstagram(_ url: URL) -> Bool {
        host(url, isIn: ["instagram.com"])
    }

    static func isFamily(_ url: URL) -> Bool {
        host(url, isIn: familyDomains)
    }

    private static func host(_ url: URL, isIn domains: [String]) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func classify(_ url: URL) -> ReelsRoute? {
        guard isInstagram(url) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let head = parts.first?.lowercased() else { return nil }
        if head == "reels" {
            if parts.count == 2, isClipID(parts[1]) { return .clip(id: parts[1]) }
            return .feed
        }
        if head == "reel" {
            if parts.count >= 2, isClipID(parts[1]) { return .clip(id: parts[1]) }
            return .feed
        }
        // A clip under its author's name, /<name>/reel/<id>/: the form signed-in pages link to.
        if parts.count >= 3, parts[1].lowercased() == "reel", isClipID(parts[2]) {
            return .clip(id: parts[2])
        }
        return nil
    }

    private static func isClipID(_ text: String) -> Bool {
        guard text.count >= 5, text.lowercased() != "audio" else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
        }
    }
}

extension Routes {
    private static let knownHeads: Set<String> = [
        "reels", "reel", "p", "explore", "direct", "stories", "accounts", "tv", "challenge",
        "notifications", "your_activity", "legal", "about", "web"
    ]
    private static let knownWords: Set<String> = [
        "p", "reel", "inbox", "t", "new", "requests", "tagged", "reels", "saved", "audio", "login", "onetap",
        "edit", "tags", "locations", "search", "people", "highlights", "comments", "liked_by",
        "followers", "following", "activity", "signup", "password", "reset"
    ]

    /// A path reduced to its shape, for the diagnostics log: "/direct/t/*/", "/<name>/",
    /// "/p/*/". Account names, conversation numbers and post ids are never written down.
    /// The same rule as `shape` in Web/instagram.js.
    static func shape(path: String) -> String {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        guard !parts.isEmpty else { return "/" }
        let shaped = parts.enumerated().map { index, part -> String in
            if index == 0 { return knownHeads.contains(part) ? part : "<name>" }
            return knownWords.contains(part) ? part : "*"
        }
        return "/" + shaped.joined(separator: "/") + "/"
    }
}

extension URL {
    /// What the diagnostics log says about an address: the site and, on Instagram, the shape of
    /// the path. No query (tokens, search terms), no names or ids. Other sites: the site only.
    var redacted: String {
        let site = host ?? scheme ?? "?"
        return Routes.isFamily(self) ? site + Routes.shape(path: path) : site
    }
}
