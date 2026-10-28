import Foundation

/// A JSON document as a value, for migrations (MODEL-042): they rewrite an older project file's
/// shape before it is decoded as a `Project`, so they can't work on the Codable types.
///
/// Integers stay integers (IDs, ticks and frame counts are 64-bit and must round-trip exactly);
/// any other number is a `Double`.
public enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    /// A member of an object; nil for a missing key or a non-object. Setting nil removes the key.
    /// Setting on a non-object does nothing.
    public subscript(key: String) -> JSON? {
        get {
            if case .object(let members) = self { members[key] } else { nil }
        }
        set {
            guard case .object(var members) = self else { return }
            members[key] = newValue
            self = .object(members)
        }
    }

    public var intValue: Int64? {
        if case .int(let value) = self { value } else { nil }
    }

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var arrayValue: [JSON]? {
        if case .array(let value) = self { value } else { nil }
    }

    public init(parsing data: Data) throws(DAWError) {
        do {
            self = try JSONDecoder().decode(JSON.self, from: data)
        } catch {
            throw .invalidProject("not JSON: \(error)")
        }
    }

    /// MODEL-040: pretty-printed with sorted keys, like `project.json`.
    public func encoded() throws(DAWError) -> Data {
        do {
            return try ProjectFile.encoder.encode(self)
        } catch {
            throw .invalidProject("cannot encode JSON: \(error)")
        }
    }
}

extension JSON: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? c.decode(Double.self) {
            self = .double(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([JSON].self) {
            self = .array(value)
        } else {
            self = .object(try c.decode([String: JSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .int(let value): try c.encode(value)
        case .double(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}
