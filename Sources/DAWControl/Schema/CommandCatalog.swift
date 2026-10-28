import DAWModel

/// CTL-024: the catalogue of Command types with their JSON Schemas, generated from
/// `CommandRegistry`, so every command a task registers shows up without a hand-kept list.
public enum CommandCatalog {
    public static func schemas(_ params: CommandSchemaParams = .init()) throws(DAWError) -> CommandSchemaResult {
        let types: [any Command.Type]
        if let name = params.type {
            guard let type = CommandRegistry.commandType(named: name) else { throw .unknownCommandType(name) }
            types = [type]
        } else {
            types = CommandRegistry.registered
        }
        return CommandSchemaResult(commands: types.map { .init(type: $0.type, schema: schema(of: $0)) })
    }

    /// The command's wire form (MODEL-006): its own fields plus `"type"`.
    public static func schema(of type: any Command.Type) -> JSONValue {
        var schema = JSONSchema.of(type).objectValue ?? [:]
        var properties = schema["properties"]?.objectValue ?? [:]
        properties["type"] = ["const": .string(type.type)]
        schema["type"] = "object"
        schema["properties"] = .object(properties)
        schema["required"] = .array(["type"] + (schema["required"]?.arrayValue ?? []))
        return .object(schema)
    }
}
