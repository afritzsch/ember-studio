import DAWControl
import DAWModel
import Foundation
import Testing

// T-073: the reverb_determinism golden (DSP-033, IO-011). The fixture runs twice on fresh
// engines and the renders must be the same bits (and null against the reference); since T-089
// (DW-063) also twice on one engine with a ringing tail in between; and the
// reference is checked sample by sample against an oracle written from 06's reverb signal path
// (nodes/Reverb.h), so a regenerated reference can't hide a wrong network, tap or level. The
// input comes from the fixture's asset files.

@Suite("Golden references, M7 (DSP-033, IO-011)")
struct ReverbGoldenTests {
    static let name = "reverb_determinism"
    static let rate = 48000.0
    static let frames = 60000
    /// The fixture's reverb: size 0.6, decay 0.8 s, damping 0.4, pre-delay 15 ms, mix 0.5.
    static let size = 0.6, decay = 0.8, damping = 0.4, predelayMs = 15.0, mix = 0.5
    /// Kick clip at tick 480: 25 frames per tick at 120 bpm.
    static let kickStart = 12000
    /// Centre pans on Room and the master (MIX-005): √½ · √½.
    static let centre = 0.5

    /// 06 DSP-033 for constant params and the same input on both sides: returns (L, R).
    static func oracle(_ input: [Double]) -> ([Double], [Double]) {
        let base: [Double] = [2411, 2647, 2953, 3203, 3541, 3833, 4241, 4799]
        let scale = 0.15 + 0.85 * size
        let lengths = base.map { max(1, ($0 * scale * rate / 48000).rounded()) }
        let gains = lengths.map { pow(10, -3 * $0 / (decay * rate)) }
        let p = Int((predelayMs * rate / 1000).rounded())
        let cutoff = min(18000 * pow(500.0 / 18000, damping), 0.45 * rate)
        let a = exp(-2 * Double.pi * cutoff / rate)
        func sign(_ r: Int, _ c: Int) -> Double { (r & c).nonzeroBitCount % 2 == 0 ? 1 : -1 }

        var lines = [[Double]](repeating: [], count: 8)
        var z = [Double](repeating: 0, count: 8)
        var left = [Double](), right = [Double]()
        left.reserveCapacity(input.count)
        right.reserveCapacity(input.count)
        for t in input.indices {
            let pre = t - p >= 0 ? input[t - p] : 0  // whole-frame delays: no interpolation
            var x = [Double](repeating: 0, count: 8), y = [Double](repeating: 0, count: 8)
            for i in 0..<8 {
                let k = t - Int(lengths[i])
                x[i] = k >= 0 ? lines[i][k] : 0
                z[i] = (1 - a) * x[i] + a * z[i]
                y[i] = gains[i] * z[i]
            }
            for row in 0..<8 {
                var m = 0.0
                for c in 0..<8 { m += sign(row, c) * y[c] }
                lines[row].append(m / 8.0.squareRoot() + pre)  // L and R inputs are the same
            }
            var wL = 0.0, wR = 0.0
            for i in 0..<8 {
                wL += sign(1, i) * x[i]
                wR += sign(2, i) * x[i]
            }
            left.append((1 - mix) * input[t] + mix * 0.25 * wL)
            right.append((1 - mix) * input[t] + mix * 0.25 * wR)
        }
        return (left, right)
    }

