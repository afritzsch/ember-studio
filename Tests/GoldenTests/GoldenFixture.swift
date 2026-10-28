import DAWControl
import DAWModel
import Foundation

/// TEST-001: a golden fixture, `fixtures/<name>.jsonl`. It is a `dawctl` script (CTL-010) that
/// builds a project with commands and calls `render.offline`; the last render is compared with
/// `references/<name>.wav` (TEST-002).
///
/// Comment lines starting with `# @` are directives for the golden harness, each followed by one
/// JSON object. `dawctl`/`dawmcp` read them as comments.
///
/// - `# @node {"kind": "audioClipPlayer", "type": "sine", "frequency": 1000, "level": 1}`
///   registers a test-only node (TEST-004) under a real kind for this fixture's engine. Under
///   `audioClipPlayer` it stands in only for tracks without clips. Types: `sine` (frequency Hz,
///   level), `impulse` (level at `offset`, `offset + samples`, …; `samples` 0 fires once; 1 is
///   a constant), `fakeLatency` (`samples` frames), `nan`. One per kind. `allocating` is left
///   out on purpose: deliberate RT violations belong in RtTrapTests (14, "C++ unit tests").
/// - `# @expect {"field": "peakDb", "value": -6.02, "tolerance": 0.01, "range": {"start": 0, "end": 512}}`
///   checks a field of `audio.analyze` on the golden render (every channel for per-channel
///   fields), so the numbers the spec states hold whatever the reference says. `frames` checks
///   the render's length. `range` and `tolerance` (default 0) are optional. `"channel": 0`
///   checks one channel of a per-channel field only (T-025: a hard-left pan is loud on the left
///   and silent on the right).
struct GoldenFixture: Sendable {
    struct TestNode: Hashable, Sendable, Decodable {
        enum NodeType: String, Hashable, Sendable, Decodable { case sine, impulse, fakeLatency, nan }

        var kind: NodeKind
        var type: NodeType
        var frequency: Double?
        var level: Float?
        var samples: UInt32?
        var offset: UInt32?
    }

    struct Expectation: Hashable, Sendable, Decodable {
        var field: String
        var value: Double
        var tolerance: Double?
        var range: FrameRange?
        var channel: Int?
    }

    struct ParseError: Error, CustomStringConvertible {
        var description: String
    }

    let name: String
    let script: ControlScript
    let testNodes: [TestNode]
    let expectations: [Expectation]

    init(name: String, contentsOf url: URL) throws {
        try self.init(name: name, text: String(contentsOf: url, encoding: .utf8))
    }

    init(name: String, text: String) throws {
        self.name = name
        script = try ControlScript(parsing: text)
        var nodes: [TestNode] = []
        var expectations: [Expectation] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("# @") else { continue }
            let body = line.dropFirst(3)
            let word = body.prefix { !$0.isWhitespace }
            let json = Data(body.dropFirst(word.count).utf8)
            do {
                switch word {
                case "node": nodes.append(try JSONDecoder().decode(TestNode.self, from: json))
                case "expect": expectations.append(try JSONDecoder().decode(Expectation.self, from: json))
                default: throw ParseError(description: "unknown directive @\(word)")
                }
            } catch {
                throw ParseError(description: "\(name).jsonl:\(index + 1): \(error)")
            }
        }
        let kinds = nodes.map(\.kind)
        if Set(kinds).count != kinds.count {
            throw ParseError(description: "\(name).jsonl: a kind has more than one @node")
        }
        testNodes = nodes
        self.expectations = expectations
    }
}
