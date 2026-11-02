import DAWControl
import Darwin
import Foundation
import Testing

// CTL-011 / CTL-023 / DW-046: attach mode end to end. `dawctl serve` (a headless dispatcher behind
// the same ControlSocketServer the app runs) stands in for the app, launched from a copy at a path
// with spaces, as "Ember Studio.app/Contents/MacOS/Ember Studio" has.

private func dawctlBinary() -> URL {
    Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "dawctl")
}

private func socketPath() -> String {
    ControlSocketPath.forProcess(Int32.random(in: 1_000_000...Int32.max))
}

/// dawctl copied to "<tmp>/Ember Studio stand-in/Contents/MacOS/Ember Studio" (DW-046).
private func standIn(in dir: TempDir) throws -> AppLauncher.Target {
    let folder = dir.file("Ember Studio stand-in/Contents/MacOS")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appending(path: "Ember Studio")
    try FileManager.default.copyItem(at: dawctlBinary(), to: copy)
    return AppLauncher.Target(executable: copy, leadingArguments: ["serve"])
}

private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

@Suite("Attach mode (CTL-011, CTL-023, DW-046)", .serialized)
struct AttachTests {
    @Test("CTL-011: `dawctl --socket` sends requests to a running server; state lives there across calls; --progress goes to stderr")
    func dawctlAttach() async throws {
        let dir = try TempDir()
        let path = socketPath()
        let server = Process()
        server.executableURL = dawctlBinary()
        server.arguments = ["serve", "--control-socket", path, "--parent-pid", String(getpid())]
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            server.terminate()
            server.waitUntilExit()
        }
        #expect(await waitUntil { ControlSocketClient.isListening(at: path) })

