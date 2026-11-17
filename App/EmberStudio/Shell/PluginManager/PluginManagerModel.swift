import Foundation
import Observation
import PluginCatalog

// This file is the shell's only door to the `PluginCatalog` product (DW-015). It imports neither
// DAWModel nor DAWControl: both modules name a `PluginDescriptor`, and `PluginCatalog` is also the
// name of the catalog's main type, so the app works with `ScannedPlugin` instead.

/// UI-041 (T-065): one plugin the scanner reported, in the shell's own terms.
struct ScannedPlugin: Equatable, Sendable, Identifiable {
    enum Format: String, Sendable { case au, vst3 }

    var format: Format
    /// AU: `type:subtype:manufacturer`; VST3: `path#classUID` (PLUG-002). For a blocked VST3 bundle
    /// the scanner couldn't report on, the bundle path.
    var identifier: String
    var name: String
    var vendor: String
    var version: String
    var isInstrument: Bool
    var hasSidechain: Bool
    var numParams: UInt32
    /// PLUG-001: why the scan blocked it; nil for a usable plugin.
    var blockedReason: String?

    var id: String { "\(format.rawValue):\(identifier)" }
    var isBlocked: Bool { blockedReason != nil }

    init(format: Format, identifier: String, name: String, vendor: String = "", version: String = "",
         isInstrument: Bool = false, hasSidechain: Bool = false, numParams: UInt32 = 0, blockedReason: String? = nil) {
        self.format = format
        self.identifier = identifier
        self.name = name
        self.vendor = vendor
        self.version = version
        self.isInstrument = isInstrument
        self.hasSidechain = hasSidechain
        self.numParams = numParams
        self.blockedReason = blockedReason
    }

    fileprivate init(_ d: PluginDescriptor) {
        self.init(format: d.format == .au ? .au : .vst3, identifier: d.identifier, name: d.name, vendor: d.vendor,
                  version: d.version, isInstrument: d.isInstrument, hasSidechain: d.hasSidechain, numParams: d.numParams,
                  blockedReason: d.status == .blocked ? (d.reason ?? "blocked") : nil)
    }
}

/// UI-041 (T-065, DW-015): the plugin manager. It keeps the app's view of installed plugins, read
/// from the scan cache (PLUG-004) and refreshed by scans that run the `PluginScanner` helper out of
/// process (PLUG-001; the app embeds it as an auxiliary executable). One per app (`AppModel`); each
/// window shows it in its own panel.
///   - **Scan**: scans new or changed plugins only, drops vanished ones (`PluginCatalog.refresh`).
///   - **Rescan All**: forgets the cache and scans every plugin again.
///   - **Blocked list**: plugins whose scan crashed, hung or failed, with the reason. "Retry"
///     forgets one (or all) and scans again.
/// Scans run off the main actor, one at a time; the panel shows progress as `isScanning`.
@Observable
@MainActor
final class PluginManagerModel {
    /// What the last scan did.
    struct ScanSummary: Equatable, Sendable {
        var scanned: Int
        var unchanged: Int
        var removed: Int
    }

    /// The app's one manager. Windows show it (`PluginManagerPanelModel`); tests give a window
    /// one of their own.
    static let shared = PluginManagerModel(cacheURL: sharedCacheURL(automated: AppOptions(arguments: CommandLine.arguments).isAutomated))

