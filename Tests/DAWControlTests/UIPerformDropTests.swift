import DAWControl
import Foundation
import Testing

// UI-063/UI-067 (T-124, 13 "Contract delta (T-124)"): `ui.perform` takes `track` and `tick` for
// action `drop` on a browser item. The app runs it (EmberStudioShellTests `BrowserAttachTests`);
// here, the protocol side: the params decode and reach the UI provider, and the schema documents them.

@MainActor
private final class RecordingUI: ControlUIProvider {
    var params: [UIPerformParams] = []
    func uiState() async throws -> JSONValue { [:] }
    func uiSnapshot(_ params: UISnapshotParams) async throws -> JSONValue { [:] }
    func uiPerform(_ params: UIPerformParams) async throws -> JSONValue {
        self.params.append(params)
        return [:]
    }
}

@MainActor
@Suite("ui.perform drop (UI-067)")
struct UIPerformDropTests {
    @Test("UI-067: ui.perform {accessibilityId, action: drop, tick, track?} reaches the UI provider; both are optional and documented")
    func dropParamsReachProvider() async throws {
        let ui = RecordingUI()
        let dispatcher = Dispatcher(configuration: .init(mode: .attach, ui: ui))
        _ = try await dispatcher.ok(.uiPerform, ["accessibilityId": "browser.item.0123456789abcdef", "action": "drop", "track": 7, "tick": 1920])
        _ = try await dispatcher.ok(.uiPerform, ["accessibilityId": "browser.item.0123456789abcdef", "action": "drop", "tick": 0])
        _ = try await dispatcher.ok(.uiPerform, ["accessibilityId": "transport.play", "action": "click"])
        #expect(ui.params.map(\.track) == [7, nil, nil])
        #expect(ui.params.map(\.tick) == [1920, 0, nil])

        let schema = ControlMethod.uiPerform.paramsSchema
        #expect(schema["properties"]?["track"]?["type"] == "integer")
        #expect(schema["properties"]?["tick"]?["type"] == "integer")
        #expect(schema["properties"]?["tick"]?["description"]?.stringValue?.contains("drop") == true)
        #expect(schema["properties"]?["action"]?["description"]?.stringValue?.contains("drop") == true)
        let required = schema["required"]?.arrayValue ?? []
        #expect(!required.contains("track") && !required.contains("tick"))
    }
}
