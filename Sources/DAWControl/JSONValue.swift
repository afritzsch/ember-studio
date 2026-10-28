import Foundation

/// Any JSON value. Params and results cross the control protocol as JSON (CTL-001); handlers
/// decode them into typed Codable structs, and `project.get` returns project JSON as one of these.
///
/// Integers are kept apart from doubles so model IDs (up to 2^56) round-trip exactly.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { array[index] } else { nil }
    }

    public var stringValue: String? {
        if case .string(let s) = self { s } else { nil }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { b } else { nil }
    }

    /// An integer, or a double with an integral value.
    public var int64Value: Int64? {
        switch self {
        case .int(let i): i
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e18: Int64(d)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { a } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { o } else { nil }
    }
}

// MARK: Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: Conversions

extension JSONValue {
    /// Sorted keys, so equal values encode to equal bytes (CTL-004 compares project JSON).
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The JSON form of any Encodable value.
    public init(encoding value: some Encodable) throws {
        let data = try Self.makeEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Parses one JSON text.
    public init(parsing data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value as `type` (e.g. a method's params struct).
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data())
    }

    /// Compact JSON with sorted keys.
    public func data() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Compact JSON with sorted keys, on one line (newline-delimited transports, CTL-001).
    public func jsonString() -> String {
        // Encoding a JSONValue only fails for a non-finite double; results never carry one
        // (audio levels are floored, see AudioAnalysis).
        (try? data()).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// RFC 6901 JSON Pointer lookup (`project.get` `path`). "" is the whole value.
    public func resolve(pointer: String) -> JSONValue? {
        guard !pointer.isEmpty else { return self }
        guard pointer.hasPrefix("/") else { return nil }
        var current = self
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch current {
            case .object(let object):
                guard let next = object[token] else { return nil }
                current = next
            case .array(let array):
                guard let index = Int(token), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
