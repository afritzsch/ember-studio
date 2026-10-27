/// Where a track or bus sends its main output.
public enum OutputTarget: Hashable, Sendable {
    case master
    case bus(NodeIDValue)
}

// JSON: {"kind": "master"} or {"kind": "bus", "id": 7}.
extension OutputTarget: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id }
    private enum Kind: String, Codable { case master, bus }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .master: self = .master
        case .bus: self = .bus(try c.decode(NodeIDValue.self, forKey: .id))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .master:
            try c.encode(Kind.master, forKey: .kind)
        case .bus(let id):
            try c.encode(Kind.bus, forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }
}