    @Test("IO-011: reverb_determinism renders the same bits on two fresh engines, and nulls against its reference")
    @MainActor func twoRendersBitIdentical() async throws {
        let fixture = try GoldenFixture(name: Self.name,
                                        contentsOf: GoldenHarness.fixturesDirectory.appending(path: "\(Self.name).jsonl"))
        var renders: [AudioData] = []
        for _ in 0..<2 {
            let run = await GoldenHarness.run(fixture, reference: GoldenHarness.reference(Self.name))
            defer { try? FileManager.default.removeItem(at: run.workDirectory) }
            #expect(run.failures == [])
            #expect(run.comparison?.pass == true)
            #expect(run.renders.allSatisfy { $0.rtViolations == 0 })
            guard let golden = run.golden else { continue }
            renders.append(try AudioData(contentsOf: golden))
        }
        #expect(renders.count == 2)
        guard renders.count == 2 else { return }
        #expect(renders[0].frameCount == Self.frames && renders[0].channels.count == 2)
        for (a, b) in zip(renders[0].channels, renders[1].channels) {
            #expect(a.map(\.bitPattern) == b.map(\.bitPattern))
        }
        // A reverb, not silence: the tail is there in both channels.
        for channel in renders[0].channels { #expect(channel[3000..<12000].contains { $0 != 0 }) }
    }

    /// DW-063 (T-089): an offline render resets every node first, so a reverb tail still ringing
    /// from the render before can't reach the next one. On one engine: the fixture's render, a
    /// render of ticks 480..<600 (cut while the kick's tail rings), then the fixture's range again,
    /// which must be the first render's bits. (Live playback first: `offlineResetsEveryNode`.)
    @Test("DW-063, IO-011: reverb_determinism renders the same bits twice on one engine, a ringing tail in between")
    @MainActor func sameEngineRendersBitIdentical() async throws {
        let fixture = try GoldenFixture(name: Self.name,
                                        contentsOf: GoldenHarness.fixturesDirectory.appending(path: "\(Self.name).jsonl"))
        let work = FileManager.default.temporaryDirectory
            .appending(path: "golden-same-engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createSymbolicLink(
            at: work.appending(path: "assets"),
            withDestinationURL: GoldenHarness.fixturesDirectory.appending(path: "assets", directoryHint: .isDirectory))
        let dispatcher = Dispatcher(configuration: .init(
            mode: .headless,
            makeEngine: { rate throws(DAWError) in try GoldenEngine(sampleRate: rate, testNodes: []) },
            workingDirectory: work,
            fixtureDirectories: [GoldenHarness.fixturesDirectory]))
        for line in fixture.script.lines {
            let response = await dispatcher.handle(line.request)
            #expect(response?.error == nil, "\(line.request.method)")
        }
        func render(_ from: Int64, _ to: Int64, _ path: String) async throws -> AudioData {
            _ = try await dispatcher.call(ControlMethod.renderOffline.rawValue,
                                          .object(["from": .int(from), "to": .int(to), "path": .string(path),
                                                   "tail": .bool(false)]))
            return try AudioData(contentsOf: work.appending(path: path))
        }
        let cut = try await render(480, 600, "cut.wav")
        let again = try await render(0, 2400, "again.wav")
        let first = try AudioData(contentsOf: work.appending(path: "\(Self.name).wav"))

        // The cut render really stops with the reverb ringing, so a carried-over tail would show.
        for channel in cut.channels { #expect(channel.suffix(256).contains { abs($0) > 1e-4 }) }
        #expect(first.frameCount == Self.frames && again.frameCount == Self.frames)
        #expect(first.channels.count == 2 && again.channels.count == 2)
        for (a, b) in zip(first.channels, again.channels) {
            #expect(a.map(\.bitPattern) == b.map(\.bitPattern))
        }
        let telemetry = try await dispatcher.call(ControlMethod.engineTelemetry.rawValue)
        #expect(telemetry["rtViolations"]?.int64Value == 0)
    }

    @Test("DSP-033: reverb_determinism is 0.5 × the FDN oracle of click + kick, sample by sample")
    func samplesMatchOracle() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference(Self.name))
        #expect(audio.sampleRate == 48000)
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == Self.frames)
        guard audio.channels.count == 2, audio.frameCount == Self.frames else { return }
        let click = try M3GoldenReferenceTests.asset("click_48k.wav")
        let kick = try M3GoldenReferenceTests.asset("kick_48k.wav")
        #expect(click.count == 4800 && click[0] == 1 && kick.count == 9600)
        var input = [Double](repeating: 0, count: Self.frames)
        for (i, x) in click.enumerated() { input[i] += Double(x) }
        for (i, x) in kick.enumerated() where Self.kickStart + i < Self.frames { input[Self.kickStart + i] += Double(x) }

        let (l, r) = Self.oracle(input)
        for (channel, want) in zip(audio.channels, [l, r]) {
            var worst = 0.0
            for n in 0..<Self.frames { worst = max(worst, abs(Double(channel[n]) - Self.centre * want[n])) }
            #expect(worst < 1e-5)
        }

        // Stated in the render itself: the dry click at frame 0, silence until the first wet
        // sample at pre-delay 720 + shortest line 1591, which is kOutGain · mix · 0.5 on both sides.
        let (left, right) = (audio.channels[0], audio.channels[1])
        #expect(abs(left[0] - 0.25) < 1e-7 && abs(right[0] - 0.25) < 1e-7)  // √½ · √½ in float
        #expect(left[1..<2311].allSatisfy { $0 == 0 } && right[1..<2311].allSatisfy { $0 == 0 })
        #expect(abs(left[2311] - 0.0625) < 1e-7 && abs(right[2311] - 0.0625) < 1e-7)
        #expect(left != right)  // decorrelated taps
        // The tail decays: the last 0.1 s is over 40 dB below the 0.1 s after the kick.
        func energy(_ range: Range<Int>) -> Double { range.reduce(0) { $0 + Double(left[$1]) * Double(left[$1]) } }
        #expect(10 * log10(energy(55200..<60000) / energy(12000..<16800)) < -40)
    }
}
