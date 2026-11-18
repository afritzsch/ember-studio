import DAWControl
import Foundation
import Testing

// DW-300 (T-101): dawctl's stdout carries only its own output (CTL-010 JSONL). Anything else in
// the process that writes to fd 1, such as a hosted plugin's printf, goes to stderr. The debug-only
// DAWCTL_TEST_STRAY_STDOUT hook writes to fd 1 (raw write(1) and C stdio) before every request.

@Suite("dawctl stdout isolation (DW-300)")
struct DawctlStdoutTests {
    private let stray = ["DAWCTL_TEST_STRAY_STDOUT": "1"]

    private func expectStrayOnStderr(_ run: Run, before method: String) {
        #expect(run.stderr.contains("stray write(1) before \(method)\n"), "\(run.stderr)")
        #expect(run.stderr.contains("stray printf before \(method)\n"), "\(run.stderr)")
        #expect(!run.stdout.contains("stray"), "\(run.stdout)")
    }

    @Test("DW-300: a write to fd 1 during a single request lands on stderr; stdout holds only the result")
    func single() throws {
        let dir = try TempDir()
        let run = try dawctl(["project.new", "--json", #"{"name": "cli"}"#], in: dir.url, environment: stray)
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout == #"{"projectID":"00000000-0000-0000-0000-000000000001"}"# + "\n")
        expectStrayOnStderr(run, before: "project.new")
    }

    @Test("DW-300: `dawctl script` and `dawctl repl` print only JSONL responses while fd 1 is written to during each request")
    func scriptAndREPL() throws {
        let dir = try TempDir()
        let script = """
            project.new {"name": "s"}
            command.apply {"command": {"type": "AddTrack", "name": "A", "kind": "audio"}}
            render.offline {"from": 0, "to": 960, "path": "out.wav", "tail": false}
            project.get {"path": "/name"}

            """
        for arguments in [["script", "-"], ["repl"]] {
            let run = try dawctl(arguments, stdin: script, in: dir.url, environment: stray)
            #expect(run.status == 0, "\(arguments): \(run.stderr)")
            let decoded = try responses(run)
            #expect(decoded.count == 4 && decoded.allSatisfy { !$0.isError }, "\(arguments): \(run.stdout)")
            for method in ["project.new", "command.apply", "render.offline", "project.get"] {
                expectStrayOnStderr(run, before: method)
            }
        }
    }
}
