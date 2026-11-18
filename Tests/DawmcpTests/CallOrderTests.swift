import DAWControl
import Darwin
import Foundation
import MCP
import Testing

@testable import dawmcp

// T-098: dawmcp runs pipelined tools/call requests in arrival order (DW-163) and says when its
// binary was rebuilt after launch (DW-147/151). The binary tests speak raw newline-delimited
// JSON-RPC over stdio, so requests really are pipelined (the SDK client would wait per call).

private final class BundleMarker {}

private func dawmcpBinary() -> URL {
    Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "dawmcp")
}

/// A dawmcp child spoken to with raw JSON lines.
private final class RawSession: @unchecked Sendable {
    let process = Process()
    private let toServer = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [JSONValue] = []

    init(executable: URL = dawmcpBinary(), in directory: URL) throws {
        process.executableURL = executable
        process.currentDirectoryURL = directory
        let fromServer = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice
        fromServer.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // At EOF availableData is empty and the handler fires again at once: without this, it
            // spins a core until the process exits, starving small CI runners (DW-261).
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let self else { return }
            lock.withLock {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let json = try? JSONValue(parsing: Data(line)) { lines.append(json) }
                }
            }
        }
        try process.run()
        send([
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"CallOrderTests","version":"1"}}}"#,
        ])
        _ = response(0)
        send([#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#])
    }

    /// Writes all `messages` in one write: the server has them all before it answers any.
    func send(_ messages: [String]) {
        toServer.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))
    }

    static func call(_ id: Int, _ tool: String, _ arguments: JSONValue = [:]) -> String {
        let request: JSONValue = ["jsonrpc": "2.0", "id": .int(Int64(id)), "method": "tools/call",
                                  "params": ["name": .string(tool), "arguments": arguments]]
        return request.jsonString()
    }

    /// Responses (lines with an id) in the order they arrived.
    var responses: [JSONValue] { lock.withLock { lines.filter { $0["id"] != nil } } }

    func response(_ id: Int, timeout: Duration = .seconds(60)) -> JSONValue? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = responses.first(where: { $0["id"] == .int(Int64(id)) }) { return found }
            usleep(5_000)
        }
        return nil
    }

    func close() {
        try? toServer.fileHandleForWriting.close()
        waitForExit(process)
    }
}

/// The tool result's text items.
private func texts(_ response: JSONValue?) -> [String] {
    response?["result"]?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
}

private func isError(_ response: JSONValue?) -> Bool { response?["result"]?["isError"] == true }

@Suite("dawmcp call order and stale binary (T-098)")
struct CallOrderTests {
    // MARK: DW-163

