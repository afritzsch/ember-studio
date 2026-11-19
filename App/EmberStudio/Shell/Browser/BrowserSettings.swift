import Foundation
import os

/// UI-061: what the browser keeps app-wide, `~/Library/Application Support/Ember Studio/Browser.json`
/// (atomic write). `version` lets later fields come in (UI-066's collections, T-127) without a
/// migration: a file without them reads as empty, and unknown keys are ignored.
///
///     {"version": 1, "places": [{"path": "/Users/me/Samples"}]}
struct BrowserSettings: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Place: Codable, Equatable, Sendable {
        var path: String
    }

    var version = BrowserSettings.currentVersion
    var places: [Place] = []

    init(places: [Place] = []) {
        self.places = places
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        places = try c.decodeIfPresent([Place].self, forKey: .places) ?? []
    }

    private static let log = Logger(subsystem: "dev.emberstudio", category: "browser")

    /// The settings at `url`; empty when there is no file. A file that doesn't decode is logged
    /// and read as empty (the next change writes a good one).
    static func read(_ url: URL) -> BrowserSettings {
        guard let data = try? Data(contentsOf: url) else { return BrowserSettings() }
        do {
            return try JSONDecoder().decode(BrowserSettings.self, from: data)
        } catch {
            log.error("couldn't read \(url.path, privacy: .public): \(error)")
            return BrowserSettings()
        }
    }

    /// Writes atomically (a temporary file renamed over the old one), making the folder if needed.
    func write(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// The user's file.
    static var userURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support.appending(path: "Ember Studio", directoryHint: .isDirectory).appending(path: "Browser.json")
    }

    /// The file the app uses. An app launched by a tool (`AppOptions.isAutomated`: dawmcp attach,
    /// `dawctl --launch`) works on a copy in a folder of its own under `$TMPDIR` (CONV §9, as the
    /// plugin cache does): parallel worktrees' apps never write one shared file, and an agent
    /// adding places doesn't change the user's.
    static func appURL(automated: Bool, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                       userFile: URL = BrowserSettings.userURL) -> URL {
        guard automated else { return userFile }
        let folder = FileManager.default.temporaryDirectory.appending(path: "EmberStudio-Browser-\(pid)", directoryHint: .isDirectory)
        let copy = folder.appending(path: "Browser.json")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: userFile, to: copy)
        }
        return copy
    }
}
