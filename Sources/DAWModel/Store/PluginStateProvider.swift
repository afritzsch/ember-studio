import Foundation

/// MODEL-043 seam: where plugin state comes from at save time and goes after open.
///
/// The folder format is done: each slot's state is `Plugins/<slotID>.state` (and
/// `autosave/Plugins/<slotID>.state`), read back into `DeviceSlot.pluginState` on open.
/// Instantiating hosted plugins and restoring into them is plugin hosting's (10): until it exists,
/// `EnginePluginStates` reads and writes whatever the engine holds for a slot.
@MainActor
public protocol PluginStateProvider: AnyObject {
    /// The current state of every slot that has one. Slots left out keep the state stored in the
    /// project (`DeviceSlot.pluginState`).
    func capturePluginStates(of project: Project) -> [NodeIDValue: Data]
    /// Called by `ProjectStore.restorePluginStates()` with every stored state, after the slots'
    /// plugins are instantiated.
    func restorePluginStates(_ states: [NodeIDValue: Data])
}

/// A `PluginStateProvider` over the facade's `getPluginState`/`setPluginState` (08 Interfaces).
@MainActor
public final class EnginePluginStates: PluginStateProvider {
    public let engine: any EngineProtocol

    public init(engine: any EngineProtocol) {
        self.engine = engine
    }

    /// Hosted plugin slots (AU, VST3) only: built-in devices keep their state in params.
    public func capturePluginStates(of project: Project) -> [NodeIDValue: Data] {
        var states: [NodeIDValue: Data] = [:]
        project.forEachDeviceSlot { slot, _ in
            guard slot.kind.isHostedPlugin else { return }
            let state = engine.pluginState(slot: slot.id)
            if !state.isEmpty { states[slot.id] = state }
        }
        return states
    }

    public func restorePluginStates(_ states: [NodeIDValue: Data]) {
        for (slot, state) in states.sorted(by: { $0.key < $1.key }) {
            engine.setPluginState(slot: slot, state)
        }
    }
}

extension DeviceSlot.Kind {
    var isHostedPlugin: Bool {
        if case .builtin = self { false } else { true }
    }
}

extension Project {
    /// Every slot's stored plugin state.
    public var pluginStates: [NodeIDValue: Data] {
        var states: [NodeIDValue: Data] = [:]
        forEachDeviceSlot { slot, _ in
            if let state = slot.pluginState { states[slot.id] = state }
        }
        return states
    }

    /// Runs `body` on every device slot in place, in `forEachDeviceSlot` order.
    mutating func updateEachDeviceSlot(_ body: (inout DeviceSlot) -> Void) {
        for t in tracks.indices {
            if tracks[t].instrument != nil { body(&tracks[t].instrument!) }
            for i in tracks[t].inserts.indices { body(&tracks[t].inserts[i]) }
        }
        for b in buses.indices {
            for i in buses[b].inserts.indices { body(&buses[b].inserts[i]) }
        }
        for i in master.inserts.indices { body(&master.inserts[i]) }
    }
}
