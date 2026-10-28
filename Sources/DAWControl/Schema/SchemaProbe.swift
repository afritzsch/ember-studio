import Foundation

/// The decoder behind `JSONSchema.of`: decodes a type from nothing, answering every request with a
/// placeholder (`""`, `0`, `false`, one array element) and recording what was asked for in a tree
/// of `Node`s, which then prints as a JSON Schema.
final class SchemaProbe {
    /// Deeper than any model type; a self-recursive type would otherwise probe forever.
    static let maxDepth = 32

    struct TooDeep: Error, CustomStringConvertible {
        var type: String
        var description: String { "\(type) nests deeper than \(SchemaProbe.maxDepth) levels (recursive?)" }
    }

    private let root = Node()
    private var depth = 0

    /// What the probe learned so far (after a failure, too).
    var partialSchema: JSONValue { root.schema }

    func schema(of type: any Decodable.Type) throws -> JSONValue {
        _ = try value(type, into: root, codingPath: [])
        return root.schema
    }

    /// Records the schema of `T` into `node` and returns a placeholder `T`.
    func value<T: Decodable>(_ type: T.Type, into node: Node, codingPath: [any CodingKey]) throws -> T {
        if let described = T.self as? any JSONSchemaDescribing.Type {
            let schema = described.jsonSchema
            node.kind = .fixed(schema)
            return try (described.jsonSchemaExample ?? JSONSchema.minimalInstance(of: schema)).decode(T.self)
        }
        // Foundation types JSONDecoder decodes specially (as strings, not by their own init(from:)).
        if T.self == Data.self {
            node.kind = .fixed(["type": "string", "contentEncoding": "base64"])
            return Data() as! T
        }
        if T.self == UUID.self {
            node.kind = .fixed(["type": "string", "format": "uuid"])
            return UUID(uuid: UUID_NULL) as! T
        }
        if T.self == URL.self {
            node.kind = .fixed(["type": "string", "format": "uri"])
            return URL(fileURLWithPath: "/") as! T
        }
        if let enumType = T.self as? any (CaseIterable & RawRepresentable).Type,
           let (schema, first) = Self.enumCases(enumType)
        {
            node.kind = .fixed(schema)
            return first as! T
        }
        guard depth < Self.maxDepth else { throw TooDeep(type: String(describing: T.self)) }
        depth += 1
        defer { depth -= 1 }
        if let documented = T.self as? any JSONSchemaDocumented.Type { node.docs = documented.jsonSchemaDocs }
        return try T(from: ProbeDecoder(probe: self, node: node, codingPath: codingPath))
    }

    private static func enumCases<E: CaseIterable & RawRepresentable>(_: E.Type) -> (JSONValue, Any)? {
        let values: [JSONValue] = E.allCases.compactMap { value in
            switch value.rawValue as Any {
            case let string as String: .string(string)
            case let int as Int: .int(Int64(int))
            default: nil
            }
        }
        guard let first = E.allCases.first, !values.isEmpty, values.count == E.allCases.count else { return nil }
        let type: JSONValue = values[0].stringValue != nil ? "string" : "integer"
        return (["type": type, "enum": .array(values)], first)
    }

    static func integerSchema<I: FixedWidthInteger>(_: I.Type) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer"]
        if I.bitWidth <= 32 {
            schema["minimum"] = .int(Int64(I.min))
            schema["maximum"] = .int(Int64(I.max))
        } else if !I.isSigned {
            schema["minimum"] = 0
        }
        return .object(schema)
    }
}

/// One value in the type being probed.
final class Node {
    enum Kind {
        case unknown
        case fixed(JSONValue)
        case object
        case array(Node)
    }

    struct Property {
        var key: String
        var node: Node
        var required: Bool
    }

    var kind: Kind = .unknown
    var properties: [Property] = []
    var docs: [String: String] = [:]

    func makeObject() {
        if case .object = kind { return }
        kind = .object
    }

    func property(_ key: String, required: Bool) -> Node {
        if let index = properties.firstIndex(where: { $0.key == key }) {
            properties[index].required = properties[index].required || required
            return properties[index].node
        }
        let node = Node()
        properties.append(Property(key: key, node: node, required: required))
        return node
    }

