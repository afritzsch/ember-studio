import DAWControl
import Foundation
import MCP

/// CTL-023: the `daw_session_mode` tool's name, schema and params.
enum SessionMode {
    static let toolName = "daw_session_mode"

    enum Mode: String, Codable, CaseIterable {
        case headless
        case attach
    }

    struct Params: Codable {
        var mode: Mode
        /// Attach only: the app's engine when it is launched (default `fake`).
        var engine: EngineChoice?
        /// Attach only: rebuild the app with xcodebuild first when it is missing or stale (default true).
        var build: Bool?
    }

    static let tool = Tool(
        name: toolName,
        description: """
            Switch between headless (in-process model + offline engine, the default) and attach mode, where every \
            daw_* tool drives this worktree's running Ember Studio app over its control socket (CTL-023). Attach \
            builds the app if it is stale (build: false skips that; a first build takes minutes), launches \
            .build/xcode/Build/Products/Debug/Ember Studio.app with --control-socket \
            $TMPDIR/emberstudio-<hash of the worktree>.sock (or reuses an app already listening there) and stops \
            it again when the session ends or mode goes back to headless. daw_ui_state, daw_ui_perform and \
            daw_ui_snapshot need attach mode. engine: fake (realtime on the fake device, default), coreAudio \
            (the real device) or offline.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "mode": ["type": "string", "enum": .array(Mode.allCases.map { .string($0.rawValue) })],
                "engine": ["type": "string", "enum": .array(EngineChoice.allCases.map { .string($0.rawValue) })],
                "build": ["type": "boolean"],
            ],
            "required": ["mode"],
            "additionalProperties": false,
        ])
}

/// Where attach mode finds the app and its socket. The default is the checkout dawmcp was built in;
/// tests point it elsewhere.
struct AttachSetup: Sendable {
    var checkoutRoot: URL?
    var target: @Sendable (URL) -> AppLauncher.Target
    var socketPath: @Sendable (URL) -> String
    var launchTimeout: Duration

    static func currentCheckout() -> AttachSetup {
        AttachSetup(checkoutRoot: ControlSocketPath.currentCheckoutRoot(), target: { .app(checkoutRoot: $0) },
                    socketPath: { ControlSocketPath.forCheckout($0) }, launchTimeout: .seconds(60))
    }
}
