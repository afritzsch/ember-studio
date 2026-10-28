import DAWControl
import Foundation
import MCP
import System

// CTL-020: the control protocol as an MCP server over stdio, headless (in-process model + offline
// engine, like dawctl). Launched by scripts/dawmcp.sh through the repo's .mcp.json (CTL-025).
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
        let server = Server(name: "dawmcp", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: DawTools.tools) }
        await server.withMethodHandler(CallTool.self) { params in
            await tools.call(params.name, arguments: params.arguments)
        }
        do {
            let transport = StdioTransport(input: .standardInput, output: FileDescriptor(rawValue: protocolOut))
            try await server.start(transport: transport)
        } catch {
            fail("cannot start the MCP server: \(error)")
        }
        // Until the client closes stdin.
        await server.waitUntilCompleted()
        await server.stop()
        exit(0)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("dawmcp: \(message)\n".utf8))
        exit(2)
    }
}
