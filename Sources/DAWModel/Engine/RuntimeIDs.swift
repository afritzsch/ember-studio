import Foundation

/// MODEL-022: engine-side IDs the model needs but never persists. `EngineSync` asks the engine for
/// a param range per param-bearing node when it first appears and keeps it here; a project that
/// is opened again starts with an empty `RuntimeIDs`, so everything is reallocated.
///
/// GraphDescriptionBuilder reads it to fill `firstParam`/`numParams` and `configVersion`.
public struct RuntimeIDs: Hashable, Sendable {
    /// `count` contiguous slots from `first` (ENG-020).
    public struct ParamRange: Hashable, Sendable {
        public var first: ParamID
        public var count: UInt32

        public init(first: ParamID, count: UInt32) {
            self.first = first
            self.count = count
        }

        /// The slot for param `index` of the node, nil if out of range.
        public func id(_ index: UInt32) -> ParamID? { index < count ? first + index : nil }
    }

    /// Keyed by graph NodeID (GraphNodeID): a strip by its channel's ID, a send or device slot by
    /// its own ID, the master's limiter by `GraphNodeID.output(of: master.id)`.
    public var params: [NodeIDValue: ParamRange]
    /// DW-072: clip players whose clips (or the assets they use) changed get a new version, so the
    /// engine creates an instance with the new clip set (DW-051). Missing means 0.
    public var configVersions: [NodeIDValue: UInt32]

    public init(params: [NodeIDValue: ParamRange] = [:], configVersions: [NodeIDValue: UInt32] = [:]) {
        self.params = params
        self.configVersions = configVersions
    }

    /// The slot for param `index` of `node`.
    public func paramID(_ node: NodeIDValue, _ index: UInt32) -> ParamID? { params[node]?.id(index) }

    /// A channel strip's slot (`ParamLayout.Strip`) for a track, bus or the master.
    public func stripParam(_ channel: NodeIDValue, _ index: UInt32) -> ParamID? { paramID(channel, index) }
    /// A send's level slot.
    public func sendLevelParam(_ send: ModelID) -> ParamID? { paramID(send, ParamLayout.Send.level) }
    /// A send's mute slot (MIX-007).
    public func sendMuteParam(_ send: ModelID) -> ParamID? { paramID(send, ParamLayout.Send.mute) }
    /// Param `index` of a device slot, as in its kind's ParamInfo list.
    public func deviceParam(_ slot: NodeIDValue, _ index: UInt32) -> ParamID? { paramID(slot, index) }
    /// MIX-009: the master's safety limiter switch (on when ≥ 0.5).
    public func masterLimiterParam(_ master: NodeIDValue) -> ParamID? {
        paramID(GraphNodeID.output(of: master), ParamLayout.Master.limiter)
    }
    /// TIME-010 (T-026): param `index` (`ParamLayout.Metronome`) of the project metronome.
    public func metronomeParam(_ master: NodeIDValue, _ index: UInt32) -> ParamID? {
        paramID(GraphNodeID.metronome(of: master), index)
    }
}

/// The param slots of the nodes the model lays out itself. Device slots follow their kind's
/// ParamInfo list instead (`ParamCatalog`).
public enum ParamLayout {
    /// MIX-005, DSP-010. Agreed with T-020: gain and pan come first (T-013), mute and phase are
    /// appended. The model writes the solo-resolved mute here (MIX-006); solo has no slot.
    public enum Strip {
        public static let gain: UInt32 = 0
        public static let pan: UInt32 = 1
        /// 1 = muted, 0 = audible.
        public static let mute: UInt32 = 2
        /// 1 = inverted.
        public static let phase: UInt32 = 3
        public static let count: UInt32 = 4
    }

    /// MIX-007: a send is a `NodeKind.gain` node with a smoothed level slot (linear amplitude)
    /// and a mute slot. The model writes its owner's resolved mute (MIX-006) into the mute slot,
    /// so a muted track silences all its sends, pre-fader included; the level keeps its value.
    public enum Send {
        public static let level: UInt32 = 0
        /// 1 = muted, 0 = audible.
        public static let mute: UInt32 = 1
        public static let count: UInt32 = 2
    }

    /// MIX-009: the master node's limiter switch.
    public enum Master {
        public static let limiter: UInt32 = 0
        public static let count: UInt32 = 1
    }

    /// TIME-010 / DSP-011 (T-026): the metronome node's slots, as `Metronome::kParamInfo`
    /// (nodes/Metronome.h; the engine publishes them through `paramInfoJSON(.metronome)`).
    public enum Metronome {
        /// Switch: clicks while ≥ 0.5. The model writes `MetronomeSettings.enabled` here.
        public static let on: UInt32 = 0
        /// Linear amplitude of a beat click.
        public static let level: UInt32 = 1
        /// Linear gain of a downbeat over `level`.
        public static let accent: UInt32 = 2
        public static let count: UInt32 = 3
    }
}

/// How many param slots a device slot gets and what they start at, from each kind's ParamInfo
/// (`EngineProtocol.paramInfoJSON`, 06/PLUG-015). Kinds without published ParamInfo get as many
/// slots as the slot's stored values need, starting at 0.
public struct ParamCatalog: Hashable, Sendable {
    /// Per kind, the default of each param in index order.
    public var defaults: [NodeKind: [Float]]

    public init(defaults: [NodeKind: [Float]] = [:]) {
        self.defaults = defaults
    }

    /// Reads every kind's ParamInfo from the engine.
    public init(engine: any EngineProtocol) {
        var defaults: [NodeKind: [Float]] = [:]
        for kind in NodeKind.allCases {
            let values = Self.parseDefaults(engine.paramInfoJSON(kind))
            if !values.isEmpty { defaults[kind] = values }
        }
        self.init(defaults: defaults)
    }

    public func paramCount(for slot: DeviceSlot) -> UInt32 {
        let published = defaults[slot.nodeKind]?.count ?? 0
        let stored = (slot.params.map(\.index).max() ?? -1) + 1
        return UInt32(max(published, stored))
    }

    public func defaultValue(for slot: DeviceSlot, _ index: Int) -> Float {
        // PLUG-015 (T-061): a hosted plugin's param without a stored value is NaN, "not set": the
        // engine leaves the plugin's own value alone (AUPluginNode), whatever the state set it to.
        if slot.nodeKind == .auPlugin || slot.nodeKind == .vst3Plugin { return .nan }
        guard let values = defaults[slot.nodeKind], values.indices.contains(index) else { return 0 }
        return values[index]
    }

    /// `[{"index": 0, "default": 1.0, …}, …]` → defaults by index. Malformed JSON gives none.
    static func parseDefaults(_ json: String) -> [Float] {
        struct Info: Decodable {
            var index: Int
            var `default`: Float
        }
        guard let infos = try? JSONDecoder().decode([Info].self, from: Data(json.utf8)), !infos.isEmpty,
            let last = infos.map(\.index).max(), last >= 0, last < 4096
        else { return [] }
        var values = [Float](repeating: 0, count: last + 1)
        for info in infos where info.index >= 0 { values[info.index] = info.default }
        return values
    }
}

extension DeviceSlot {
    /// The graph node kind this slot runs as.
    public var nodeKind: NodeKind {
        switch kind {
        case .builtin(let kind): kind
        case .au: .auPlugin
        case .vst3: .vst3Plugin
        }
    }
}
