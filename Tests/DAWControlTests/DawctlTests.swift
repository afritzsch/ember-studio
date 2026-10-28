import DAWControl
import DAWModel
import Foundation
import Testing

// CTL-010 / CTL-012: the dawctl binary, launched as a shell test would. The test target depends
// on dawctl, so `swift test` builds it next to the test bundle.

private final class BundleMarker {}

private struct Run {
    var status: Int32
    var stdout: String
    var stderr: String

    var lines: [String] { stdout.split(separator: "\n").map(String.init) }
}

private func dawctl(_ arguments: [String], stdin: String? = nil, in directory: URL) throws -> Run {
    let process = Process()
    process.executableURL = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "dawctl")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    // Only the fixtures a test passes; never the checkout's.
    process.environment = ProcessInfo.processInfo.environment.filter { $0.key != "DAWCTL_FIXTURES" }
    let out = Pipe()
    let err = Pipe()
    let input = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = input
    try process.run()
    if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
    try input.fileHandleForWriting.close()
    // Read before waiting, so a full pipe can't stall the child.
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
               stderr: String(decoding: stderr, as: UTF8.self))
}

private func responses(_ run: Run) throws -> [RPCResponse] {
    try run.lines.map { try JSONDecoder().decode(RPCResponse.self, from: Data($0.utf8)) }
}

