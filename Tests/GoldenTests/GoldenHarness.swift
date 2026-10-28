import DAWControl
import DAWModel
import Foundation

/// TEST-001..003: runs golden fixtures in-process (DW-108): each script line goes through
/// DAWControl's `Dispatcher.handle(_:)` in headless mode, on a `GoldenEngine` with the fixture's
/// test-only nodes. The last `render.offline` is the golden render. It must:
/// - finish every line without an error, with 0 RT violations (every render's own scope and
///   `engine.telemetry`, CONV §5.3);
/// - meet the fixture's `@expect` numbers (GoldenFixture);
/// - null against `references/<name>.wav` with a residual ≤ −100 dBFS (`audio.compare`, TEST-002).
///
/// `scripts/update-goldens.sh <name>` (TEST-003) sets `DAW_GOLDEN_UPDATE=<name>`: the fixture must
/// still run cleanly and meet its `@expect`s, then its render replaces the reference in the
/// checkout and an `audio.analyze` before/after summary goes to stdout and to
/// `$DAW_GOLDEN_SUMMARY_DIR/<name>.txt`, for the commit message.
///
/// Renders go to a fresh folder under $TMPDIR (CONV §9), removed unless the fixture failed.
/// Relative paths in a script resolve there; `assets/` in it links to `fixtures/assets`.
@MainActor
enum GoldenHarness {
    /// TEST-002.
    nonisolated static let toleranceDb = -100.0