    @Test("DW-163: pipelined tools/call over stdio run in arrival order: a render sent right behind a fixture and 30 edits sees all of them")
    func pipelinedCallsInOrder() throws {
        let dir = try TempDir()
        let session = try RawSession(in: dir.url)
        defer { session.close() }
        var messages = [RawSession.call(1, "daw_test_fixture", ["name": "pan_law"])]
        for i in 0..<30 {
            messages.append(RawSession.call(2 + i, "daw_command_apply",
                                            ["command": ["type": "AddTrack", "name": .string("T\(i)"), "kind": "midi"]]))
        }
        messages.append(RawSession.call(40, "daw_project_get", ["path": "/tracks/34/name"]))
        messages.append(RawSession.call(41, "daw_render_offline", ["from": 0, "to": 2400, "path": "ordered.wav"]))
        session.send(messages)

        let render = session.response(41)
        #expect(!isError(render), "\(texts(render))")
        #expect(FileManager.default.fileExists(atPath: dir.file("ordered.wav").path))
        let fixture = session.response(1)
        #expect(!isError(fixture), "\(texts(fixture))")
        // pan_law makes 5 tracks; the 30 edits came after it, in order.
        #expect(texts(session.response(40)).first == "\"T29\"")
        // The edits ran in the order they were sent. (Responses may be written slightly out of order:
        // a call's turn passes on when its handler returns, before the SDK writes the response.
        // JSON-RPC matches them by id.)
        session.send([RawSession.call(42, "daw_project_get", ["path": "/tracks"])])
        let tracks = try JSONValue(parsing: Data(try #require(texts(session.response(42)).first).utf8))
        let names = tracks.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(Array(names.suffix(30)) == (0..<30).map { "T\($0)" })
        let answered: Set<Int64> = Set(session.responses.compactMap { $0["id"]?.int64Value })
        let sent: Set<Int64> = Set(Array(1...31) + [40, 41])
        #expect(answered.isSuperset(of: sent))
    }

    @Test("DW-163: the tagger numbers tools/call requests (also in batches and with _meta), never daw_render_cancel, and leaves other lines alone")
    func tagger() throws {
        let sequencer = CallSequencer()
        let tagger = CallOrderTagger(sequencer: sequencer, input: .nullDevice, output: .nullDevice)
        func tag(_ line: String) throws -> JSONValue { try JSONValue(parsing: tagger.tag(Data(line.utf8))) }
        let key = CallOrder.metaKey
        #expect(try tag(RawSession.call(7, "daw_undo"))["params"]?["_meta"]?[key] == 0)
        let meta = try tag(#"{"jsonrpc":"2.0","id":"x","method":"tools/call","params":{"name":"daw_redo","_meta":{"progressToken":"p"}}}"#)
        #expect(meta["params"]?["_meta"] == ["progressToken": "p", key: 1])
        #expect(try tag(RawSession.call(8, "daw_render_cancel"))["params"]?["_meta"] == nil)
        let batch = try tag("[\(RawSession.call(9, "daw_undo")), {\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"ping\"}]")
        #expect(batch[0]?["params"]?["_meta"]?[key] == 2 && batch[1]?["params"] == nil)
        let ping = #"{"jsonrpc":"2.0","id":11,"method":"ping"}"#
        #expect(tagger.tag(Data(ping.utf8)) == Data(ping.utf8))
        #expect(tagger.tag(Data("not json".utf8)) == Data("not json".utf8))
        // A call the SDK would refuse before the handler (arguments not an object) isn't numbered.
        #expect(try tag(#"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"daw_undo","arguments":3}}"#)["params"]?["_meta"] == nil)
    }

    @Test("DW-163: the sequencer runs numbers strictly in order, a cancelled number is released, and one that never starts is skipped")
    func sequencer() async throws {
        // Long enough that a slow runner starting the tasks late doesn't abandon 0, 1, 3 or 5 (DW-261).
        let sequencer = CallSequencer(abandonAfter: .seconds(2))
        let log = Log()
        let seqs = (0..<6).map { sequencer.issue(id: "n:\($0)") }
        await withTaskGroup(of: Void.self) { group in
            for seq in seqs.reversed() where seq != 2 && seq != 4 {
                group.addTask {
                    await sequencer.waitTurn(seq)
                    log.add(seq)
                    try? await Task.sleep(for: .milliseconds(5))
                    sequencer.finish(seq)
                }
            }
            // 2 was cancelled by the client before its handler ran; 4 never reaches the handler.
            sequencer.cancel(id: "n:2")
        }
        #expect(log.values == [0, 1, 3, 5])
    }

    @Test("DW-163: a number that comes up after it was abandoned runs at once instead of waiting forever")
    func lateAfterAbandon() async throws {
        let sequencer = CallSequencer(abandonAfter: .milliseconds(50))
        let late = sequencer.issue(id: "n:0")
        let next = sequencer.issue(id: "n:1")
        try await Task.sleep(for: .milliseconds(100))
        await sequencer.waitTurn(next)  // skips 0: it never started within 50 ms
        sequencer.finish(next)
        await sequencer.waitTurn(late)  // returns: 0's turn has passed
        sequencer.finish(late)
        #expect(sequencer.issue(id: nil) == 2)
    }

    // MARK: DW-147 / DW-151

    @Test("DW-147/151: once the dawmcp binary is newer than the process, every tool result (errors too) carries the stale warning after its JSON; before that, none")
    func staleWarningOverStdio() throws {
        let dir = try TempDir()
        let copy = dir.file("bin/dawmcp")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dawmcpBinary(), to: copy)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: copy.path)
        let session = try RawSession(executable: copy, in: dir.url)
        defer { session.close() }

        session.send([RawSession.call(1, "daw_project_new", ["name": "fresh"])])
        #expect(texts(session.response(1)) == [#"{"projectID":"00000000-0000-0000-0000-000000000001"}"#])

        // "Rebuilt": the file on disk is newer than the running process.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: copy.path)
        session.send([RawSession.call(2, "daw_project_get", ["path": "/name"]), RawSession.call(3, "daw_command_apply", ["command": ["type": "Nope"]])])
        #expect(texts(session.response(2)) == ["\"fresh\"", StaleBinaryWatch.warning])
        let failed = session.response(3)
        #expect(isError(failed) && texts(failed).last == StaleBinaryWatch.warning)
        #expect(StaleBinaryWatch.warning.hasPrefix("stale: dawmcp binary rebuilt since launch; restart the MCP server"))
    }

    @Test("DW-147: StaleBinaryWatch compares the file's date with launch time")
    func staleWatch() throws {
        let dir = try TempDir()
        let file = dir.file("bin")
        try Data().write(to: file)
        let launched = Date()
        try FileManager.default.setAttributes([.modificationDate: launched.addingTimeInterval(-1)], ofItemAtPath: file.path)
        let watch = StaleBinaryWatch(paths: [file.path, dir.file("missing").path], launched: launched)
        #expect(watch.check() == nil)
        try FileManager.default.setAttributes([.modificationDate: launched.addingTimeInterval(1)], ofItemAtPath: file.path)
        #expect(watch.check() == StaleBinaryWatch.warning)
    }

    // MARK: Tools (CTL-021)

    @Test("CTL-021, T-098: daw_plugins_* and daw_engine_param_display are listed with their params; list/blocked/paramDisplay are read-only")
    func newTools() throws {
        let names = Set(DawTools.tools.map(\.name))
        #expect(names.isSuperset(of: ["daw_plugins_scan", "daw_plugins_list", "daw_plugins_blocked", "daw_plugins_retry",
                                      "daw_plugins_unblock", "daw_engine_param_display"]))
        let display = try #require(DawTools.tools.first { $0.name == "daw_engine_param_display" })
        #expect(JSONValue(mcp: display.inputSchema)["required"] == ["node", "param"])
        #expect(display.annotations.readOnlyHint == true)
        #expect(DawTools.tools.first { $0.name == "daw_plugins_scan" }?.annotations.readOnlyHint == nil)
        let retry = try #require(DawTools.tools.first { $0.name == "daw_plugins_retry" })
        #expect(JSONValue(mcp: retry.inputSchema)["properties"]?["timeoutSeconds"] != nil)
    }
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    func add(_ value: Int) { lock.withLock { _values.append(value) } }
    var values: [Int] { lock.withLock { _values } }
}
