import DAWControl
import Darwin
import Foundation
import MCP
import Testing

@testable import dawmcp

// CTL-023 / CTL-031 (DW-133): daw_session_mode and progress notifications. Attach mode runs against
// `dawctl serve` (the same ControlSocketServer + Dispatcher the app serves) copied to a path with
// spaces (DW-046), launched by the same AppLauncher that launches the app.

private final class BundleMarker {}

/// A fake checkout whose "app" is a dawctl copy at "<root>/Ember Studio stand-in/Ember Studio".
private func standInSetup(root: URL) throws -> AttachSetup {
    let dawctl = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "dawctl")
    try #require(FileManager.default.isExecutableFile(atPath: dawctl.path), "swift test builds dawctl")
    let folder = root.appending(path: "Ember Studio stand-in")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appending(path: "Ember Studio")
    try FileManager.default.copyItem(at: dawctl, to: copy)
    return AttachSetup(checkoutRoot: root, target: { _ in AppLauncher.Target(executable: copy, leadingArguments: ["serve"]) },
                       socketPath: { ControlSocketPath.forCheckout($0) }, launchTimeout: .seconds(30))
}

private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProgressNotification.Parameters] = []
    func add(_ item: ProgressNotification.Parameters) { lock.withLock { items.append(item) } }
    var values: [ProgressNotification.Parameters] { lock.withLock { items } }
}

@MainActor
@Suite("dawmcp session mode and progress (CTL-023, CTL-031)", .serialized)
struct SessionModeTests {
    @Test("CTL-023: attach launches the checkout's app, routes every tool to it, and headless stops it again")
    func attachAndBack() async throws {
        let dir = try TempDir()
        let tools = DawTools(dispatcher: Dispatcher(), attachSetup: try standInSetup(root: dir.url))
        defer { tools.shutdown() }
        let state = try await tools.ok("daw_session_mode", ["mode": "attach", "build": false, "engine": "offline"])
        #expect(state["mode"] == "attach" && state["launched"] == true)
        #expect(state["socketPath"]?.stringValue == ControlSocketPath.forCheckout(dir.url))
        let pid = try #require(state["pid"]?.int64Value).int32

        _ = try await tools.ok("daw_project_new", ["name": "in the app"])
        #expect(tools.dispatcher.store == nil, "the call went to the app, not the in-process dispatcher")
        #expect(try await tools.ok("daw_project_get", ["path": "/name"]) == "in the app")
        // Errors from the app arrive as they would in-process (CTL-003).
        let bad = try await tools.failure("daw_command_apply", ["command": ["type": "Nope"]])
        #expect(bad["data"]?["dawError"] == "unknownCommandType")
        let again = try await tools.ok("daw_session_mode", ["mode": "attach", "build": false])
        #expect(again["note"] == "already attached" && again["pid"]?.int64Value == Int64(pid))

        let back = try await tools.ok("daw_session_mode", ["mode": "headless"])
        #expect(back == ["mode": "headless"])
        #expect(!isAlive(pid) || waitpid(pid, nil, WNOHANG) == pid, "the launched app was stopped")
        #expect(!FileManager.default.fileExists(atPath: ControlSocketPath.forCheckout(dir.url)))
        let none = try await tools.failure("daw_project_get")
        #expect(none["data"]?["dawError"] == "noProject", "back on the fresh in-process dispatcher")
    }

