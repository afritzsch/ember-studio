import DAWControl
import Foundation
import MCP
import System

// CTL-020: the control protocol as an MCP server over stdio, headless (in-process model + offline
// engine, like dawctl) by default; `daw_session_mode` switches to attach mode, which drives this
// checkout's running app over its socket (CTL-023). Launched by scripts/dawmcp.sh through the
// repo's .mcp.json (CTL-025).
//
//   dawmcp [--fixtures <dir>]…
//
// Relative paths in tool arguments resolve against the working directory (the launcher's is the
// worktree root).

@main
struct DawMCP {
    static let usage = """
        usage: dawmcp [--fixtures <dir>]…
        An MCP server on stdin/stdout exposing the Ember Studio control methods as daw_* tools.
        options:
          --fixtures <dir>  also look for daw_test_fixture scripts here (repeatable; $DAWCTL_FIXTURES too)
        Tool calls run one at a time in the order they arrive (daw_render_cancel excepted).
        When this binary is rebuilt while it runs, every tool result adds the warning
        "stale: dawmcp binary rebuilt since launch; restart the MCP server"; it keeps running the
        old build (and the session's project) until the client restarts it.
        plugins.* (daw_plugins_*) use PluginScanner next to this binary and the scan cache
        <checkout>/.build/plugins/plugins.json ($DAWCTL_PLUGIN_CACHE, $DAWCTL_VST3_DIRS, $DAWCTL_AU=0).
        """

    @MainActor
    static func main() async {
        var extraFixtures: [URL] = []
        var arguments = CommandLine.arguments.dropFirst()
        while let argument = arguments.popFirst() {
            switch argument {
            case "--fixtures":
                guard let value = arguments.popFirst() else { fail("--fixtures needs a folder\n\(usage)") }
                extraFixtures.append(URL(fileURLWithPath: value, isDirectory: true))
            case "-h", "--help":
                FileHandle.standardError.write(Data((usage + "\n").utf8))
                exit(0)
            default:
                fail("unknown argument \(argument)\n\(usage)")
            }
        }

        // stdout carries only MCP messages. The transport gets its own copy of it, and fd 1 becomes
        // stderr, so a stray print (or engine output) can't corrupt the stream.
        let protocolOut = dup(STDOUT_FILENO)
        guard protocolOut >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { fail("cannot set up stdout") }

        let dispatcher = Dispatcher(configuration: .init(
            fixtureDirectories: extraFixtures + ControlFixtures.defaultDirectories()))
        let tools = DawTools(dispatcher: dispatcher)
        // DW-147/151 (T-098): results say when this binary was rebuilt after launch.
        let watch = StaleBinaryWatch()
        tools.staleCheck = { watch.check() }
        let server = Server(name: "dawmcp", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: DawTools.tools) }
        // CTL-031 / DW-133: progress of long calls as MCP notifications/progress.
        tools.sendProgress = { [weak server] progress in
            try? await server?.notify(ProgressNotification.message(progress))
        }
        // DW-163 (T-098): tools/call runs in arrival order; stdin passes through a tagger that numbers
        // the calls before the SDK, which handles each request in a task of its own, sees them.
        let sequencer = CallSequencer()
        let stdinPipe = Pipe()
        CallOrderTagger(sequencer: sequencer, input: .standardInput, output: stdinPipe.fileHandleForWriting).start()
        await server.withMethodHandler(CallTool.self) { params in
            let seq = params._meta?[CallOrder.metaKey]?.intValue
            if let seq { await sequencer.waitTurn(seq) }
            defer { if let seq { sequencer.finish(seq) } }
            return await tools.call(params.name, arguments: params.arguments, meta: params._meta)
        }
        do {
            let transport = StdioTransport(
                input: FileDescriptor(rawValue: stdinPipe.fileHandleForReading.fileDescriptor),
                output: FileDescriptor(rawValue: protocolOut))
            try await server.start(transport: transport)
        } catch {
            fail("cannot start the MCP server: \(error)")
        }
        // Until the client closes stdin. CTL-023: then the app attach mode launched is stopped too
        // (should dawmcp be killed instead, the app's --parent-pid watch ends it).
        await server.waitUntilCompleted()
        tools.shutdown()
        await server.stop()
        exit(0)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("dawmcp: \(message)\n".utf8))
        exit(2)
    }
}
