import DAWModel
import Foundation

/// UI-032, DW-250 (T-065): a device that can go into an insert chain, as the device pickers of the
/// device chain and the mixer strips offer it: the built-in effects, then every scanned AU/VST3
/// effect that isn't blocked (UI-041's list). Instruments aren't offered as inserts.
struct DeviceChoice: Equatable, Identifiable {
    enum Group: String { case builtin = "Built-in", au = "Audio Units", vst3 = "VST3" }

    /// `builtin.<node>` (`builtin.eq`) or `plugin.<n>`, the n-th scanned effect by name: the end of
    /// a picker's control id.
    let key: String
    let name: String
    let group: Group
    let kind: DeviceSlot.Kind

    var id: String { key }

    /// The built-in insert kinds in picker order (`DeviceSlot.builtinInsertKinds`, MODEL-005).
    static let builtinKinds: [NodeKind] = [.eq, .compressor, .delay, .reverb, .gain]

    /// Every choice, built-ins first; plugins from `plugins` (the manager's usable list).
    @MainActor
    static func all(plugins: [ScannedPlugin]) -> [DeviceChoice] {
        var out = builtinKinds.filter { DeviceSlot.builtinInsertKinds.contains($0) }.map { node in
            DeviceChoice(key: "builtin.\(node.rawValue)", name: MixerModel.insertName(.builtin(node)), group: .builtin,
                         kind: .builtin(node))
        }
        for (n, plugin) in plugins.filter({ !$0.isInstrument && !$0.isBlocked }).enumerated() {
            out.append(DeviceChoice(key: "plugin.\(n)", name: plugin.name, group: plugin.format == .au ? .au : .vst3,
                                    kind: plugin.slotKind))
        }
        return out
    }
}

extension ScannedPlugin {
    /// The device slot kind the model stores for this plugin (MODEL-005 `InsertDevice`).
    var slotKind: DeviceSlot.Kind {
        switch format {
        case .au: .au(AUDescriptor(identifier: identifier, name: name, vendor: vendor, version: version))
        case .vst3: .vst3(VST3Descriptor(identifier: identifier, name: name, vendor: vendor, version: version))
        }
    }
}
