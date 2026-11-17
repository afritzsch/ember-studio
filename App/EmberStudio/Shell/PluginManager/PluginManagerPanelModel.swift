import Foundation
import Observation

/// UI-041 (T-065): a window's plugin manager panel, a strip under the toolbar like the audio
/// settings (in the layout, so `ui.snapshot` shows it). It shows the app's `PluginManagerModel`.
///
/// Control ids (UI-052): `plugins.manager` (toggle, always listed). While open: `plugins.close`,
/// `plugins.scan`, `plugins.rescan`, `plugins.blocked.retry` (all blocked) and
/// `plugins.blocked.<n>.retry` (the n-th blocked plugin, as `ui.state` lists them); scans are
/// disabled while one runs.
@Observable
@MainActor
final class PluginManagerPanelModel {
    @ObservationIgnored weak var window: ProjectWindowModel?

    var isOpen = false {
        didSet { if isOpen { manager.loadIfNeeded() } }
    }

    /// The manager this window shows: the app's, unless a test gives it another.
    var manager: PluginManagerModel = .shared

    init() {}

    var controls: [UIControl] {
        var controls: [UIControl] = [
            .toggle("plugins.manager", "Plugin Manager", isOn: isOpen) { [weak self] in self?.isOpen.toggle() },
        ]
        guard isOpen else { return controls }
        let manager = manager
        let idle = !manager.isScanning
        controls += [
            .button("plugins.close", "Close Plugin Manager") { [weak self] in self?.isOpen = false },
            .button("plugins.scan", "Scan for New Plugins", enabled: idle) { manager.scan() },
            .button("plugins.rescan", "Rescan All Plugins", enabled: idle) { manager.rescanAll() },
        ]
        let blocked = manager.blocked
        controls.append(.button("plugins.blocked.retry", "Retry All Blocked Plugins", enabled: idle && !blocked.isEmpty) {
            manager.retryBlocked()
        })
        for (n, plugin) in blocked.enumerated() {
            controls.append(.button("plugins.blocked.\(n).retry", "Retry \(plugin.name)", enabled: idle) {
                manager.retryBlocked([plugin.identifier])
            })
        }
        return controls
    }
}
