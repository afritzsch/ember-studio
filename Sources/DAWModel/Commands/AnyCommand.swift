/// Codable box for an existential command: encodes and decodes the `"type"`-tagged JSON form
/// (MODEL-006), looking the type up in `CommandRegistry`.
public struct AnyCommand: Codable, Sendable {
    public let base: any Command

    public init(_ base: any Command) {
        self.base = base
    }

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
        guard let commandType = CommandRegistry.commandType(named: type) else {
            throw DAWError.unknownCommandType(type)
        }
        base = try commandType.init(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        // The command's fields and "type" share one JSON object.
        try base.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Swift.type(of: base).type, forKey: .type)
    }
}
