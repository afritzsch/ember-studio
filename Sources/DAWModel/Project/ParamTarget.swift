/// A continuous or switch parameter of the document, as `SetParam` (MODEL-005, DW-094) addresses
/// it. The same targets are what automation lanes point at (11, AUTO-008), so 11's `ParamTarget`
/// can be this type.
///
/// JSON: `{"kind": "strip", "channel": 7, "param": "gain"}`, `{"kind": "sendLevel", "send": 9}`,
/// `{"kind": "device", "slot": 5, "index": 2}`.
public enum ParamTarget: Hashable, Sendable {
    /// A control on the strip of a track, bus or the master (MIX-005, MIX-006).
    case strip(channel: NodeIDValue, param: StripParam)
    /// A send's level (MIX-007).
    case sendLevel(send: ModelID)
    /// Param `index` of a device slot, in its kind's ParamInfo order (06, PLUG-015).
    case device(slot: NodeIDValue, index: Int)

    public enum StripParam: String, Hashable, Sendable, Codable {
        /// Linear amplitude, 0…+12 dB.
        case gain
        /// −1 (left) … 1 (right).
        case pan
        /// Switches: on at ≥ 0.5, like their param slots (MIX-005).
        case mute, solo, phase
    }
}

extension ParamTarget: Codable {
    private enum CodingKeys: String, CodingKey { case kind, channel, param, send, slot, index }
    private enum Kind: String, Codable { case strip, sendLevel, device }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .strip:
            self = .strip(channel: try c.decode(NodeIDValue.self, forKey: .channel),
                          param: try c.decode(StripParam.self, forKey: .param))
        case .sendLevel:
            self = .sendLevel(send: try c.decode(ModelID.self, forKey: .send))
        case .device:
            self = .device(slot: try c.decode(NodeIDValue.self, forKey: .slot), index: try c.decode(Int.self, forKey: .index))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .strip(let channel, let param):
            try c.encode(Kind.strip, forKey: .kind)
            try c.encode(channel, forKey: .channel)
            try c.encode(param, forKey: .param)
        case .sendLevel(let send):
            try c.encode(Kind.sendLevel, forKey: .kind)
            try c.encode(send, forKey: .send)
        case .device(let slot, let index):
            try c.encode(Kind.device, forKey: .kind)
            try c.encode(slot, forKey: .slot)
            try c.encode(index, forKey: .index)
        }
    }
}
