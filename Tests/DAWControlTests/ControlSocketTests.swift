import DAWControl
import DAWModel
import Darwin
import Foundation
import Testing

// CTL-030 / CTL-032 / CTL-011: the app's control socket and the attach-mode client, against a
// headless dispatcher on FakeEngine (the app's dispatcher is the same type in attach mode).

/// A socket path under $TMPDIR, unique per test (CONV §9), short enough for `sun_path`.
private func socketPath() -> String {
    ControlSocketPath.forProcess(Int32.random(in: 1_000_000...Int32.max))
}

@MainActor
private func server(at path: String) throws -> (ControlSocketServer, Dispatcher) {
    let (dispatcher, _) = TestDispatchers.fake()
    let server = ControlSocketServer(path: path, dispatcher: dispatcher)
    try server.start()
    return (server, dispatcher)
}

private func mode(_ path: String) -> mode_t {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode : 0
}

@Suite("Control socket (CTL-030, CTL-032, CTL-011)")
@MainActor
struct ControlSocketTests {
    @Test("CTL-030: the socket file is created 0600 and stop() removes it")
    func permissions() throws {
        let path = socketPath()
        let (server, _) = try server(at: path)
        #expect(server.isListening)
        #expect(mode(path) & S_IFMT == S_IFSOCK)
        #expect(mode(path) & 0o777 == 0o600, "owner read/write only")
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!server.isListening)
    }

    @Test("CTL-030/CTL-011: a request round-trips over the socket; app errors arrive unchanged as `remote`")
    func roundTrip() async throws {
        let path = socketPath()
        let (server, dispatcher) = try server(at: path)
        defer { server.stop() }
        let client = try await ControlSocketClient.connect(path: path, timeout: .seconds(5))
        defer { client.close() }
        let result = try await client.call(.projectNew, ["name": "socket"])
        #expect(result["projectID"] == "00000000-0000-0000-0000-000000000001")
        #expect(dispatcher.store?.project.name == "socket", "the request ran on the server's dispatcher")
        _ = try await client.call(.commandApply, ["command": ["type": "AddTrack", "name": "T", "kind": "audio"]])
        #expect(try await client.call(.projectGet, ["path": "/tracks/0/name"]) == "T")

        do {
            _ = try await client.call("no.such")
            Issue.record("an unknown method succeeded")
        } catch {
            guard case .remote(let rpc) = error else { throw error }
            #expect(rpc.code == -32601 && rpc.dawError == "methodNotFound")
            #expect(error.rpcError == rpc, "passed on unchanged")
        }
    }

    @Test("CTL-030: two clients are served on one socket, each getting its own responses")
    func twoClients() async throws {
        let path = socketPath()
        let (server, _) = try server(at: path)
        defer { server.stop() }
        let a = try await ControlSocketClient.connect(path: path, timeout: .seconds(5))
        let b = try await ControlSocketClient.connect(path: path, timeout: .seconds(5))
        defer {
            a.close()
            b.close()
        }
        _ = try await a.call(.projectNew, ["name": "shared"])
        async let fromA = a.call(.commandApply, ["command": ["type": "AddTrack", "name": "A", "kind": "audio"]])
        async let fromB = b.call(.commandApply, ["command": ["type": "AddTrack", "name": "B", "kind": "audio"]])
        let (ra, rb) = try await (fromA, fromB)
        #expect(ra["createdIDs"] != rb["createdIDs"], "each client got its own result")
        let names = try await b.call(.projectGet, ["path": "/tracks"]).arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(Set(names ?? []) == ["A", "B"])
        // A connection that closes doesn't disturb the other one.
        a.close()
        #expect(try await b.call(.projectGet, ["path": "/name"]) == "shared")
    }

    @Test("CTL-032: a stale socket file (nobody listening) is unlinked on start")
    func staleSocket() async throws {
        let path = socketPath()
        // A socket bound and then abandoned, like one left by a crashed app.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
            raw[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        #expect(bound == 0)
        #expect(mode(path) & S_IFMT == S_IFSOCK && !ControlSocketClient.isListening(at: path))

        let (server, _) = try server(at: path)
        defer { server.stop() }
        let client = try ControlSocketClient(path: path)
        defer { client.close() }
        #expect(try await client.call(.projectNew, ["name": "fresh"])["projectID"] != nil)
    }

    @Test("CTL-032: a socket another server still answers on, or a path that isn't a socket, is refused")
    func liveSocketRefused() throws {
        let path = socketPath()
        let (first, _) = try server(at: path)
        defer { first.stop() }
        let (dispatcher, _) = TestDispatchers.fake()
        let second = ControlSocketServer(path: path, dispatcher: dispatcher)
        #expect(throws: ControlError.self) { try second.start() }
        #expect(ControlSocketClient.isListening(at: path), "the first server is untouched")
        second.stop()
        #expect(FileManager.default.fileExists(atPath: path), "stop() leaves a socket it didn't create")

        let file = socketPath()
        FileManager.default.createFile(atPath: file, contents: Data("keep".utf8))
        defer { unlink(file) }
        let third = ControlSocketServer(path: file, dispatcher: dispatcher)
        do {
            try third.start()
            Issue.record("bound over a regular file")
        } catch {
            #expect(error.name == "attachFailed" && error.detail.contains("isn't a socket"))
        }
        #expect(FileManager.default.contents(atPath: file) == Data("keep".utf8))
    }

    @Test("CTL-011: connecting where nothing listens is attachFailed (-32004); connect(timeout:) waits for a late server")
    func clientErrors() async throws {
        let path = socketPath()
        do {
            _ = try ControlSocketClient(path: path)
            Issue.record("connected to nothing")
        } catch {
            #expect(error.code == -32004 && error.name == "attachFailed")
        }
        do {
            _ = try await ControlSocketClient.connect(path: path, timeout: .milliseconds(200))
            Issue.record("connected to nothing")
        } catch {
            #expect(error.name == "attachFailed" && error.detail.contains("within"))
        }
        do {
            _ = try await ControlSocketClient.connect(path: path, timeout: .seconds(5), alive: { false })
            Issue.record("connected to nothing")
        } catch {
            #expect(error.detail.contains("exited"))
        }

        // The server starts while the client is already retrying.
        let (dispatcher, _) = TestDispatchers.fake()
        let server = ControlSocketServer(path: path, dispatcher: dispatcher)
        defer { server.stop() }
        async let late = ControlSocketClient.connect(path: path, timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(150))
        try server.start()
        let client = try await late
        #expect(try await client.call(.projectNew, ["name": "late"])["projectID"] != nil)

        // The server goes away: the next call is attachFailed, not a hang.
        server.stop()
        do {
            _ = try await client.call(.projectGet)
            Issue.record("a call on a closed connection succeeded")
        } catch {
            #expect(error.name == "attachFailed")
        }
        client.close()
    }

    @Test("CTL-001 over the socket: a notification gets no response and runs before the next request")
    func wireDetails() async throws {
        let path = socketPath()
        let (server, dispatcher) = try server(at: path)
        defer { server.stop() }
        let client = try ControlSocketClient(path: path)
        defer { client.close() }
        #expect(try await client.send(RPCRequest(id: nil, method: "project.new", params: ["name": "n"])) == nil)
        // The notification ran before the next request (one connection is served in order).
        let response = try await client.send(RPCRequest(7, .projectGet, ["path": "/name"]))
        #expect(response?.id == .int(7) && response?.result == "n")
        #expect(dispatcher.store != nil)
    }

    @Test("CTL-032: per-process and per-checkout socket paths; too-long paths fall back to /tmp")
    func paths() throws {
        let tmp = "/var/folders/xy/abc/T/"
        #expect(ControlSocketPath.forProcess(4242, temporaryDirectory: tmp) == "/var/folders/xy/abc/T/emberstudio-4242.sock")
        let a = ControlSocketPath.forCheckout(URL(fileURLWithPath: "/Users/me/wt/a"), temporaryDirectory: tmp)
        let b = ControlSocketPath.forCheckout(URL(fileURLWithPath: "/Users/me/wt/b"), temporaryDirectory: tmp)
        let a2 = ControlSocketPath.forCheckout(URL(fileURLWithPath: "/Users/me/wt/a/"), temporaryDirectory: tmp)
        #expect(a != b, "two worktrees never share a socket")
        #expect(a == a2, "stable for the same checkout")
        #expect(a.hasPrefix(tmp + "emberstudio-") && a.hasSuffix(".sock"))
        #expect(a.utf8.count <= ControlSocketPath.maxLength)

        let long = "/" + String(repeating: "d", count: 120) + "/"
        let fallback = ControlSocketPath.forCheckout(URL(fileURLWithPath: "/Users/me/wt/a"), temporaryDirectory: long)
        #expect(fallback.hasPrefix("/tmp/emberstudio-") && fallback.utf8.count <= ControlSocketPath.maxLength)
        #expect(fallback.hasSuffix(String(a.split(separator: "/").last!)), "same name, other folder")
        #expect(ControlSocketPath.forProcess(1, temporaryDirectory: long) == "/tmp/emberstudio-1.sock")

        let dir = try TempDir()
        let nested = dir.file("x/y")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.file("Package.swift").path, contents: Data())
        #expect(ControlSocketPath.checkoutRoot(containing: nested)?.path == dir.url.resolvingSymlinksInPath().path)
        #expect(ControlSocketPath.checkoutRoot(containing: URL(fileURLWithPath: "/usr/bin")) == nil)
    }
}
