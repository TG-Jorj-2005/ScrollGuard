import Foundation
import UIKit

/// What the app did, line by line: every navigation decision, error and block. There is no Mac
/// to attach a debugger from, so this log (Control panel → Diagnostics → Copy report) is how a
/// problem on the iPhone gets explained.
///
/// It stays on the device. It holds addresses without their query (no tokens, no search terms)
/// and never cookie values or anything typed into a page.
@MainActor
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()

    struct Entry: Identifiable {
        let id: Int
        let time: Date
        let tag: String
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    /// The last lines of the previous run, read at launch: what happened before a crash.
    let previousSession: [String]

    private var nextID = 0
    private var file: FileHandle?
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("scrollguard-log.txt")
        if let old = try? String(contentsOf: url, encoding: .utf8) {
            previousSession = old.split(separator: "\n").suffix(80).map(String.init)
        } else {
            previousSession = []
        }
        // Start this run's file empty; each line is written at once, so it survives a crash.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }

    func add(_ tag: String, _ text: String) {
        let entry = Entry(id: nextID, time: Date(), tag: tag, text: String(text.prefix(300)))
        nextID += 1
        entries.append(entry)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        if let data = (line(entry) + "\n").data(using: .utf8) {
            try? file?.write(contentsOf: data)
        }
    }

    func line(_ entry: Entry) -> String {
        "\(formatter.string(from: entry.time)) [\(entry.tag)] \(entry.text)"
    }
}

enum DeviceInfo {
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// The hardware identifier, e.g. "iPhone15,4" for iPhone 15.
    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    @MainActor static var system: String {
        "iOS \(UIDevice.current.systemVersion)"
    }
}
