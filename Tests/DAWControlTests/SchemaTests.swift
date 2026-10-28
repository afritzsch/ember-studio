import DAWControl
import DAWModel
import Foundation
import Testing

// CTL-021 / CTL-024: JSON Schemas generated from the Codable params and the CommandRegistry.

private struct Inner: Codable {
    var flag: Bool
}

private struct Probed: Codable, JSONSchemaDocumented {
    enum Mode: String, Codable, CaseIterable { case fast, slow }
    var name: String
    var count: UInt8
    var ratio: Double?
    var ids: [ModelID]
    var inner: Inner
    var mode: Mode
    var tick: Tick
    var map: [String: Int]
    var blob: Data?
    var any: JSONValue?

    static var jsonSchemaDocs: [String: String] { ["name": "The name"] }
}

private struct Unprobeable: Codable {
    enum Hidden: String, Codable { case a }
    var ok: Int
    var hidden: Hidden
}

/// Registered at run time, like a tool's own command. All test targets share one CommandRegistry,
/// so the type string is prefixed.
private struct SchemaTestCommand: Command {
    static let type = "SchemaTestCommand"
    var note: String
    var label: String { "Note" }
    func apply(to project: inout Project) throws(DAWError) -> any Command { self }
}

@Suite("JSON Schemas (CTL-021, CTL-024)")
struct SchemaTests {
    @Test("CTL-021: the probe records keys, optionality, nesting, arrays, enums, dictionaries and docs")
    func probe() throws {
        let schema = try JSONSchema.strict(of: Probed.self)
        #expect(schema["type"] == "object")
        #expect(schema["required"] == ["name", "count", "ids", "inner", "mode", "tick", "map"])
        let p = try #require(schema["properties"])
        #expect(p["name"] == ["type": "string", "description": "The name"])
        #expect(p["count"] == ["type": "integer", "minimum": 0, "maximum": 255])
        #expect(p["ratio"] == ["type": "number"])
        #expect(p["ids"] == ["type": "array", "items": ["type": "integer", "minimum": 0]])
        #expect(p["inner"] == ["type": "object", "properties": ["flag": ["type": "boolean"]], "required": ["flag"]])
        #expect(p["mode"] == ["type": "string", "enum": ["fast", "slow"]])
        #expect(p["tick"] == ["type": "integer"])
        #expect(p["map"] == ["type": "object", "additionalProperties": ["type": "integer"]])
        #expect(p["blob"] == ["type": "string", "contentEncoding": "base64"])
        #expect(p["any"] == [:])
    }

    @Test("CTL-021: a type the probe can't see through yields a partial schema that says so")
    func incomplete() {
        #expect(throws: (any Error).self) { try JSONSchema.strict(of: Unprobeable.self) }
        let schema = JSONSchema.of(Unprobeable.self)
        #expect(schema["properties"]?["ok"] == ["type": "integer"])
        #expect(schema["description"]?.stringValue?.hasPrefix("incomplete schema") == true)
    }

    @Test("CTL-021: every control method has an object schema of its params")
    func methodSchemas() throws {
        for method in ControlMethod.allCases {
            let schema = method.paramsSchema
            #expect(schema["type"] == "object", "\(method.rawValue)")
            #expect(schema["description"] == nil, "\(method.rawValue): \(schema.jsonString())")
            #expect(try JSONSchema.strict(of: method.paramsType).objectValue != nil, "\(method.rawValue)")
        }
        let render = ControlMethod.renderOffline.paramsSchema
        #expect(render["required"] == ["from", "to", "path"])
        #expect(render["properties"]?["format"]?["enum"] == ["wav", "caf", "aiff"])
        #expect(render["properties"]?["blockSize"]?["description"] != nil)
        #expect(ControlMethod.undo.paramsSchema == ["type": "object", "properties": [:]])
        #expect(ControlMethod.engineParamInfo.paramsSchema["properties"]?["kind"]?["enum"]?.arrayValue?.count == NodeKind.allCases.count)
    }

