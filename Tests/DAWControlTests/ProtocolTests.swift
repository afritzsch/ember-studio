import DAWControl
import DAWModel
import Foundation
import Testing

@Suite("Control protocol (CTL-001, CTL-003)")
@MainActor
struct ProtocolTests {
    @Test("CTL-001: JSONValue round-trips JSON, keeping 2^56-range integers exact")
    func jsonValueRoundTrip() throws {
        let text = #"{"a":[1,2.5,"x",true,null],"big":72057594037927935,"nested":{"k":-3}}"#
        let value = try JSONValue(parsing: Data(text.utf8))
        #expect(value["big"] == .int(72_057_594_037_927_935))
        #expect(value["a"]?[1] == .double(2.5))
        #expect(value["a"]?[3] == .bool(true))
        #expect(value.jsonString() == text, "sorted keys, compact")
    }

    @Test("CTL-001: JSON Pointer (RFC 6901) lookup for project.get")
    func jsonPointer() throws {
        let value: JSONValue = ["tracks": [["name": "Drums"]], "a/b": 1, "m~n": 2]
        #expect(value.resolve(pointer: "") == value)
        #expect(value.resolve(pointer: "/tracks/0/name") == "Drums")
        #expect(value.resolve(pointer: "/a~1b") == 1)
        #expect(value.resolve(pointer: "/m~0n") == 2)
        #expect(value.resolve(pointer: "/tracks/1") == nil)
        #expect(value.resolve(pointer: "tracks") == nil)
    }

    @Test("CTL-001: requests and responses round-trip through Codable; responses always carry id and one of result/error")
    func messageRoundTrip() throws {
        let request = RPCRequest(id: .string("abc"), method: "project.new", params: ["name": "x"])
        let decoded = try JSONDecoder().decode(RPCRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)

        let ok = RPCResponse(id: .int(7), result: .null)
        #expect(ok.line() == #"{"id":7,"jsonrpc":"2.0","result":null}"#)
        #expect(try JSONDecoder().decode(RPCResponse.self, from: Data(ok.line().utf8)) == ok)

        let failure = RPCResponse(id: nil, error: ControlError.noProject.rpcError)
        let back = try JSONDecoder().decode(RPCResponse.self, from: Data(failure.line().utf8))
        #expect(back == failure && back.result == nil && back.error?.dawError == "noProject")
        #expect(failure.line().contains(#""id":null"#))
    }

