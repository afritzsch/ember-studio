import DAWModel
import Foundation

/// PLUG-021, DW-224, DW-226 (T-083): a window whose project is in safe mode says so. The banner
/// under the toolbar lists the plugins that aren't loaded and offers "Enable Plugins"
/// (`safeMode.enablePlugins`), which ends the session override: every plugin slot is then built
/// with its plugin again (the graph is re-applied), and each slot's own bypass applies. Safe mode
/// never changes the document, so there is nothing to undo.
extension ProjectWindowModel {
    /// The AU/VST3 slots safe mode keeps from loading, in layout order; empty when not in safe mode.
    var safeModePlugins: [CrashMarker.Plugin] {
        guard store.isSafeMode else { return [] }
        return CrashMarker.OpenProject(project: project, folder: nil).plugins
    }

    /// The banner's text.
    var safeModeMessage: String {
        let plugins = safeModePlugins
        guard !plugins.isEmpty else { return "Safe mode: plugins are disabled for this session (this project has none)." }
        let names = plugins.map(\.name).joined(separator: ", ")
        return "Safe mode: \(plugins.count == 1 ? "1 plugin is" : "\(plugins.count) plugins are") disabled for this session "
            + "(\(names)). Their settings are kept and saved as they were."
    }

    /// UI-052: `safeMode.enablePlugins`, while in safe mode.
    var safeModeControls: [UIControl] {
        guard store.isSafeMode else { return [] }
        return [.button("safeMode.enablePlugins", "Enable Plugins") { [weak self] in self?.enablePlugins() }]
    }

    /// Leaves safe mode: the plugins load now (a plugin that crashes on load can still take the app
    /// down; the autosave is the mitigation, PLUG-020).
    func enablePlugins() {
        guard store.isSafeMode else { return }
        let count = safeModePlugins.count
        store.isSafeMode = false
        toasts.post(.info, .info, title: "Plugins enabled",
                    message: count == 0 ? "\(project.name) left safe mode." : "\(project.name): \(count) plugin\(count == 1 ? "" : "s") loading.")
    }

    /// The name a device slot shows in toasts: its plugin's name, or its built-in kind, with the
    /// channel it sits on.
    func deviceSlotName(_ id: NodeIDValue) -> String? {
        var found: String?
        project.forEachDeviceSlot { slot, channel in
            guard slot.id == id, found == nil else { return }
            let device: String = switch slot.kind {
            case .au(let d): d.name
            case .vst3(let d): d.name
            case .builtin(let kind): "\(kind)".prefix(1).uppercased() + "\(kind)".dropFirst()
            }
            let owner = project.track(channel)?.name ?? project.buses.first { $0.id == channel }?.name
                ?? (channel == project.master.id ? "Master" : nil)
            found = owner.map { "\(device) on \($0)" } ?? device
        }
        return found
    }
}