    @Test("CTL-024: every built-in command has a complete schema with its type as a const")
    func builtInCommands() throws {
        for type in CommandRegistry.builtIn {
            #expect(throws: Never.self, "\(type.type)") { _ = try JSONSchema.strict(of: type) }
            let schema = CommandCatalog.schema(of: type)
            #expect(schema["properties"]?["type"] == ["const": .string(type.type)])
            #expect(schema["required"]?[0] == "type")
        }
        let addSend = CommandCatalog.schema(of: AddSend.self)
        #expect(addSend["required"] == ["type", "channelID", "busID"])
        #expect(addSend["properties"]?["tap"] == ["type": "string", "enum": ["preFader", "postFader"]])
        let output = try #require(CommandCatalog.schema(of: SetTrackOutput.self)["properties"]?["output"]?["oneOf"]?.arrayValue)
        #expect(output.map { $0["properties"]?["kind"] } == [["const": "master"], ["const": "bus"]])
    }

    @Test("CTL-024: the enum values the schemas list are the ones the types decode")
    func describedEnums() throws {
        func check<T: Decodable>(_ type: T.Type) throws {
            let values = try #require(JSONSchema.strict(of: type)["enum"]?.arrayValue, "\(type)")
            for value in values { #expect(throws: Never.self, "\(type) \(value)") { _ = try value.decode(T.self) } }
        }
        try check(SignalTap.self)
        try check(ParamTarget.StripParam.self)
        try check(Track.Kind.self)
        try check(Track.Monitoring.self)
        try check(ExportSpec.FileType.self)
        try check(ExportSpec.SampleFormat.self)
        try check(DeviceDriverKind.self)
        try check(DeviceEvent.Kind.self)
        // Tagged unions: every branch's smallest instance decodes.
        func branches<T: Decodable>(_ type: T.Type) throws {
            let oneOf = try #require(JSONSchema.strict(of: type)["oneOf"]?.arrayValue, "\(type)")
            for branch in oneOf {
                #expect(throws: Never.self, "\(type) \(branch)") { _ = try JSONSchema.minimalInstance(of: branch).decode(T.self) }
            }
        }
        try branches(OutputTarget.self)
        try branches(ParamTarget.self)
        try branches(Clip.self)
        try branches(DeviceSlot.Kind.self)
    }

    @Test("CTL-024: command.schema lists the registry, test-registered commands included, or one type")
    func commandSchemaMethod() async throws {
        CommandRegistry.register(SchemaTestCommand.self)
        let (dispatcher, _) = await TestDispatchers.fake()
        let all = try await dispatcher.ok(.commandSchema).decode(CommandSchemaResult.self)
        let types = all.commands.map(\.type)
        #expect(types == types.sorted())
        #expect(Set(CommandRegistry.builtIn.map { $0.type }).isSubset(of: types))
        #expect(types.contains(SchemaTestCommand.type))
        let one = try await dispatcher.ok(.commandSchema, ["type": "AddTrack"]).decode(CommandSchemaResult.self)
        #expect(one.commands.map(\.type) == ["AddTrack"])
        #expect(one.commands[0].schema["properties"]?["kind"]?["enum"] == ["audio", "midi"])
        let error = await dispatcher.failure(.commandSchema, ["type": "Nope"])
        #expect(error?.code == -32000 && error?.data?["dawError"] == "unknownCommandType")
    }

    @Test("CTL-024: a command built from its schema's smallest instance decodes")
    func schemaInstancesDecode() throws {
        for type in CommandRegistry.builtIn {
            let instance = JSONSchema.minimalInstance(of: CommandCatalog.schema(of: type))
            #expect(throws: Never.self, "\(type.type): \(instance.jsonString())") {
                _ = try CommandRegistry.decode(instance.data())
            }
        }
    }
}
