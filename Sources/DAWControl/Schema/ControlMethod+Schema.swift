extension ControlMethod {
    /// CTL-021: JSON Schema of the method's params (an object), generated from `paramsType`.
    public var paramsSchema: JSONValue {
        var schema = JSONSchema.of(paramsType).objectValue ?? [:]
        schema["type"] = "object"
        if schema["properties"] == nil { schema["properties"] = [:] }
        return .object(schema)
    }
}
