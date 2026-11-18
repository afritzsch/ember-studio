import DAWControl
import Foundation

/// T-098 (DW-016): `plugins.*` in attach mode run through the app's plugin manager (UI-041), so
/// the plugin manager panel shows what a scan through the socket found, and the other way round.
/// The `Dispatcher` uses this because the app's UI provider conforms (13 "Contract delta (T-098)").
///
/// Differences from headless: `plugins.scan` uses the app's scanner limit (30 s; a
/// `timeoutSeconds` is reported back in `note`, not applied), the summary has counts only, and
/// `plugins.unblock` is `notSupported` (the manager always rescans what it forgets: use
/// `plugins.retry`).
extension AppControlProvider: ControlPluginProvider {
    /// The main window's manager (the app's one, unless a test gave the window another).
    private var pluginManager: PluginManagerModel {
        app?.mainWindow?.pluginPanel.manager ?? .shared
    }

    var pluginCachePath: String { pluginManager.cacheURL.path }

    func pluginsList() async throws -> [ControlPlugin] {
        let manager = pluginManager
        manager.loadIfNeeded()
        return manager.plugins.map { p in
            ControlPlugin(format: p.format.rawValue, identifier: p.identifier, name: p.name, vendor: p.vendor,
                          version: p.version, isInstrument: p.isInstrument, hasSidechain: p.hasSidechain,
                          numParams: p.numParams, reason: p.blockedReason, timedOut: p.isTimedOut)
        }
    }

    func pluginsScan(timeout: TimeInterval?) async throws -> ControlPluginScanSummary {
        var summary = try await runScan { $0.scan() }
        summary.timeoutSeconds = CatalogPluginControl.defaultTimeout
        if let timeout {
            summary.note = "timeoutSeconds \(timeout) not applied: the app scans with its own \(Int(CatalogPluginControl.defaultTimeout)) s limit"
        }
        return summary
    }

    func pluginsRetry(identifiers: Set<String>?, timeout: TimeInterval?) async throws -> ControlPluginScanSummary {
        var summary = try await runScan { $0.retryBlocked(identifiers, timeout: timeout) }
        summary.timeoutSeconds = timeout ?? CatalogPluginControl.defaultTimeout
        return summary
    }

    func pluginsUnblock(identifiers: Set<String>?) async throws {
        throw ControlError.notSupported("the app's plugin manager rescans what it unblocks: use plugins.retry")
    }

    /// Starts a scan on the manager (after one already running, which the panel may have
    /// started) and waits for it.
    private func runScan(_ start: (PluginManagerModel) -> Void) async throws -> ControlPluginScanSummary {
        let manager = pluginManager
        await manager.scanTask?.value
        manager.loadIfNeeded()
        start(manager)
        await manager.scanTask?.value
        if let error = manager.error { throw ControlError.internalError(error) }
        let last = manager.lastScan
        return ControlPluginScanSummary(
            scanned: last?.scanned ?? 0, unchanged: last?.unchanged ?? 0, removed: last?.removed ?? 0,
            plugins: manager.usable.count, blocked: manager.blocked.count)
    }
}
