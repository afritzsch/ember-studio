import DAWControl
import Foundation
import Testing

// DW-297 (T-100, 13 "Contract delta (T-100)"): `ui.perform` takes `text` for action `setText`. The
// app runs it (EmberStudioShellTests `setTextOnToolbarFields`); here, the protocol side: the param
// decodes and reaches the UI provider, and the method schema documents it.

@MainActor
private final class RecordingUI: ControlUIProvider {
    var params: [UIPerformParams] = []
    func uiState() async throws -> JSONValue { [:] }
    func uiSnapshot(_ params: UISnapshotParams) async throws -> JSONValue { [:] }
    func uiPerform(_ params: UIPerformParams) async throws -> JSONValue {
        self.params.append(params)
        return ["text": .string(params.text ?? "")]
    }
}

@MainActor
@Suite("ui.perform setText (DW-297)")
struct UIPerformSetTextTests {
    @Test("DW-297: ui.perform {accessibilityId, action: setText, text} reaches the UI provider; text is optional and documented")
    func textReachesProvider() async throws {
        let ui = RecordingUI()
        let dispatcher = Dispatcher(configuration: .init(mode: .attach, ui: ui))
        let result = try await dispatcher.ok(.uiPerform, ["accessibilityId": "transport.tempo", "action": "setText", "text": "128"])
        #expect(result["text"] == "128")
        _ = try await dispatcher.ok(.uiPerform, ["accessibilityId": "transport.play", "action": "click"])
        #expect(ui.params.map(\.text) == ["128", nil])

        let schema = ControlMethod.uiPerform.paramsSchema
        #expect(schema["properties"]?["text"]?["type"] == "string")
        #expect(schema["properties"]?["text"]?["description"]?.stringValue?.contains("setText") == true)
        #expect(schema["required"]?.arrayValue?.contains("text") != true)
    }
}
