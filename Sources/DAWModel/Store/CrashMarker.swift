import Darwin
import Foundation
import os

/// PLUG-021 (T-064, docs/autobuild/DECISIONS.md "T-064 crash marker"): the `running` marker a
/// session leaves in Application Support while it runs, saying which projects are open and which
/// plugins they host. A clean quit removes it, so a marker whose process is gone was left by a
/// session that crashed (D-07: plugins run in-process, no sandbox; PLUG-020). The next launch
/// reads it to offer opening the project in safe mode (`ProjectStore.open(_:recover:safeMode:)`;
/// the dialog is T-083).
///
/// One file per process, `running-<pid>.json`, so concurrent instances (a user session and an
/// automated one) never overwrite or misreport each other's marker (CONV §9). A marker counts as
/// crashed when no process with its pid is alive (a reused pid hides a crash; rare and harmless).
public struct CrashMarker: Hashable, Sendable, Codable {
    /// A plugin slot of an open project.
    public struct Plugin: Hashable, Sendable, Codable {
        public var slotID: NodeIDValue
        /// "au" or "vst3".
        public var format: String
        public var identifier: String
        public var name: String

        public init(slotID: NodeIDValue, format: String, identifier: String, name: String) {
            self.slotID = slotID
            self.format = format
            self.identifier = identifier
            self.name = name
        }
    }

    /// An open project: its name, its folder (nil until saved) and its plugins in layout order.
    public struct OpenProject: Hashable, Sendable, Codable {
        public var name: String
        public var path: String?
        public var plugins: [Plugin]

        public init(name: String, path: String?, plugins: [Plugin]) {
            self.name = name
            self.path = path
            self.plugins = plugins
        }

        public init(project: Project, folder: URL?) {
            var plugins: [Plugin] = []
            for slot in project.allDeviceSlots {
                switch slot.kind {
                case .au(let d): plugins.append(Plugin(slotID: slot.id, format: "au", identifier: d.identifier, name: d.name))
                case .vst3(let d): plugins.append(Plugin(slotID: slot.id, format: "vst3", identifier: d.identifier, name: d.name))
                case .builtin: continue
                }
            }
            self.init(name: project.name, path: folder?.path, plugins: plugins)
        }
    }

    public var processID: Int32
    public var launched: Date
    public var projects: [OpenProject]

    public init(processID: Int32, launched: Date, projects: [OpenProject]) {
        self.processID = processID
        self.launched = launched
        self.projects = projects
    }

    /// `~/Library/Application Support/Ember Studio` (where PLUG-004 keeps `plugins.json` too).
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ember Studio", isDirectory: true)
    }

    static let filePrefix = "running-"

    public static func fileURL(processID: Int32, in directory: URL) -> URL {
        directory.appendingPathComponent("\(filePrefix)\(processID).json")
    }

    /// The markers in `directory` whose process isn't running: sessions that crashed (or were
    /// killed). Oldest launch first. Unreadable files are skipped.
    public static func leftByCrashedSessions(in directory: URL = defaultDirectory) -> [CrashMarker] {
        markerFiles(in: directory).compactMap { url -> CrashMarker? in
            guard let marker = read(url), !isProcessAlive(marker.processID) else { return nil }
            return marker
        }.sorted { $0.launched < $1.launched }
    }

    /// Removes the marker `marker` was read from (once it has been dealt with).
    public static func discard(_ marker: CrashMarker, in directory: URL = defaultDirectory) {
        try? FileManager.default.removeItem(at: fileURL(processID: marker.processID, in: directory))
    }

    public static func read(_ url: URL) -> CrashMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CrashMarker.self, from: data)
    }

    static func markerFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".json") }.sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// `kill(pid, 0)`: 0, or EPERM (someone else's process), means it exists.
    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }
}

/// PLUG-021: this process's `running` marker. `start` (once, at launch) collects the markers of
/// crashed sessions and writes this one's; the marker is rewritten whenever what `projects` returns
/// changes (checked every `refreshInterval` and on `refresh()`); `end()` (a clean quit) removes it.
/// A process that dies without `end()` leaves it behind for the next launch.
@MainActor
public final class CrashMarkerSession {
    public static let refreshInterval: Duration = .seconds(2)

    public let directory: URL
    public let processID: Int32
    /// The markers crashed sessions left, read (and removed from disk) by `start`, oldest first.
    /// For the crash dialog (T-083), which offers safe mode for their projects.
    public let crashedSessions: [CrashMarker]

    private let launched: Date
    private let projects: @MainActor () -> [CrashMarker.OpenProject]
    private var written: CrashMarker?
    private var timer: Task<Void, Never>?
    private var ended = false

    private static let log = Logger(subsystem: "dev.emberstudio", category: "model")

    /// The app's launch hook. `projects` says what is open right now.
    public static func start(
        directory: URL = CrashMarker.defaultDirectory,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        projects: @escaping @MainActor () -> [CrashMarker.OpenProject]
    ) -> CrashMarkerSession {
        let crashed = CrashMarker.leftByCrashedSessions(in: directory).filter { $0.processID != processID }
        for marker in crashed { CrashMarker.discard(marker, in: directory) }
        let session = CrashMarkerSession(directory: directory, processID: processID, crashed: crashed, projects: projects)
        session.refresh()
        session.timer = Task { [weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(for: CrashMarkerSession.refreshInterval)
                guard let session, !Task.isCancelled else { return }
                session.refresh()
            }
        }
        return session
    }

    private init(directory: URL, processID: Int32, crashed: [CrashMarker],
                 projects: @escaping @MainActor () -> [CrashMarker.OpenProject]) {
        self.directory = directory
        self.processID = processID
        crashedSessions = crashed
        launched = Date()
        self.projects = projects
    }

    public var fileURL: URL { CrashMarker.fileURL(processID: processID, in: directory) }

    /// Writes the marker if what is open changed since the last write.
    public func refresh() {
        guard !ended else { return }
        let marker = CrashMarker(processID: processID, launched: launched, projects: projects())
        guard marker != written, let data = marker.encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            written = marker
        } catch {
            Self.log.error("running marker not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The clean-quit hook: stops refreshing and removes the marker.
    public func end() {
        guard !ended else { return }
        ended = true
        timer?.cancel()
        timer = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
