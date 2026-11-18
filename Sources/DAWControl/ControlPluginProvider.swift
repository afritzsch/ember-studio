import Foundation

/// T-098 (DW-016): what `plugins.*` run against. Headless (`dawctl`, `dawmcp`) that is a
/// `CatalogPluginControl` over the scan cache with the `PluginScanner` helper next to the binary;
/// in the app (attach mode) it is the app's plugin manager, so the plugin manager panel shows what
/// a scan through the socket found.
///
/// The `Dispatcher` takes the one in its configuration (`Configuration.plugins`), else its UI
/// provider when that conforms too (the app's), else a `CatalogPluginControl` made on first use.
@MainActor
public protocol ControlPluginProvider: AnyObject {
    /// Every cached plugin, blocked ones included (PLUG-004). Reads the cache; never scans.
    func pluginsList() async throws -> [ControlPlugin]
    /// PLUG-004: scans new or changed candidates, drops vanished ones. `timeout`: each scan's limit
    /// (nil: the scanner's own, 30 s).
    func pluginsScan(timeout: TimeInterval?) async throws -> ControlPluginScanSummary
    /// PLUG-001/004 (DW-275): forgets the blocked plugins in `identifiers` (nil: all) and scans
    /// again, those with `timeout` (nil: the scanner's own limit).
    func pluginsRetry(identifiers: Set<String>?, timeout: TimeInterval?) async throws -> ControlPluginScanSummary
    /// PLUG-004: forgets the blocked plugins in `identifiers` (nil: all) without scanning.
    func pluginsUnblock(identifiers: Set<String>?) async throws
    /// The `plugins.json` the plugins come from.
    var pluginCachePath: String { get }
}
