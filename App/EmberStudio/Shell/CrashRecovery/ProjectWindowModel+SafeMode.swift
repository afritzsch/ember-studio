import DAWModel
import Foundation

/// PLUG-021, DW-224, DW-226 (T-083): a window whose project is in safe mode says so. The banner
/// under the toolbar lists the plugins that aren't loaded and offers "Enable Plugins"
/// (`safeMode.enablePlugins`), which ends the session override: every plugin slot is then built
/// with its plugin again (the graph is re-applied), and each slot's own bypass applies. Safe mode
/// never changes the document, so there is nothing to undo.
extension ProjectWindowModel {
    /// The AU/VST3 slots safe mode keeps from loading, in layout order; empty when not in safe mode.
    /// DW-266 (T-095): slots enabled one by one aren't kept from loading, so they aren't listed.
    var safeModePlugins: [CrashMarker.Plugin] {
        guard store.isSafeMode else { return [] }
        let enabled = store.safeModeEnabledSlots
        return CrashMarker.OpenProject(project: project, folder: nil).plugins.filter { !enabled.contains($0.slotID) }
    }

    /// DW-266 (T-095): the plugins enabled one by one in safe mode, in layout order.
    var safeModeEnabledPlugins: [CrashMarker.Plugin] {
        guard store.isSafeMode else { return [] }
        let enabled = store.safeModeEnabledSlots
        return CrashMarker.OpenProject(project: project, folder: nil).plugins.filter { enabled.contains($0.slotID) }
    }

    /// PLUG-021, DW-226, DW-266: whether safe mode keeps `slot` from loading (an AU/VST3 slot, safe
    /// mode on, not enabled one by one).
    func isDisabledBySafeMode(_ slot: DeviceSlot) -> Bool {
        slot.isPlugin && store.isSafeMode && !store.safeModeEnabledSlots.contains(slot.id)
    }

    /// DW-266 (T-095, DECISIONS "T-095 app decisions"): "Enable this plugin": in safe mode, loads one
    /// plugin slot (to find a suspect plugin one at a time). Session-only like safe mode: nothing is
    /// written to the project, no undo entry, not dirty. The banner's "Enable Plugins" still ends
    /// safe mode for all of them.
    func enablePluginInSafeMode(_ slot: NodeIDValue) {
        guard store.isSafeMode, project.allDeviceSlots.contains(where: { $0.id == slot && $0.isPlugin }),
              !store.safeModeEnabledSlots.contains(slot)
        else { return }
        store.safeModeEnabledSlots.insert(slot)
        let name = deviceSlotName(slot) ?? "Plugin"
        toasts.post(.info, .info, title: "Plugin enabled", message: "\(name) is loading; the other plugins stay disabled.")
    }

    /// The banner's text.
    var safeModeMessage: String {
        let plugins = safeModePlugins
        // DW-266 (T-095): the ones enabled one by one are named apart.
        let enabled = safeModeEnabledPlugins
        let enabledNote = enabled.isEmpty ? "" : " Enabled: \(enabled.map(\.name).joined(separator: ", "))."
        guard !plugins.isEmpty else {
            return enabled.isEmpty ? "Safe mode: plugins are disabled for this session (this project has none)."
                : "Safe mode: every plugin was enabled one by one.\(enabledNote)"
        }
        let names = plugins.map(\.name).joined(separator: ", ")
        return "Safe mode: \(plugins.count == 1 ? "1 plugin is" : "\(plugins.count) plugins are") disabled for this session "
            + "(\(names)). Their settings are kept and saved as they were.\(enabledNote)"
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
        store.safeModeEnabledSlots = []  // DW-266: all of them load now
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