    @Test("CTL-001: newline-delimited JSON in, one line out, id echoed (number or string)")
    func handleLine() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        let line = try #require(await dispatcher.handle(line: #"{"jsonrpc":"2.0","id":"r1","method":"project.new","params":{"name":"p"}}"#))
        #expect(!line.contains("\n"))
        let response = try JSONDecoder().decode(RPCResponse.self, from: Data(line.utf8))
        #expect(response.id == .string("r1"))
        #expect(response.result?["projectID"] == "00000000-0000-0000-0000-000000000001")
    }

    @Test("CTL-001: notifications (no id) run but get no response")
    func notifications() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        #expect(await dispatcher.handle(line: #"{"jsonrpc":"2.0","method":"project.new","params":{"name":"p"}}"#) == nil)
        #expect(dispatcher.store?.project.name == "p")
    }

    @Test("CTL-001, CTL-003: unreadable lines get parseError / invalidRequest with standard codes")
    func malformed() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        func error(_ line: String) async throws -> RPCResponse {
            try JSONDecoder().decode(RPCResponse.self, from: Data(try #require(await dispatcher.handle(line: line)).utf8))
        }
        let notJSON = try await error("{nope")
        #expect(notJSON.error?.code == -32700 && notJSON.error?.dawError == "parseError" && notJSON.id == nil)
        let noVersion = try await error(#"{"id":1,"method":"undo"}"#)
        #expect(noVersion.error?.code == -32600 && noVersion.id == .int(1))
        let noMethod = try await error(#"{"jsonrpc":"2.0","id":2}"#)
        #expect(noMethod.error?.code == -32600)
        let positional = try await error(#"{"jsonrpc":"2.0","id":3,"method":"project.new","params":["x"]}"#)
        #expect(positional.error?.code == -32602 && positional.error?.dawError == "invalidParams")
        let unknown = try await error(#"{"jsonrpc":"2.0","id":4,"method":"nope.nope"}"#)
        #expect(unknown.error?.code == -32601 && unknown.error?.dawError == "methodNotFound")
        let missing = try await error(#"{"jsonrpc":"2.0","id":5,"method":"project.new","params":{}}"#)
        #expect(missing.error?.code == -32602 && missing.error?.data?["detail"] == "missing name")
        let empty = try await error("[]")
        #expect(empty.error?.code == -32600)
    }

    @Test("CTL-001: a JSON array is a JSON-RPC batch; notifications in it get no entry")
    func batch() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        let line = try #require(await dispatcher.handle(line: """
            [{"jsonrpc":"2.0","id":1,"method":"project.new","params":{"name":"a"}},
             {"jsonrpc":"2.0","method":"transport.play"},
             {"jsonrpc":"2.0","id":2,"method":"project.get","params":{"path":"/name"}}]
            """.replacingOccurrences(of: "\n", with: "")))
        let responses = try JSONDecoder().decode([RPCResponse].self, from: Data(line.utf8))
        #expect(responses.map(\.id) == [.int(1), .int(2)])
        #expect(responses[1].result == "a")
    }

    @Test("CTL-003: model errors carry data {dawError, detail, error}; a cycle adds its path")
    func errorData() throws {
        let cycle = ControlError.model(.routingCycle(path: [3, 4, 3])).rpcError
        #expect(cycle.code == -32000)
        #expect(cycle.dawError == "routingCycle")
        #expect(cycle.data?["path"] == [3, 4, 3])
        #expect(cycle.data?["detail"] == "routing cycle: 3 → 4 → 3")
        let roundTrip = try #require(cycle.data?["error"]).decode(DAWError.self)
        #expect(roundTrip == .routingCycle(path: [3, 4, 3]))

        let annotated = ControlError.withData(.model(.notFound(kind: "track", id: 9)), ["index": 2]).rpcError
        #expect(annotated.code == -32000 && annotated.dawError == "notFound" && annotated.data?["index"] == 2)
        #expect(ControlError.timeout("x").rpcError.code == -32003)
    }

    @Test("CTL-003: DW-095 maps an engine-side cycle's NodeIDs back to model IDs")
    func engineCycleOwners() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "c"])
        let track = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "t", "kind": "audio"]])["createdIDs"]?[0]?.int64Value)
        // The next structural change is rejected by the engine with role-tagged NodeIDs.
        let bus: NodeIDValue = 40
        box.last.rejectNextGraph(with: .routingCycle(path: [GraphNodeID.input(of: bus), bus, UInt64(track), GraphNodeID.input(of: bus)]))
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "u", "kind": "audio"]])
        let error = try #require(await dispatcher.failure(.renderOffline, ["from": 0, "to": 960, "path": "x.wav"]))
        #expect(error.dawError == "routingCycle")
        #expect(error.data?["path"] == [40, .int(track), 40])
    }
}

@Suite("ControlScript (CTL-010)")
struct ControlScriptTests {
    @Test("CTL-010: scripts take JSON lines or `method {params}` shorthand; comments and blanks are skipped; ids default to line numbers")
    func parse() throws {
        let script = try ControlScript(parsing: """
            # build
            project.new {"name": "a"}

            // comment
            {"method": "undo"}
            {"jsonrpc": "2.0", "id": "x", "method": "redo", "params": {}}
            transport.play
            """)
        #expect(script.lines.map(\.number) == [2, 5, 6, 7])
        #expect(script.lines.map(\.request.method) == ["project.new", "undo", "redo", "transport.play"])
        #expect(script.lines.map(\.request.id) == [.int(2), .int(5), .string("x"), .int(7)])
        #expect(script.lines[0].request.params?["name"] == "a")
    }

    @Test("CTL-010: a bad line is reported with its number")
    func badLine() {
        #expect(throws: ControlError.invalidRequest("line 2: not JSON")) {
            try ControlScript(parsing: "undo\n{oops\n")
        }
        #expect(throws: ControlError.invalidRequest("line 1: params of project.new are not JSON")) {
            try ControlScript(parsing: "project.new {name}")
        }
    }
}
