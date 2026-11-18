import Foundation
import PluginCatalog

// This file is DAWControl's only door to the `PluginCatalog` module, and it doesn't import
// DAWModel: both modules name a `PluginDescriptor` (and `PluginCatalog` is also the catalog's type,
// so the module name can't qualify it). Everything leaves this file as `ControlPlugin`.

/// T-098 (DW-016): `plugins.*` headless. Runs PLUG-001..004's catalog (discovery, the out-of-process
/// `PluginScanner`, the `plugins.json` cache) the way the app's plugin manager does. Plugin code
/// is never loaded in this process.
///
/// The cache is re-read before every call, so `dawctl plugins.scan` and a later
/// `dawctl plugins.list` (two processes) see the same list. Scans run off the main actor.
public final class CatalogPluginControl: ControlPluginProvider {
    /// Where the catalog reads, writes and scans.
    public struct Settings: Sendable {
        /// The `plugins.json` scan cache.
        public var cacheURL: URL
        /// The `PluginScanner` executable; nil: scans fail with "scanner unavailable".
        public var scannerURL: URL?
        public var vst3Directories: [URL]
        public var includeAudioUnits: Bool

        public init(cacheURL: URL, scannerURL: URL?,
                    vst3Directories: [URL] = SystemPluginDiscovery.defaultVST3Directories, includeAudioUnits: Bool = true) {
            self.cacheURL = cacheURL
            self.scannerURL = scannerURL
            self.vst3Directories = vst3Directories
            self.includeAudioUnits = includeAudioUnits
        }

        /// `dawctl`'s and `dawmcp`'s settings (13 "Contract delta (T-098)"):
        /// - cache: `$DAWCTL_PLUGIN_CACHE`, else `<checkout>/.build/plugins/plugins.json` of the
        ///   checkout the executable was built in (else `$TMPDIR/EmberStudio-Plugins-<pid>/`),
        ///   started as a copy of the user's cache (PLUG-004's file), so it lists what the user's
        ///   scans found while its own scans never write the user's file or another worktree's
        ///   (CONV §9);
        /// - scanner: `$DAWCTL_PLUGIN_SCANNER`, else `PluginScanner` next to the executable;
        /// - VST3 folders: `$DAWCTL_VST3_DIRS` (colon-separated), else PLUG-003's;
        /// - audio units unless `$DAWCTL_AU` is `0`.
        public static func headless(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            executable: URL? = Bundle.main.executableURL,
            userCache: URL = PluginCache.defaultURL
        ) -> Settings {
            let cache: URL
            if let path = environment["DAWCTL_PLUGIN_CACHE"], !path.isEmpty {
                cache = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            } else {
                let folder = checkoutRoot(of: executable)?.appending(path: ".build/plugins", directoryHint: .isDirectory)
                    ?? FileManager.default.temporaryDirectory.appending(
                        path: "EmberStudio-Plugins-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
                cache = folder.appending(path: "plugins.json")
                if !FileManager.default.fileExists(atPath: cache.path) {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: userCache, to: cache)
                }
            }
            let scanner = environment["DAWCTL_PLUGIN_SCANNER"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? executable.flatMap { exe in
                    let sibling = exe.resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "PluginScanner")
                    return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
                }
            let vst3 = environment["DAWCTL_VST3_DIRS"].map {
                $0.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
            } ?? SystemPluginDiscovery.defaultVST3Directories
            return Settings(cacheURL: cache, scannerURL: scanner, vst3Directories: vst3,
                            includeAudioUnits: environment["DAWCTL_AU"] != "0")
        }