    @Test("CTL-023: two checkouts attach at the same time without interfering")
    func twoCheckouts() async throws {
        let (dirA, dirB) = (try TempDir(), try TempDir())
        let a = DawTools(dispatcher: Dispatcher(), attachSetup: try standInSetup(root: dirA.url))
        let b = DawTools(dispatcher: Dispatcher(), attachSetup: try standInSetup(root: dirB.url))
        defer {
            a.shutdown()
            b.shutdown()
        }
        async let stateA = a.ok("daw_session_mode", ["mode": "attach", "build": false, "engine": "offline"])
        async let stateB = b.ok("daw_session_mode", ["mode": "attach", "build": false, "engine": "offline"])
        let (sa, sb) = try await (stateA, stateB)
        #expect(sa["socketPath"] != sb["socketPath"] && sa["pid"] != sb["pid"])
        _ = try await a.ok("daw_project_new", ["name": "A"])
        _ = try await b.ok("daw_project_new", ["name": "B"])
        _ = try await a.ok("daw_command_apply", ["command": ["type": "AddTrack", "name": "only in A", "kind": "audio"]])
        #expect(try await a.ok("daw_project_get", ["path": "/name"]) == "A")
        #expect(try await b.ok("daw_project_get", ["path": "/name"]) == "B")
        #expect(try await b.ok("daw_project_get", ["path": "/tracks"]) == [])

        a.shutdown()
        let pidB = try #require(sb["pid"]?.int64Value).int32
        #expect(isAlive(pidB), "stopping A's app leaves B's running")
        #expect(try await b.ok("daw_project_get", ["path": "/name"]) == "B")
    }

    @Test("CTL-023: attach without a checkout, or with bad params, fails cleanly and stays headless")
    func attachFailures() async throws {
        var setup = AttachSetup.currentCheckout()
        setup.checkoutRoot = nil
        let tools = DawTools(dispatcher: Dispatcher(), attachSetup: setup)
        let noRoot = try await tools.failure("daw_session_mode", ["mode": "attach"])
        #expect(noRoot["code"] == -32004 && noRoot["data"]?["dawError"] == "attachFailed")
        #expect(try await tools.failure("daw_session_mode", ["mode": "sideways"])["code"] == -32602)
        #expect(try await tools.failure("daw_session_mode", ["mode": "attach", "engine": "warp"])["code"] == -32602)

        let dir = try TempDir()
        var missing = try standInSetup(root: dir.url)
        missing.target = { AppLauncher.Target(executable: $0.appending(path: "Nope.app/Contents/MacOS/Nope")) }
        let noApp = DawTools(dispatcher: Dispatcher(), attachSetup: missing)
        let failed = try await noApp.failure("daw_session_mode", ["mode": "attach", "build": false])
        #expect(failed["data"]?["dawError"] == "attachFailed")
        #expect(noApp.attached == nil)
        _ = try await noApp.ok("daw_project_new", ["name": "still headless"])
    }

    @Test("CTL-031, DW-133: with a progressToken, a render sends notifications/progress (rising, ending at 1, before the result); without one, none")
    func progressNotifications() async throws {
        let dir = try TempDir()
        let log = ProgressLog()
        let tools = DawTools(dispatcher: Dispatcher(configuration: .init(workingDirectory: dir.url)),
                             attachSetup: try standInSetup(root: dir.url))
        defer { tools.shutdown() }
        tools.sendProgress = { log.add($0) }
        let render: [String: Value] = ["from": 0, "to": 96_000, "path": .string(dir.file("p.wav").path)]

        for mode in ["headless", "attach"] {
            _ = try await tools.ok("daw_session_mode", ["mode": .string(mode), "build": false, "engine": "offline"])
            _ = try await tools.ok("daw_project_new", ["name": .string(mode)])
            let before = log.values.count
            let result = await tools.call("daw_render_offline", arguments: render, meta: Metadata(progressToken: .string(mode)))
            #expect(result.isError != true, "\(result.texts)")
            let updates = log.values.dropFirst(before)
            #expect(!updates.isEmpty && updates.allSatisfy { $0.progressToken == .string(mode) }, "\(mode)")
            #expect(updates.last?.progress == 1 && updates.allSatisfy { $0.total == 1 }, "\(mode)")
            let values = updates.map(\.progress)
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "\(mode): \(values)")
            #expect(updates.first?.message == "render.offline")

            let quiet = log.values.count
            _ = try await tools.ok("daw_render_offline", render)
            #expect(log.values.count == quiet, "\(mode): no token, no notifications")
        }
    }
}

private extension Int64 {
    var int32: Int32 { Int32(truncatingIfNeeded: self) }
}
