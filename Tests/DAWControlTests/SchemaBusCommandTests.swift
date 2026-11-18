import DAWControl
import DAWModel
import Foundation
import Testing

// CTL-024 (T-102): command.schema lists RenameBus and MoveBus (DW-113), and its plugin descriptor
// shape, which leaves `vendor`/`version` optional, matches what the decoder accepts (DW-296).

@Suite("command.schema (T-102)")
@MainActor
struct SchemaBusCommandTests {
    @Test("CTL-024, DW-113: command.schema lists RenameBus {busID, name} and MoveBus {busID, index}")
    func schemaListsBusCommands() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        let all = try await dispatcher.ok(.commandSchema)["commands"]?.arrayValue ?? []
        let types = Set(all.compactMap { $0["type"]?.stringValue })
        #expect(types.isSuperset(of: ["RenameBus", "MoveBus"]))
        let rename = try await dispatcher.ok(.commandSchema, ["type": "RenameBus"])["commands"]?[0]?["schema"]
        #expect(rename?["required"] == ["type", "busID", "name"])
        let move = try await dispatcher.ok(.commandSchema, ["type": "MoveBus"])["commands"]?[0]?["schema"]
        #expect(move?["required"] == ["type", "busID", "index"])
    }

    @Test("CTL-024, DW-296: the AU and VST3 descriptor schemas don't require vendor/version, and an InsertDevice without them decodes")
    func descriptorSchemaMatchesDecoder() throws {
        for schema in [JSONSchema.of(AUDescriptor.self), JSONSchema.of(VST3Descriptor.self)] {
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(Set(required).isSuperset(of: ["identifier", "name"]))
            #expect(!required.contains("vendor") && !required.contains("version"))
        }
        let json = #"{"type":"InsertDevice","channel":1,"device":{"format":"au","identifier":"aufx:dely:appl","name":"AUDelay"}}"#
        #expect(throws: Never.self) { _ = try CommandRegistry.decode(Data(json.utf8)) }
    }
}