        private static func checkoutRoot(of executable: URL?) -> URL? {
            guard var dir = executable?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
            while dir.path != "/" {
                if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) { return dir }
                dir = dir.deletingLastPathComponent()
            }
            return nil
        }
    }

    /// PLUG-001: the scanner's limit for a first scan (30 s).
    public nonisolated static let defaultTimeout: TimeInterval = ScannerLauncher.defaultTimeout
    /// DW-275: the limit of a retry of a plugin that timed out (120 s).
    public nonisolated static let retryTimeout: TimeInterval = ScannerLauncher.retryTimeout

    public let cacheURL: URL
    private let discovery: any PluginDiscovering
    private let scanner: any PluginScanning

    public convenience init(settings: Settings) {
        let scanner: any PluginScanning = if let url = settings.scannerURL {
            ScannerLauncher(executableURL: url)
        } else {
            MissingScanner()
        }
        self.init(cacheURL: settings.cacheURL,
                  discovery: SystemPluginDiscovery(vst3Directories: settings.vst3Directories,
                                                   includeAudioUnits: settings.includeAudioUnits),
                  scanner: scanner)
    }

    /// With stand-ins (tests): any discovery and scanner.
    public init(cacheURL: URL, discovery: any PluginDiscovering, scanner: any PluginScanning) {
        self.cacheURL = cacheURL
        self.discovery = discovery
        self.scanner = scanner
    }

    public var pluginCachePath: String { cacheURL.path }

    public func pluginsList() async throws -> [ControlPlugin] {
        catalog(scanner).descriptors.map(Self.plugin)
    }

    public func pluginsScan(timeout: TimeInterval?) async throws -> ControlPluginScanSummary {
        let scanner: any PluginScanning = timeout.map { LimitedScanner(base: scanner, timeout: $0) } ?? scanner
        var summary = try await run(catalog(scanner)) { catalog throws(PluginCatalogError) in try catalog.refresh() }
        summary.timeoutSeconds = timeout ?? Self.defaultTimeout
        return summary
    }

    public func pluginsRetry(identifiers: Set<String>?, timeout: TimeInterval?) async throws -> ControlPluginScanSummary {
        var summary = try await run(catalog(scanner)) { catalog throws(PluginCatalogError) in
            try catalog.retryBlocked(identifiers: identifiers, timeout: timeout)
        }
        summary.timeoutSeconds = timeout ?? Self.defaultTimeout
        return summary
    }

    public func pluginsUnblock(identifiers: Set<String>?) async throws {
        var catalog = catalog(scanner)
        do {
            try catalog.resetBlocked(identifiers: identifiers)
        } catch {
            throw Self.controlError(error)
        }
    }

    // MARK: Internals

    private func catalog(_ scanner: any PluginScanning) -> PluginCatalog {
        PluginCatalog(cacheURL: cacheURL, discovery: discovery, scanner: scanner)
    }

    /// Runs a refresh off the main actor: every candidate runs the helper process (PLUG-001).
    private func run(
        _ start: PluginCatalog,
        _ work: @escaping @Sendable (inout PluginCatalog) throws(PluginCatalogError) -> PluginCatalog.RefreshSummary
    ) async throws -> ControlPluginScanSummary {
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ControlPluginScanSummary, PluginCatalogError> in
            var catalog = start
            do throws(PluginCatalogError) {
                let summary = try work(&catalog)
                return .success(ControlPluginScanSummary(
                    scanned: summary.scanned.map(\.path), unchanged: summary.unchanged, removed: summary.removed,
                    plugins: catalog.plugins.count, blocked: catalog.blocked.count))
            } catch {
                return .failure(error)
            }
        }.value
        switch outcome {
        case .success(let summary): return summary
        case .failure(let error): throw Self.controlError(error)
        }
    }

    static func plugin(_ d: PluginDescriptor) -> ControlPlugin {
        ControlPlugin(format: d.format == .au ? "au" : "vst3", identifier: d.identifier, name: d.name, vendor: d.vendor, version: d.version,
                      isInstrument: d.isInstrument, hasSidechain: d.hasSidechain, numParams: d.numParams,
                      reason: d.status == .blocked ? (d.reason ?? "blocked") : nil, timedOut: d.isTimedOut)
    }

    static func controlError(_ error: PluginCatalogError) -> ControlError {
        switch error {
        case .scannerUnavailable(let detail): .internalError("plugin scanner unavailable: \(detail)")
        case .cacheWriteFailed(let detail): .internalError("couldn't save the plugin cache: \(detail)")
        }
    }
}

/// A scan limit of the caller's (`plugins.scan {timeoutSeconds}`): `refresh()` scans with the
/// scanner's own limit, so the scanner is wrapped.
private struct LimitedScanner: PluginScanning {
    let base: any PluginScanning
    let timeout: TimeInterval

    func scan(_ candidate: PluginCandidate) throws(PluginCatalogError) -> [PluginDescriptor] {
        try base.scan(candidate, timeout: timeout)
    }

    func scan(_ candidate: PluginCandidate, timeout: TimeInterval) throws(PluginCatalogError) -> [PluginDescriptor] {
        try base.scan(candidate, timeout: timeout)
    }
}

/// No `PluginScanner` next to the executable: a scan fails before anything is cached.
private struct MissingScanner: PluginScanning {
    func scan(_ candidate: PluginCandidate) throws(PluginCatalogError) -> [PluginDescriptor] {
        throw .scannerUnavailable("no PluginScanner next to this executable (swift build --product PluginScanner)")
    }
}
