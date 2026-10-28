import Foundation

/// A type that states its own JSON Schema instead of having it inferred by `JSONSchema.of`. Needed
/// for types whose decoder can't be probed: tagged unions (`{"kind": …}` decided by a private
/// enum), string enums that aren't `CaseIterable`, and free-form JSON.
public protocol JSONSchemaDescribing: Decodable {
    static var jsonSchema: JSONValue { get }
    /// A value that decodes as `Self`, for probing the types that contain this one. Default: the
    /// smallest instance of `jsonSchema` (`JSONSchema.minimalInstance`).
    static var jsonSchemaExample: JSONValue? { get }
}

extension JSONSchemaDescribing {
    public static var jsonSchemaExample: JSONValue? { nil }
}

/// Descriptions for the properties of a type's schema (keyed by JSON property name).
public protocol JSONSchemaDocumented {
    static var jsonSchemaDocs: [String: String] { get }
}

/// CTL-021, CTL-024: JSON Schemas (draft 2020-12 subset) generated from `Decodable` types, so tool
/// inputs and the command catalogue follow the Codable params and commands without a hand-kept
/// list.
///
/// `of(_:)` decodes the type once from a probing decoder that records every key and value type the
/// type's `init(from:)` asks for: keys read with `decodeIfPresent` are optional, arrays probe one
/// element, `CaseIterable` raw-value enums list their cases. Types the probe can't see through
/// conform to `JSONSchemaDescribing` (see `ModelSchemas.swift`).
public enum JSONSchema {
    /// The schema of `type`. If probing fails part-way, returns what was learned so far and says
    /// why in `description` (use `strict(of:)` in tests).
    public static func of(_ type: any Decodable.Type) -> JSONValue {
        let probe = SchemaProbe()
        do {
            return try probe.schema(of: type)
        } catch {
            var schema = probe.partialSchema.objectValue ?? [:]
            schema["description"] = .string("incomplete schema for \(type): \(error)")
            return .object(schema)
        }
    }

    /// The schema of `type`, or the error that stopped the probe.
    public static func strict(of type: any Decodable.Type) throws -> JSONValue {
        try SchemaProbe().schema(of: type)
    }

    // MARK: Building blocks for JSONSchemaDescribing

    public static func stringEnum(_ values: [String], description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "enum": .array(values.map(JSONValue.string))]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    /// An object with these properties (required unless listed in `optional`).
    public static func object(
        _ properties: [String: JSONValue], optional: Set<String> = [], description: String? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        let required = properties.keys.filter { !optional.contains($0) }.sorted()
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    /// `{"<tag>": "<case>", …}` tagged unions: one `oneOf` branch per case, each the case's object
    /// schema with the tag as a required `const`.
    public static func taggedUnion(tag: String, _ cases: [(String, JSONValue)], description: String? = nil) -> JSONValue {
        let branches: [JSONValue] = cases.map { name, schema in
            var branch = schema.objectValue ?? ["type": "object"]
            var properties = branch["properties"]?.objectValue ?? [:]
            properties[tag] = ["const": .string(name)]
            branch["properties"] = .object(properties)
            let required = [JSONValue.string(tag)] + (branch["required"]?.arrayValue ?? []).filter { $0 != .string(tag) }
            branch["required"] = .array(required)
            branch["type"] = "object"
            return .object(branch)
        }
        var schema: [String: JSONValue] = ["oneOf": .array(branches)]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    /// The smallest JSON value `schema` accepts: required properties only, the first `enum` value or
    /// `oneOf` branch, empty arrays, zero or the minimum for numbers.
    public static func minimalInstance(of schema: JSONValue) -> JSONValue {
        guard let schema = schema.objectValue else { return .null }
        if let value = schema["const"] { return value }
        if let first = schema["enum"]?.arrayValue?.first { return first }
        if let first = (schema["oneOf"] ?? schema["anyOf"])?.arrayValue?.first { return minimalInstance(of: first) }
        switch schema["type"]?.stringValue {
        case "object":
            let properties = schema["properties"]?.objectValue ?? [:]
            var object: [String: JSONValue] = [:]
            for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                object[key] = minimalInstance(of: properties[key] ?? [:])
            }
            return .object(object)
        case "array": return .array([])
        case "string": return .string("")
        case "integer": return .int(schema["minimum"]?.int64Value ?? 0)
        case "number": return .double(schema["minimum"]?.doubleValue ?? 0)
        case "boolean": return .bool(false)
        default: return .null
        }
    }
}
