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
///
/// CTL-023: `daw_session_mode` switches between the in-process headless dispatcher (the default)
/// and attach mode, where every other tool goes over the socket of this checkout's running app.
/// CTL-031 / DW-133: a call that carries `_meta.progressToken` gets MCP `notifications/progress`
/// while it runs, in either mode.
@MainActor
final class DawTools {
    let dispatcher: Dispatcher
    let attachSetup: AttachSetup
    /// The app attach mode talks to; nil in headless mode.
    private(set) var attached: AttachedApp?
    /// Sends one MCP progress notification (set by the server; tests collect them).
    var sendProgress: (@Sendable (ProgressNotification.Parameters) async -> Void)?

    init(dispatcher: Dispatcher, attachSetup: AttachSetup = .currentCheckout()) {
        self.dispatcher = dispatcher
        self.attachSetup = attachSetup
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

    /// One tool per control method, then `daw_session_mode` (CTL-023).
    nonisolated static let tools: [Tool] = ControlMethod.allCases.map { method in
        Tool(name: toolName(method), description: description(method), inputSchema: Value(control: method.paramsSchema),
             annotations: .init(readOnlyHint: readOnly.contains(method) ? true : nil))
    } + [SessionMode.tool]

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

    func call(_ name: String, arguments: [String: Value]?, meta: Metadata? = nil) async -> CallTool.Result {
        if name == SessionMode.toolName {
            do {
                return Self.success(try await setSessionMode(JSONValue(mcp: .object(arguments ?? [:]))))
            } catch {
                return Self.failure(ControlError(error).rpcError)
            }
        }
        guard let method = Self.methodsByTool[name] else {
            return Self.failure(ControlError.methodNotFound(name).rpcError)
        }
        let params = arguments.map { JSONValue(mcp: Value.object($0)) }
        // CTL-031: progress goes out in order, and all of it before the result.
        let (updates, progress) = AsyncStream<ControlProgress>.makeStream()
        let sender: Task<Void, Never>? = meta?.progressToken.flatMap { token in
            sendProgress.map { send in
                Task {
                    for await update in updates {
                        await send(.init(progressToken: token, progress: update.progress, total: 1,
                                         message: update.message ?? update.method))
                    }
                }
            }
        }
        var report: (@Sendable (ControlProgress) -> Void)?
        if sender != nil { report = { @Sendable update in progress.yield(update) } }
        let result: JSONValue
        do {
            if let attached {
                result = try await attached.client.call(method, params, progress: report)
            } else {
                var handler: ControlProgressHandler?
                if let report { handler = { report($0) } }
                result = try await dispatcher.call(method, params, progress: handler)
            }
        } catch {
            progress.finish()
            await sender?.value
            return Self.failure(error.rpcError)
        }
        progress.finish()
        await sender?.value
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

    // MARK: daw_session_mode (CTL-023)

    /// Switches mode. Attach builds this checkout's app if it is stale (unless `build: false`),
    /// launches it with `--control-socket` (or reuses one already listening there) and routes every
    /// other tool to it; headless stops the app this session launched.
    func setSessionMode(_ params: JSONValue) async throws -> JSONValue {
        let p = try params.decode(SessionMode.Params.self)
        switch p.mode {
        case .headless:
            shutdown()
        case .attach:
            if let attached, attached.client.isConnected {
                return try sessionState(note: "already attached")
            }
            shutdown()
            guard let root = attachSetup.checkoutRoot else {
                throw ControlError.attachFailed("dawmcp isn't running from a checkout, so there is no app to launch")
            }
            let socket = attachSetup.socketPath(root)
            if p.build ?? true, !ControlSocketClient.isListening(at: socket), AppLauncher.needsBuild(checkoutRoot: root) {
                try await AppLauncher.buildApp(checkoutRoot: root, log: root.appending(path: ".build/attach/xcodebuild.log"))
            }
            attached = try await AppLauncher.attach(
                attachSetup.target(root), socketPath: socket, engine: p.engine ?? .fake,
                log: root.appending(path: ".build/attach/app.log"), timeout: attachSetup.launchTimeout)
        }
        return try sessionState(note: nil)
    }

    private func sessionState(note: String?) throws -> JSONValue {
        var state: [String: JSONValue] = ["mode": .string(attached == nil ? "headless" : "attach")]
        if let attached {
            state["socketPath"] = .string(attached.socketPath)
            state["launched"] = .bool(attached.launched)
            if let pid = attached.pid { state["pid"] = .int(Int64(pid)) }
        }
        if let note { state["note"] = .string(note) }
        return .object(state)
    }

    /// Ends attach mode: closes the connection and stops the app if this session launched it.
    func shutdown() {
        attached?.terminate()
        attached = nil
    }

    private nonisolated static func success(_ result: JSONValue) -> CallTool.Result {
        CallTool.Result(content: [.text(text: result.jsonString(), annotations: nil, _meta: nil)])
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
