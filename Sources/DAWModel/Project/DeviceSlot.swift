import Foundation

/// An instrument or insert: a built-in node or a hosted plugin.
public struct DeviceSlot: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable {
        case builtin(NodeKind)
        case au(AUDescriptor)
        case vst3(VST3Descriptor)
    }

    public var id: NodeIDValue
    public var kind: Kind
    /// Param values to restore into the slot's param slots. ParamIDs themselves are runtime-only
    /// (MODEL-022).
    public var params: [ParamValue]
    /// Opaque plugin state, captured at save time (MODEL-043).
    public var pluginState: Data?
    public var bypass: Bool
    public var sidechainSource: SidechainRef?
    /// DW-140: a built-in sampler's zones (DSP-020), empty for every other kind. Sent to the
    /// engine as the node's `configJSON`.
    public var zones: [SamplerZone]

    public init(
        id: NodeIDValue, kind: Kind, params: [ParamValue] = [], pluginState: Data? = nil,
        bypass: Bool = false, sidechainSource: SidechainRef? = nil, zones: [SamplerZone] = []
    ) {
        self.id = id
        self.kind = kind
        self.params = params
        self.pluginState = pluginState
        self.bypass = bypass
        self.sidechainSource = sidechainSource
        self.zones = zones
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, params, pluginState, bypass, sidechainSource, zones
    }

    // `zones` is written only when there are some, so slots without zones keep the JSON they had
    // before T-042 and older files decode.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(NodeIDValue.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        params = try c.decode([ParamValue].self, forKey: .params)
        pluginState = try c.decodeIfPresent(Data.self, forKey: .pluginState)
        bypass = try c.decode(Bool.self, forKey: .bypass)
        sidechainSource = try c.decodeIfPresent(SidechainRef.self, forKey: .sidechainSource)
        zones = try c.decodeIfPresent([SamplerZone].self, forKey: .zones) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(params, forKey: .params)
        try c.encodeIfPresent(pluginState, forKey: .pluginState)
        try c.encode(bypass, forKey: .bypass)
        try c.encodeIfPresent(sidechainSource, forKey: .sidechainSource)
        if !zones.isEmpty { try c.encode(zones, forKey: .zones) }
    }

    /// The built-in sampler: the only built-in instrument (D-19) and the only kind with zones.
    public var isSampler: Bool { kind == .builtin(.sampler) }
}

/// One parameter of a device slot. `index` is the position in the kind's `ParamInfo` list
/// (06, PLUG-015).
public struct ParamValue: Hashable, Sendable, Codable {
    public var index: Int
    public var value: Float

    public init(index: Int, value: Float) {
        self.index = index
        self.value = value
    }
}

/// The track or bus feeding a device's sidechain input (MIX-008).
public struct SidechainRef: Hashable, Sendable, Codable {
    public var source: NodeIDValue
    public var tap: SignalTap

    public init(source: NodeIDValue, tap: SignalTap = .postFader) {
        self.source = source
        self.tap = tap
    }
}

// JSON: {"format": "builtin", "node": "eq"}, or {"format": "au" | "vst3", …descriptor fields}.
extension DeviceSlot.Kind: Codable {
    private enum CodingKeys: String, CodingKey { case format, node }
    private enum Format: String, Codable { case builtin, au, vst3 }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Format.self, forKey: .format) {
        case .builtin: self = .builtin(try c.decode(NodeKind.self, forKey: .node))
        case .au: self = .au(try AUDescriptor(from: decoder))
        case .vst3: self = .vst3(try VST3Descriptor(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let node):
            try c.encode(Format.builtin, forKey: .format)
            try c.encode(node, forKey: .node)
        case .au(let descriptor):
            try c.encode(Format.au, forKey: .format)
            try descriptor.encode(to: encoder)
        case .vst3(let descriptor):
            try c.encode(Format.vst3, forKey: .format)
            try descriptor.encode(to: encoder)
        }
    }
}