        let created = try dawctl(["--socket", path, "project.new", "--json", #"{"name": "attached"}"#], in: dir.url)
        #expect(created.status == 0, "\(created.stderr)")
        let script = try dawctl(["--socket", path, "script", "-"], stdin: """
            command.apply {"command": {"type": "AddTrack", "name": "T", "kind": "audio"}}
            project.get {"path": "/name"}
            """, in: dir.url)
        #expect(script.status == 0, "\(script.stderr)")
        #expect(try responses(script).last?.result == "attached", "the project made by the earlier call")

        let out = dir.file("attached.wav").path
        let render = try dawctl(["--socket", path, "--progress", "render.offline", "--json",
                                 #"{"from": 0, "to": 9600, "path": "\#(out)"}"#], in: dir.url)
        #expect(render.status == 0, "\(render.stderr)")
        #expect(render.stderr.contains("dawctl: render.offline 100%"), "\(render.stderr)")
        #expect(!render.stdout.contains("progress"), "stdout carries only the result")

        let failure = try dawctl(["--socket", path, "command.apply", "--json", #"{"command": {"type": "Nope"}}"#], in: dir.url)
        #expect(failure.status == 1 && failure.stderr.contains("unknownCommandType"), "app errors pass through")
        let repl = try dawctl(["--socket", path, "repl"], stdin: "project.get {\"path\": \"/tracks/0/name\"}\n", in: dir.url)
        #expect(try responses(repl).first?.result == "T")
    }

    @Test("CTL-011: --attach with nothing listening fails with attachFailed and exit 1")
    func attachNothing() throws {
        let dir = try TempDir()
        let run = try dawctl(["--socket", socketPath(), "project.get"], in: dir.url)
        #expect(run.status == 1 && run.stderr.contains("attachFailed") && run.stderr.contains("-32004"))
        let script = try dawctl(["--socket", socketPath(), "script", "-"], stdin: "project.get\n", in: dir.url)
        #expect(script.status == 1, "every request fails, nothing hangs")
    }

    @Test("CTL-023, DW-046: the launcher starts the executable at a path with spaces, passes --control-socket/--parent-pid, and terminate() stops it and its socket")
    func launchAndTerminate() async throws {
        let dir = try TempDir()
        let target = try standIn(in: dir)
        #expect(target.executable.path.contains(" "))
        let path = socketPath()
        let app = try await AppLauncher.attach(target, socketPath: path, engine: .offline, log: dir.file("app.log"))
        let pid = try #require(app.pid)
        #expect(app.launched && app.socketPath == path && isAlive(pid))
        #expect(try await app.client.call(.projectNew, ["name": "launched"])["projectID"] != nil)

        // A second attach to the same socket reuses that app and doesn't own it.
        let again = try await AppLauncher.attach(target, socketPath: path, engine: .offline)
        #expect(!again.launched && again.pid == nil)
        #expect(try await again.client.call(.projectGet, ["path": "/name"]) == "launched", "the same app")
        again.terminate()
        #expect(isAlive(pid), "terminating a reused app leaves it running")

        app.terminate()
        #expect(!isAlive(pid) || app.process?.isRunning == false)
        #expect(await waitUntil { !FileManager.default.fileExists(atPath: path) }, "SIGTERM: the server removed its socket")
        let log = try String(contentsOf: dir.file("app.log"), encoding: .utf8)
        #expect(log.contains("serving at \(path)"), "its output went to the log: \(log)")
    }

    @Test("CTL-023: --parent-pid: the launched app exits when the process that launched it does")
    func parentExit() async throws {
        let dir = try TempDir()
        let target = try standIn(in: dir)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["30"]
        try parent.run()
        let path = socketPath()
        let app = try await AppLauncher.attach(target, socketPath: path, engine: .offline, parentPID: parent.processIdentifier)
        let process = try #require(app.process)
        #expect(process.isRunning)
        parent.terminate()
        #expect(await waitUntil { !process.isRunning }, "the stand-in exits with its parent")
        #expect(!FileManager.default.fileExists(atPath: path))
        app.terminate()
    }

    @Test("CTL-023: a missing app, or one that exits before listening, is attachFailed; a bad --engine is refused")
    func launchFailures() async throws {
        let dir = try TempDir()
        do {
            _ = try await AppLauncher.attach(.init(executable: dir.file("Nope.app/Contents/MacOS/Nope")), socketPath: socketPath())
            Issue.record("launched nothing")
        } catch {
            #expect(error.name == "attachFailed" && error.detail.contains("no app at"))
        }
        do {
            _ = try await AppLauncher.attach(.init(executable: URL(fileURLWithPath: "/usr/bin/false")), socketPath: socketPath(),
                                             timeout: .seconds(10))
            Issue.record("attached to /usr/bin/false")
        } catch {
            #expect(error.name == "attachFailed" && error.detail.contains("exited"), "\(error.detail)")
        }
        let target = try standIn(in: dir)
        let run = Process()
        run.executableURL = target.executable
        run.arguments = ["serve", "--engine", "warp"]
        run.standardError = FileHandle.nullDevice
        try run.run()
        run.waitUntilExit()
        #expect(run.terminationStatus == 2)
    }

    @Test("CTL-023: the app is rebuilt when it is missing or older than its sources")
    func staleness() throws {
        let dir = try TempDir()
        let root = dir.url
        try FileManager.default.createDirectory(at: root.appending(path: "Sources/X"), withIntermediateDirectories: true)
        try "x".write(to: root.appending(path: "Sources/X/a.swift"), atomically: true, encoding: .utf8)
        try "p".write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        #expect(AppLauncher.needsBuild(checkoutRoot: root), "no app yet")

        let executable = AppLauncher.appExecutable(checkoutRoot: root)
        #expect(executable.path.hasSuffix(".build/xcode/Build/Products/Debug/Ember Studio.app/Contents/MacOS/Ember Studio"))
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "bin".write(to: executable, atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSinceNow: -100)
        for file in ["Sources/X/a.swift", "Package.swift"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appending(path: file).path)
        }
        #expect(!AppLauncher.needsBuild(checkoutRoot: root), "built after every source")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)],
                                              ofItemAtPath: root.appending(path: "Sources/X/a.swift").path)
        #expect(AppLauncher.needsBuild(checkoutRoot: root), "a source changed since")
    }
}