    /// PLUG-004's `plugins.json` for a person at the app. An app launched by a tool (`dawmcp`,
    /// `dawctl --launch`, tests: `AppOptions.isAutomated`) works on a copy of it in a folder of its
    /// own under `$TMPDIR` (CONV §9: parallel worktrees' apps never write one shared file), so it
    /// starts with the user's scan results and its scans stay its own.
    nonisolated static func sharedCacheURL(automated: Bool, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                           userCache: URL = PluginCache.defaultURL) -> URL {
        guard automated else { return userCache }
        let folder = FileManager.default.temporaryDirectory.appending(path: "EmberStudio-Plugins-\(pid)", directoryHint: .isDirectory)
        let copy = folder.appending(path: "plugins.json")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: userCache, to: copy)
        }
        return copy
    }

    /// Every cached plugin, blocked ones included, by name.
    private(set) var plugins: [ScannedPlugin] = []
    private(set) var isScanning = false
    private(set) var lastScan: ScanSummary?
    private(set) var error: String?
    /// Whether the cache was read yet (it is, lazily, the first time anything asks for plugins).
    private(set) var isLoaded = false

    let cacheURL: URL
    /// The scanner executable, nil when it can't be found (the app bundle lacks it).
    let scannerURL: URL?
    @ObservationIgnored private let discovery: any PluginDiscovering
    @ObservationIgnored private let scanner: any PluginScanning
    @ObservationIgnored private var catalog: PluginCatalog?
    /// The scan in flight (tests await it).
    @ObservationIgnored private(set) var scanTask: Task<Void, Never>?

    /// - Parameters:
    ///   - cacheURL: `plugins.json` (PLUG-004's default for the app).
    ///   - scannerURL: the helper; by default the app bundle's auxiliary executable, or the one next
    ///     to the running binary (SwiftPM builds).
    ///   - discovery, scanner: stand-ins for tests; by default the system's plugin folders and the
    ///     helper at `scannerURL`.
    init(cacheURL: URL = PluginCache.defaultURL, scannerURL: URL? = PluginManagerModel.defaultScannerURL(),
         discovery: (any PluginDiscovering)? = nil, scanner: (any PluginScanning)? = nil) {
        self.cacheURL = cacheURL
        self.scannerURL = scannerURL
        self.discovery = discovery ?? SystemPluginDiscovery()
        if let scanner {
            self.scanner = scanner
        } else if let scannerURL {
            self.scanner = ScannerLauncher(executableURL: scannerURL)
        } else {
            self.scanner = MissingScanner()
        }
    }

    /// The bundled helper (`Contents/MacOS/PluginScanner`), else the one beside this executable.
    nonisolated static func defaultScannerURL() -> URL? {
        ScannerLauncher.bundledExecutableURL()
    }

    // MARK: Lists

    /// Plugins the DAW may instantiate, by name (the device picker's list).
    var usable: [ScannedPlugin] {
        loadIfNeeded()
        return plugins.filter { !$0.isBlocked }
    }

    /// PLUG-001: the blocked list.
    var blocked: [ScannedPlugin] {
        loadIfNeeded()
        return plugins.filter(\.isBlocked)
    }

    /// Reads the cache once. Cheap (one JSON file); never scans.
    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        let catalog = PluginCatalog(cacheURL: cacheURL, discovery: discovery, scanner: scanner)
        self.catalog = catalog
        publish(catalog)
    }

    // MARK: Scans

    /// PLUG-004: scans new and changed plugins (and drops vanished ones).
    func scan() {
        run { catalog in
            try catalog.refresh()
        }
    }

    /// Forgets every cached result and scans all plugins again.
    func rescanAll() {
        let url = cacheURL
        let discovery = discovery
        let scanner = scanner
        run { catalog in
            try? FileManager.default.removeItem(at: url)
            catalog = PluginCatalog(cacheURL: url, discovery: discovery, scanner: scanner)
            return try catalog.refresh()
        }
    }

    /// PLUG-004: forgets blocked plugins (those in `identifiers`, or all of them) and scans again,
    /// so they get another chance.
    func retryBlocked(_ identifiers: Set<String>? = nil) {
        run { catalog in
            try catalog.resetBlocked(identifiers: identifiers)
            return try catalog.refresh()
        }
    }

    private func run(_ work: @escaping @Sendable (inout PluginCatalog) throws -> PluginCatalog.RefreshSummary) {
        guard !isScanning else { return }
        loadIfNeeded()
        guard let start = catalog else { return }
        isScanning = true
        error = nil
        scanTask = Task { [weak self] in
            // Off the main actor: every candidate runs the helper process, up to 10 s each.
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(PluginCatalog, PluginCatalog.RefreshSummary), PluginCatalogError> in
                var working = start
                do {
                    let summary = try work(&working)
                    return .success((working, summary))
                } catch let error as PluginCatalogError {
                    return .failure(error)
                } catch {
                    return .failure(.scannerUnavailable(String(describing: error)))
                }
            }.value
            self?.finish(outcome)
        }
    }

    private func finish(_ outcome: Result<(PluginCatalog, PluginCatalog.RefreshSummary), PluginCatalogError>) {
        isScanning = false
        switch outcome {
        case .success(let (catalog, summary)):
            self.catalog = catalog
            publish(catalog)
            lastScan = ScanSummary(scanned: summary.scanned.count, unchanged: summary.unchanged, removed: summary.removed)
        case .failure(let failure):
            error = Self.message(failure)
            // The cache may have been reset before the failure: show what it holds now.
            let reread = PluginCatalog(cacheURL: cacheURL, discovery: discovery, scanner: scanner)
            catalog = reread
            publish(reread)
        }
    }

    private func publish(_ catalog: PluginCatalog) {
        let list = catalog.descriptors.map(ScannedPlugin.init).sorted {
            ($0.name.localizedLowercase, $0.format.rawValue, $0.identifier) < ($1.name.localizedLowercase, $1.format.rawValue, $1.identifier)
        }
        if list != plugins { plugins = list }
    }

    static func message(_ error: PluginCatalogError) -> String {
        switch error {
        case .scannerUnavailable(let detail): "Plugin scanner unavailable: \(detail)"
        case .cacheWriteFailed(let detail): "Couldn't save the plugin list: \(detail)"
        }
    }
}

/// No helper to run: every scan fails before anything is cached (the app bundle lacks it).
private struct MissingScanner: PluginScanning {
    func scan(_ candidate: PluginCandidate) throws(PluginCatalogError) -> [PluginDescriptor] {
        throw .scannerUnavailable("PluginScanner isn't in the app bundle")
    }
}
