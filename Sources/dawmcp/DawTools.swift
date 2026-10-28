import DAWControl
import Foundation
import MCP

/// CTL-021: every control method as an MCP tool (`project.new` → `daw_project_new`,
/// `transport.setLoop` → `daw_transport_set_loop`), with the params' generated JSON Schema as its
/// input schema. A call runs on the `Dispatcher` exactly as a JSON-RPC request would.
///
/// Results come back as one text item holding the result JSON. Failures set `isError` and carry the
/// JSON-RPC error object (`{code, message, data: {dawError, detail, …}}`, CTL-003). `daw_ui_snapshot`
/// also returns the PNG as image content (CTL-022).
@MainActor
final class DawTools {
    let dispatcher: Dispatcher

    init(dispatcher: Dispatcher) {
        self.dispatcher = dispatcher
    }

    nonisolated static func toolName(_ method: ControlMethod) -> String {
        var name = "daw_"
        for character in method.rawValue {
            if character == "." {
                name.append("_")
            } else if character.isUppercase {
                name += "_" + character.lowercased()
            } else {
                name.append(character)
            }
        }
        return name
    }

    nonisolated static let methodsByTool: [String: ControlMethod] = Dictionary(
        uniqueKeysWithValues: ControlMethod.allCases.map { (toolName($0), $0) })

    nonisolated static let tools: [Tool] = ControlMethod.allCases.map { method in
        Tool(name: toolName(method), description: description(method), inputSchema: Value(control: method.paramsSchema),
             annotations: .init(readOnlyHint: readOnly.contains(method) ? true : nil))
    }

    /// Tools that only look (MCP `readOnlyHint`).
    nonisolated static let readOnly: Set<ControlMethod> = [
        .projectGet, .commandSchema, .audioAnalyze, .audioCompare, .engineTelemetry, .engineEvents, .engineParamInfo,
        .uiState,
    ]

    private nonisolated static func description(_ method: ControlMethod) -> String {
        let summary = "\(method.summary). Control method \(method.rawValue) (specs/13-control-mcp.md)."
        switch method {
        case .commandApply, .commandBatch:
            return summary + " Command types and their fields: daw_command_schema."
        case .projectNew:
            return summary + " Headless: the n-th project of a session gets ID 00000000-0000-0000-0000-<n> (CTL-004)."
        case .engineTelemetry:
            return summary + " rtViolations must be 0 (CONV §5.3)."
        default:
            return summary
        }
    }

    func call(_ name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let method = Self.methodsByTool[name] else {
            return Self.failure(ControlError.methodNotFound(name).rpcError)
        }
        let result: JSONValue
        do {
            result = try await dispatcher.call(method, arguments.map { JSONValue(mcp: Value.object($0)) })
        } catch {
            return Self.failure(error.rpcError)
        }
        var content: [Tool.Content] = [.text(text: result.jsonString(), annotations: nil, _meta: nil)]
        // CTL-022: the snapshot itself, so the agent sees the window without opening a file.
        if method == .uiSnapshot, let path = result["pngPath"]?.stringValue {
            guard let png = FileManager.default.contents(atPath: path) else {
                return Self.failure(ControlError.internalError("ui.snapshot wrote no readable PNG at \(path)").rpcError)
            }
            content.insert(.image(data: png.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil), at: 0)
        }
        return CallTool.Result(content: content)
    }

    private nonisolated static func failure(_ error: RPCError) -> CallTool.Result {
        let json = (try? JSONValue(encoding: error))?.jsonString() ?? error.message
        return CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)], isError: true)
    }
}

// MCP's `Value` and the control protocol's `JSONValue` are both plain JSON; they convert through
// their Codable forms.
extension Value {
    init(control json: JSONValue) {
        self = (try? JSONDecoder().decode(Value.self, from: json.data())) ?? .null
    }
}

extension JSONValue {
    init(mcp value: MCP.Value) {
        self = (try? JSONValue(parsing: JSONEncoder().encode(value))) ?? .null
    }
}