    var schema: JSONValue {
        switch kind {
        case .unknown: return [:]
        case .fixed(let schema): return schema
        case .array(let element): return ["type": "array", "items": element.schema]
        case .object:
            // A dictionary probes as one wildcard key (ProbeKeyedContainer.allKeys).
            if properties.count == 1, properties[0].key == ProbeKeyedContainer<AnyKey>.wildcard {
                return ["type": "object", "additionalProperties": properties[0].node.schema]
            }
            var schemas: [String: JSONValue] = [:]
            for property in properties {
                var schema = property.node.schema
                if let doc = docs[property.key], case .object(var object) = schema {
                    object["description"] = .string(doc)
                    schema = .object(object)
                }
                schemas[property.key] = schema
            }
            var object: [String: JSONValue] = ["type": "object", "properties": .object(schemas)]
            let required = properties.filter(\.required).map { JSONValue.string($0.key) }
            if !required.isEmpty { object["required"] = .array(required) }
            return .object(object)
        }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init(intValue: Int) { (stringValue, self.intValue) = (String(intValue), intValue) }
}

struct ProbeDecoder: Decoder {
    let probe: SchemaProbe
    let node: Node
    var codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        node.makeObject()
        return KeyedDecodingContainer(ProbeKeyedContainer<Key>(probe: probe, node: node, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        ProbeUnkeyedContainer(probe: probe, node: node, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        ProbeSingleValueContainer(probe: probe, node: node, codingPath: codingPath)
    }
}

struct ProbeKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    /// The one key a dictionary sees, so its value type gets probed.
    static var wildcard: String { "*" }

    let probe: SchemaProbe
    let node: Node
    var codingPath: [any CodingKey]

    // Only key types that accept any string (dictionaries) see a key; a fixed CodingKeys enum
    // sees none.
    var allKeys: [Key] { Key(stringValue: Self.wildcard).map { [$0] } ?? [] }

    func contains(_ key: Key) -> Bool { true }
    func decodeNil(forKey key: Key) throws -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try probe.value(T.self, into: node.property(key.stringValue, required: true), codingPath: codingPath + [key])
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        _ = try probe.value(T.self, into: node.property(key.stringValue, required: false), codingPath: codingPath + [key])
        return nil
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let child = node.property(key.stringValue, required: true)
        child.makeObject()
        return KeyedDecodingContainer(ProbeKeyedContainer<NestedKey>(probe: probe, node: child, codingPath: codingPath + [key]))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        ProbeUnkeyedContainer(probe: probe, node: node.property(key.stringValue, required: true), codingPath: codingPath + [key])
    }

    func superDecoder() throws -> any Decoder { ProbeDecoder(probe: probe, node: node, codingPath: codingPath) }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        ProbeDecoder(probe: probe, node: node.property(key.stringValue, required: true), codingPath: codingPath + [key])
    }

    // The protocol's primitive overloads; all go through the generic probe.
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decode(type, key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try decode(type, key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decode(type, key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decode(type, key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try decode(type, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try decode(type, key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decode(type, key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decode(type, key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decode(type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try decode(type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try decode(type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decode(type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decode(type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decode(type, key) }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try optional(type, key) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try optional(type, key) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try optional(type, key) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { try optional(type, key) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try optional(type, key) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { try optional(type, key) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { try optional(type, key) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try optional(type, key) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try optional(type, key) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { try optional(type, key) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { try optional(type, key) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { try optional(type, key) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { try optional(type, key) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { try optional(type, key) }

    private func decode<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T {
        try probe.value(T.self, into: node.property(key.stringValue, required: true), codingPath: codingPath + [key])
    }

    private func optional<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T? {
        try decodeIfPresent(type, forKey: key)
    }
}

/// Arrays probe as one element.
struct ProbeUnkeyedContainer: UnkeyedDecodingContainer {
    let probe: SchemaProbe
    let element: Node
    var codingPath: [any CodingKey]
    var currentIndex = 0
    var count: Int? { 1 }
    var isAtEnd: Bool { currentIndex >= 1 }

    init(probe: SchemaProbe, node: Node, codingPath: [any CodingKey]) {
        self.probe = probe
        self.codingPath = codingPath
        if case .array(let element) = node.kind {
            self.element = element
        } else {
            element = Node()
            node.kind = .array(element)
        }
    }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        defer { currentIndex += 1 }
        return try probe.value(T.self, into: element, codingPath: codingPath + [AnyKey(intValue: currentIndex)])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        defer { currentIndex += 1 }
        element.makeObject()
        return KeyedDecodingContainer(ProbeKeyedContainer<NestedKey>(probe: probe, node: element, codingPath: codingPath))
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        defer { currentIndex += 1 }
        return ProbeUnkeyedContainer(probe: probe, node: element, codingPath: codingPath)
    }

    mutating func superDecoder() throws -> any Decoder {
        defer { currentIndex += 1 }
        return ProbeDecoder(probe: probe, node: element, codingPath: codingPath)
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try decode(type, ()) }
    mutating func decode(_ type: String.Type) throws -> String { try decode(type, ()) }
    mutating func decode(_ type: Double.Type) throws -> Double { try decode(type, ()) }
    mutating func decode(_ type: Float.Type) throws -> Float { try decode(type, ()) }
    mutating func decode(_ type: Int.Type) throws -> Int { try decode(type, ()) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try decode(type, ()) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try decode(type, ()) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try decode(type, ()) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try decode(type, ()) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try decode(type, ()) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try decode(type, ()) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try decode(type, ()) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try decode(type, ()) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try decode(type, ()) }

    private mutating func decode<T: Decodable>(_ type: T.Type, _: Void) throws -> T {
        try decode(type)
    }
}

/// Primitives are recorded here; everything else recurses through the probe.
struct ProbeSingleValueContainer: SingleValueDecodingContainer {
    let probe: SchemaProbe
    let node: Node
    var codingPath: [any CodingKey]

    func decodeNil() -> Bool { false }

    func decode(_ type: Bool.Type) throws -> Bool { record(["type": "boolean"], false) }
    func decode(_ type: String.Type) throws -> String { record(["type": "string"], "") }
    func decode(_ type: Double.Type) throws -> Double { record(["type": "number"], 0) }
    func decode(_ type: Float.Type) throws -> Float { record(["type": "number"], 0) }
    func decode(_ type: Int.Type) throws -> Int { integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { integer(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try probe.value(T.self, into: node, codingPath: codingPath)
    }

    private func record<T>(_ schema: JSONValue, _ placeholder: T) -> T {
        node.kind = .fixed(schema)
        return placeholder
    }

    private func integer<I: FixedWidthInteger>(_ type: I.Type) -> I {
        record(SchemaProbe.integerSchema(type), 0)
    }
}
