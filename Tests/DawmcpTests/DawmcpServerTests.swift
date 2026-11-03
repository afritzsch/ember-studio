import DAWControl
import Foundation
import MCP
import System
import Testing

// CTL-020: the dawmcp binary as an MCP client sees it: launched as a child process, spoken to over
// stdio by the SDK's own Client. The test target depends on dawmcp, so `swift test` builds it next
// to the test bundle.

private final class BundleMarker {}

@Suite("dawmcp server (CTL-020)")
struct DawmcpServerTests {
    @Test("CTL-020: an MCP client connects over stdio, lists the tools and calls them; stdout stays protocol-only")
    func stdioSession() async throws {
        let dir = try TempDir()
        let process = Process()
        process.executableURL = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "dawmcp")
        // Relative paths in tool arguments resolve against the server's working directory.
        process.currentDirectoryURL = dir.url
        let toServer = Pipe()
        let fromServer = Pipe()
        let stderr = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = stderr
        try process.run()

        let client = Client(name: "DawmcpServerTests", version: "1")
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor))
        let initialized = try await client.connect(transport: transport)
        #expect(initialized.serverInfo.name == "dawmcp")
        #expect(initialized.capabilities.tools != nil)

        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name) == DawToolsNames.all)

        func call(_ name: String, _ arguments: [String: Value] = [:]) async throws -> (JSONValue, Bool) {
            let (content, isError) = try await client.callTool(name: name, arguments: arguments)
            guard case .text(let text, _, _) = try #require(content.first) else { throw CancellationError() }
            return (try JSONValue(parsing: Data(text.utf8)), isError ?? false)
        }
        let (project, _) = try await call("daw_project_new", ["name": "stdio"])
        #expect(project == ["projectID": "00000000-0000-0000-0000-000000000001"])
        let (track, _) = try await call("daw_command_apply", ["command": ["type": "AddTrack", "name": "T", "kind": "audio"]])
        #expect(track["createdIDs"] == [2])
        let (render, renderFailed) = try await call("daw_render_offline", ["from": 0, "to": 960, "path": "out/a.wav"])
        // $TMPDIR is a symlink (/var → /private/var); the server reports its resolved cwd.
        #expect(!renderFailed && render["path"]?.stringValue.map(URL.init(fileURLWithPath:))?.resolvingSymlinksInPath()
            == dir.file("out/a.wav").resolvingSymlinksInPath())
        #expect(FileManager.default.fileExists(atPath: dir.file("out/a.wav").path))
        let (analysis, _) = try await call("daw_audio_analyze", ["path": "out/a.wav"])
        #expect(analysis["firstNonSilentSample"] == -1)
        let (telemetry, _) = try await call("daw_engine_telemetry")
        #expect(telemetry["rtViolations"] == 0)
        // CTL-031, DW-133: a call with a progressToken gets notifications/progress over stdio.
        let progress = ProgressBox()
        await client.onNotification(ProgressNotification.self) { message in progress.add(message.params) }
        let (_, progressFailed) = try await client.callTool(
            name: "daw_render_offline", arguments: ["from": 0, "to": 9600, "path": "out/b.wav"],
            meta: Metadata(progressToken: .string("render-b")))
        #expect(progressFailed != true)
        let deadline = ContinuousClock.now + .seconds(5)
        while progress.values.last?.progress != 1 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(progress.values.last?.progress == 1 && progress.values.allSatisfy { $0.progressToken == .string("render-b") })
        let (error, failed) = try await call("daw_command_apply", ["command": ["type": "Nope"]])
        #expect(failed && error["data"]?["dawError"] == "unknownCommandType")

        // Closing stdin ends the session; the server exits cleanly.
        await client.disconnect()
        try toServer.fileHandleForWriting.close()
        #expect(waitForExit(process) && process.terminationStatus == 0)
        let log = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(!log.contains("rror"), "\(log)")
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProgressNotification.Parameters] = []
    func add(_ item: ProgressNotification.Parameters) { lock.withLock { items.append(item) } }
    var values: [ProgressNotification.Parameters] { lock.withLock { items } }
}

/// The tool names a client should see, in method order, then daw_session_mode (CTL-023).
enum DawToolsNames {
    static var all: [String] {
        ControlMethod.allCases.map { method in
            "daw_" + method.rawValue.replacing(".", with: "_").replacing(/[A-Z]/) { "_" + $0.output.lowercased() }
        } + ["daw_session_mode"]
    }
}