@Suite("dawctl (CTL-010, CTL-012)")
struct DawctlTests {
    @Test("CTL-010: `dawctl <method> --json` runs one request and prints its result")
    func singleCall() throws {
        let dir = try TempDir()
        let run = try dawctl(["project.new", "--json", #"{"name": "cli"}"#], in: dir.url)
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == #"{"projectID":"00000000-0000-0000-0000-000000000001"}"# + "\n")
        let pretty = try dawctl(["project.new", "--pretty", "--json", #"{"name": "cli"}"#], in: dir.url)
        #expect(pretty.status == 0 && pretty.lines.count == 3)
    }

    @Test("CTL-012: a failed request exits 1 and prints the JSON-RPC error on stderr")
    func singleFailure() throws {
        let dir = try TempDir()
        let run = try dawctl(["undo"], in: dir.url)
        #expect(run.status == 1 && run.stdout.isEmpty)
        #expect(run.stderr.contains(#""dawError":"noProject""#))
        #expect(try dawctl(["ui.state"], in: dir.url).stderr.contains("methodNotAvailableInHeadless"))
        #expect(try dawctl(["no.such"], in: dir.url).status == 1)
    }

    @Test("CTL-012: bad usage exits 2", arguments: [
        [String](), ["project.new", "--json", "{oops"], ["project.new", "--json"], ["--attach", "undo"], ["--frobnicate"],
        ["script"], ["undo", "redo"],
    ])
    func usage(arguments: [String]) throws {
        let dir = try TempDir()
        let run = try dawctl(arguments, in: dir.url)
        #expect(run.status == 2, "\(arguments): \(run.stderr)")
    }

    @Test("CTL-010: `dawctl script` runs a JSONL file against the real engine and prints every response as JSONL")
    func script() throws {
        let dir = try TempDir()
        try """
            # render one bar of an empty project and look at it
            project.new {"name": "s"}
            {"method": "render.offline", "params": {"from": 0, "to": 3840, "path": "out.wav", "tail": false}}
            audio.analyze {"path": "out.wav"}
            engine.telemetry
            """.write(to: dir.file("s.jsonl"), atomically: true, encoding: .utf8)
        let run = try dawctl(["script", "s.jsonl"], in: dir.url)
        #expect(run.status == 0, "\(run.stderr)")
        let out = try responses(run)
        #expect(out.map(\.id) == [.int(2), .int(3), .int(4), .int(5)], "ids default to line numbers")
        #expect(out.allSatisfy { !$0.isError })
        #expect(out[1].result?["frames"] == 96_000)
        #expect(out[2].result?["peakDb"] == [-240, -240])
        #if DEBUG
        #expect(out[3].result?["rtViolations"] == 0)
        #endif
        #expect(FileManager.default.fileExists(atPath: dir.file("out.wav").path))
    }

    @Test("MODEL-045: `dawctl project.open` reports a newer autosave, and with recover opens it; a save then clears it")
    @MainActor
    func openRecover() async throws {
        let dir = try TempDir()
        // A crashed session: saved once, then an edit that only reached the autosave.
        let store = ProjectStore(project: Project(name: "r"))
        store.autosavePolicy = nil
        try await store.save(to: dir.file("R.dawproject"))
        try store.perform(AddTrack(name: "Unsaved", kind: .audio))
        try await store.autosave()

        let plain = try dawctl(["project.open", "--json", #"{"path": "R.dawproject"}"#], in: dir.url)
        #expect(plain.status == 0, "\(plain.stderr)")
        let report = try JSONValue(parsing: Data(plain.stdout.utf8))["loadReport"]
        #expect(report?["recoveryAvailable"] == true && report?["recovered"] == false)

        try """
            project.open {"path": "R.dawproject", "recover": true}
            project.get {"path": "/tracks/0/name"}
            project.save
            """.write(to: dir.file("recover.jsonl"), atomically: true, encoding: .utf8)
        let run = try dawctl(["script", "recover.jsonl"], in: dir.url)
        #expect(run.status == 0, "\(run.stderr)")
        let out = try responses(run)
        #expect(out[0].result?["loadReport"]?["recovered"] == true)
        #expect(out[1].result == "Unsaved")
        #expect(!FileManager.default.fileExists(atPath: dir.file("R.dawproject/autosave").path), "the save made it stale")

        let after = try dawctl(["project.open", "--json", #"{"path": "R.dawproject"}"#], in: dir.url)
        #expect(try JSONValue(parsing: Data(after.stdout.utf8))["loadReport"]?["recoveryAvailable"] == false)
    }

    @Test("CTL-010, CTL-012: a script stops at the first error and exits 1; --keep-going runs the rest")
    func scriptFailure() throws {
        let dir = try TempDir()
        let text = "project.new {\"name\": \"s\"}\ncommand.apply {\"command\": {\"type\": \"Nope\"}}\nproject.get {\"path\": \"/name\"}\n"
        try text.write(to: dir.file("f.jsonl"), atomically: true, encoding: .utf8)
        let stop = try dawctl(["script", "f.jsonl"], in: dir.url)
        #expect(stop.status == 1 && stop.lines.count == 2)
        #expect(try responses(stop)[1].error?.dawError == "unknownCommandType")
        #expect(stop.stderr.contains("line 2"))

        let keepGoing = try dawctl(["script", "--keep-going", "f.jsonl"], in: dir.url)
        #expect(keepGoing.status == 1 && keepGoing.lines.count == 3)
        #expect(try responses(keepGoing)[2].result == "s")

        try "project.new {\"name\": \"x\"}\n{nope\n".write(to: dir.file("bad.jsonl"), atomically: true, encoding: .utf8)
        let unparsable = try dawctl(["script", "bad.jsonl"], in: dir.url)
        #expect(unparsable.status == 1 && unparsable.stdout.isEmpty && unparsable.stderr.contains("line 2"))
        #expect(try dawctl(["script", "missing.jsonl"], in: dir.url).status == 1)
    }

    @Test("CTL-010: `dawctl script -` reads the script from stdin")
    func scriptStdin() throws {
        let dir = try TempDir()
        let run = try dawctl(["script", "-"], stdin: "project.new {\"name\": \"in\"}\nproject.get {\"path\": \"/name\"}\n",
                             in: dir.url)
        #expect(try run.status == 0 && responses(run).last?.result == "in")
    }

    @Test("CTL-010: `dawctl repl` answers each line; exit status reports whether any request failed")
    func repl() throws {
        let dir = try TempDir()
        let ok = try dawctl(["repl"], stdin: "project.new {\"name\": \"r\"}\n\n# note\nproject.get {\"path\": \"/name\"}\nquit\nundo\n",
                            in: dir.url)
        #expect(ok.status == 0, "\(ok.stderr)")
        #expect(try responses(ok).map(\.result) == [["projectID": "00000000-0000-0000-0000-000000000001"], "r"])

        let failed = try dawctl(["repl"], stdin: "undo\n{bad\nproject.new {\"name\": \"r\"}\n", in: dir.url)
        #expect(failed.status == 1 && failed.lines.count == 3)
        #expect(try responses(failed).map { $0.error?.dawError } == ["noProject", "parseError", nil])
    }

    @Test("CTL-010: `dawctl methods` lists every method; test.fixture finds scripts via --fixtures")
    func methodsAndFixtures() throws {
        let dir = try TempDir()
        let methods = try dawctl(["methods"], in: dir.url)
        #expect(methods.status == 0)
        #expect(methods.lines.map { String($0.prefix { $0 != " " }) } == ControlMethod.allCases.map(\.rawValue))

        try FileManager.default.createDirectory(at: dir.file("fx"), withIntermediateDirectories: true)
        try "project.new {\"name\": \"fixture\"}\n".write(to: dir.file("fx/tiny.jsonl"), atomically: true, encoding: .utf8)
        let run = try dawctl(["script", "-", "--fixtures", "fx"],
                             stdin: "test.fixture {\"name\": \"tiny\"}\nproject.get {\"path\": \"/name\"}\n", in: dir.url)
        #expect(run.status == 0, "\(run.stderr)")
        #expect(try responses(run).last?.result == "fixture")
    }
}