    nonisolated static var fixturesDirectory: URL { resources.appending(path: "fixtures", directoryHint: .isDirectory) }
    nonisolated static var referencesDirectory: URL { resources.appending(path: "references", directoryHint: .isDirectory) }
    /// The checkout's references, where updates go (the bundle holds a build-time copy).
    nonisolated static var sourceReferencesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "references", directoryHint: .isDirectory)
    }

    nonisolated private static var resources: URL { Bundle.module.resourceURL! }

    /// Fixture names (`fixtures/<name>.jsonl`), sorted.
    nonisolated static func fixtureNames() -> [String] { names(in: fixturesDirectory, extension: "jsonl") }
    /// Reference names (`references/<name>.wav`), sorted.
    nonisolated static func referenceNames() -> [String] { names(in: referencesDirectory, extension: "wav") }

    /// `DAW_GOLDEN_UPDATE`: comma-separated fixture names whose references to regenerate.
    nonisolated static var namesToUpdate: Set<String> {
        let raw = ProcessInfo.processInfo.environment["DAW_GOLDEN_UPDATE"] ?? ""
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    nonisolated static func reference(_ name: String) -> URL { referencesDirectory.appending(path: "\(name).wav") }

    // MARK: Running

    struct Run {
        var failures: [String] = []
        var workDirectory: URL
        /// Every `render.offline`, in script order.
        var renders: [RenderOfflineResult] = []
        /// The last render's file.
        var golden: URL? { renders.last.map { URL(fileURLWithPath: $0.path) } }
        /// Against the reference, when one was compared.
        var comparison: AudioComparison?
    }

    /// Runs the fixture `name` from the bundle and checks it against its reference, or replaces
    /// the reference when `update`. Returns the failures (empty: passed).
    static func check(_ name: String, update: Bool = false) async -> [String] {
        let fixture: GoldenFixture
        do {
            fixture = try GoldenFixture(name: name, contentsOf: fixturesDirectory.appending(path: "\(name).jsonl"))
        } catch {
            return ["\(name): \(error)"]
        }
        if update {
            var run = await self.run(fixture, reference: nil)
            if run.failures.isEmpty { run.failures += await replaceReference(of: fixture, with: run) }
            finish(run)
            return run.failures
        }
        let run = await self.run(fixture, reference: reference(name))
        finish(run)
        return run.failures
    }

    /// Runs `fixture`; with `reference`, compares the golden render with it.
    static func run(_ fixture: GoldenFixture, reference: URL?) async -> Run {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "golden-\(fixture.name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        var run = Run(workDirectory: work)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let assets = fixturesDirectory.appending(path: "assets", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: assets.path) {
                try FileManager.default.createSymbolicLink(at: work.appending(path: "assets"), withDestinationURL: assets)
            }
        } catch {
            run.failures.append("\(fixture.name): can't prepare \(work.path): \(error)")
            return run
        }

        let testNodes = fixture.testNodes
        let dispatcher = Dispatcher(configuration: .init(
            mode: .headless,
            makeEngine: { rate throws(DAWError) in try GoldenEngine(sampleRate: rate, testNodes: testNodes) },
            workingDirectory: work,
            fixtureDirectories: [fixturesDirectory]))

        for line in fixture.script.lines {
            let where_ = "\(fixture.name).jsonl:\(line.number) \(line.request.method)"
            guard let response = await dispatcher.handle(line.request) else { continue }  // a notification
            if let error = response.error {
                run.failures.append("\(where_) failed: \(error.message) \(error.data?.jsonString() ?? "")")
                return run
            }
            if line.request.method == ControlMethod.renderOffline.rawValue {
                do {
                    let render = try (response.result ?? .null).decode(RenderOfflineResult.self)
                    if render.rtViolations != 0 { run.failures.append("\(where_): \(render.rtViolations) RT violations") }
                    run.renders.append(render)
                } catch {
                    run.failures.append("\(where_): unexpected result: \(error)")
                }
            }
        }
        guard let golden = run.golden else {
            run.failures.append("\(fixture.name): the fixture never calls render.offline (TEST-001)")
            return run
        }

        // CONV §5.3: nothing the fixture did counted an RT violation.
        do {
            let telemetry = try await dispatcher.call(ControlMethod.engineTelemetry.rawValue)
            let violations = telemetry["rtViolations"]?.int64Value
            if violations != 0 { run.failures.append("\(fixture.name): engine.telemetry rtViolations = \(violations.map(String.init) ?? "missing")") }
        } catch {
            run.failures.append("\(fixture.name): engine.telemetry failed: \(error)")
        }

        for expectation in fixture.expectations {
            if let failure = await check(expectation, of: golden, with: dispatcher) {
                run.failures.append("\(fixture.name) @expect \(expectation.field): \(failure)")
            }
        }

        guard let reference else { return run }
        guard FileManager.default.fileExists(atPath: reference.path) else {
            run.failures.append("""
                \(fixture.name): no reference \(reference.lastPathComponent). Create it with \
                scripts/update-goldens.sh \(fixture.name) and paste its summary into the commit (TEST-003).
                """)
            return run
        }
        do {
            let comparison = try await compare(reference, golden, with: dispatcher)
            run.comparison = comparison
            if !comparison.pass || comparison.framesA != comparison.framesB {
                run.failures.append("""
                    \(fixture.name): render differs from \(reference.lastPathComponent): null residual \
                    \(format(comparison.nullResidualDb)) dBFS (tolerance \(format(toleranceDb))) at frame \
                    \(comparison.maxDiffSample), offset \(comparison.offsetSamples) frames, \
                    \(comparison.framesB) frames vs \(comparison.framesA) in the reference. Render kept at \(golden.path)
                    """)
            }
        } catch {
            run.failures.append("\(fixture.name): audio.compare failed: \(error)")
        }
        return run
    }

    // MARK: Updating (TEST-003)

    /// Copies the golden render over the checkout's reference and reports before/after.
    private static func replaceReference(of fixture: GoldenFixture, with run: Run) async -> [String] {
        guard let golden = run.golden else { return [] }
        let target = sourceReferencesDirectory.appending(path: "\(fixture.name).wav")
        let dispatcher = Dispatcher(configuration: .init(workingDirectory: run.workDirectory))
        var summary = ["golden \(fixture.name): reference regenerated (scripts/update-goldens.sh, TEST-003)"]
        do {
            let previous = FileManager.default.fileExists(atPath: target.path) ? target : nil
            var before: AudioAnalysis?
            if let previous { before = try await analyze(previous, with: dispatcher) }
            let after = try await analyze(golden, with: dispatcher)
            summary.append("  before: " + (before.map(describe) ?? "(no reference)"))
            summary.append("  after:  " + describe(after))
            if let previous {
                let c = try await compare(previous, golden, with: dispatcher)
                summary.append("  null residual before → after: \(format(c.nullResidualDb)) dBFS at frame \(c.maxDiffSample), " +
                               "offset \(c.offsetSamples), frames \(c.framesA) → \(c.framesB)")
            }
            try FileManager.default.createDirectory(at: sourceReferencesDirectory, withIntermediateDirectories: true)
            if previous != nil { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: golden, to: target)
        } catch {
            return ["\(fixture.name): updating \(target.path) failed: \(error)"]
        }
        let text = summary.joined(separator: "\n") + "\n"
        print(text, terminator: "")
        if let dir = ProcessInfo.processInfo.environment["DAW_GOLDEN_SUMMARY_DIR"] {
            let url = URL(fileURLWithPath: dir, isDirectory: true).appending(path: "\(fixture.name).txt")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        return []
    }

    // MARK: Helpers

    private static func finish(_ run: Run) {
        if run.failures.isEmpty { try? FileManager.default.removeItem(at: run.workDirectory) }
    }

    private static func check(_ e: GoldenFixture.Expectation, of file: URL, with dispatcher: Dispatcher) async -> String? {
        var params: [String: JSONValue] = ["path": .string(file.path)]
        if let range = e.range { params["range"] = ["start": .int(range.start), "end": .int(range.end)] }
        let result: JSONValue
        do {
            result = try await dispatcher.call(ControlMethod.audioAnalyze.rawValue, .object(params))
        } catch {
            return "audio.analyze failed: \(error)"
        }
        let values: [Double]? = switch result[e.field] {
        case .array(let items)?: items.compactMap(\.doubleValue)
        case let value?: value.doubleValue.map { [$0] }
        case nil: nil
        }
        guard var values, !values.isEmpty else { return "audio.analyze has no numeric field \(e.field)" }
        if let channel = e.channel {
            guard case .array? = result[e.field] else { return "\(e.field) is not a per-channel field" }
            guard values.indices.contains(channel) else { return "no channel \(channel) (\(values.count) channels)" }
            values = [values[channel]]
        }
        let tolerance = e.tolerance ?? 0
        let off = values.filter { abs($0 - e.value) > tolerance }
        guard off.isEmpty else {
            return "\(list(values)) is not \(format(e.value)) ± \(format(tolerance))" +
                (e.channel.map { " on channel \($0)" } ?? "") +
                (e.range.map { " in frames \($0.start)..<\($0.end)" } ?? "")
        }
        return nil
    }

    private static func analyze(_ file: URL, with dispatcher: Dispatcher) async throws -> AudioAnalysis {
        try await dispatcher.call(ControlMethod.audioAnalyze.rawValue, ["path": .string(file.path)])
            .decode(AudioAnalysis.self)
    }

    private static func compare(_ a: URL, _ b: URL, with dispatcher: Dispatcher) async throws -> AudioComparison {
        try await dispatcher.call(ControlMethod.audioCompare.rawValue,
                                  ["a": .string(a.path), "b": .string(b.path), "toleranceDb": .double(toleranceDb)])
            .decode(AudioComparison.self)
    }

    /// One line of `audio.analyze` for a commit message.
    static func describe(_ a: AudioAnalysis) -> String {
        "\(a.frames) frames @ \(format(a.sampleRate)) Hz × \(a.channels), peak \(list(a.peakDb)) dBFS, " +
            "rms \(list(a.rmsDb)) dBFS, \(format(a.lufsIntegrated)) LUFS, true peak \(format(a.truePeakDb)) dBTP, " +
            "spectrum peak \(format(a.spectrumPeakHz)) Hz, dc \(format(a.dcOffset)), first sound at \(a.firstNonSilentSample)"
    }

    nonisolated static func format(_ x: Double) -> String { String(format: "%.2f", x) }
    nonisolated static func list(_ xs: [Double]) -> String { "[" + xs.map(format).joined(separator: ", ") + "]" }

    nonisolated private static func names(in directory: URL, extension ext: String) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".\(ext)") }.map { String($0.dropLast(ext.count + 1)) }.sorted()
    }
}
