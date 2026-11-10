import DAWControl
import DAWModel
import Foundation
import Testing

// T-074: the automation goldens (11). The stored references (automation_ramp, automation_loop_wrap)
// are checked sample by sample against the lane computed here, so a regenerated reference can't
// hide a wrong evaluation point, mapping or wrap. Positions come from DAWModel's TempoMap (the
// bit-identical mirror of the engine's, TIME-011), values from 11's curve and 06's ParamInfo
// mapping (automation/ParamMapping.h), the ramps from ENG-022.
//
// AUTO-009 (automation_vst3_again) renders through the SDK's `again` sample like VST3GoldenTests:
// its output is computed, not stored, because the plugin identifier holds a machine-specific path.

@Suite("Golden, automation (AUTO-002, AUTO-003, AUTO-009)")
@MainActor
struct AutomationGoldenTests {
    static let tolerance = 1e-6
    /// The constant source (0.25) through the track's and the master's centre pans (√½ · √½).
    static let unity = 0.25 * Double(Float(0.5.squareRoot())) * Double(Float(0.5.squareRoot()))

    static let map = try! TempoMap(tempoEvents: [TempoEvent(tick: 0, bpm: 120)],
                                   timeSignatures: [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)],
                                   sampleRate: 48000)

    /// TransportSegments.h: the first tick at or after a sample.
    static func firstTick(_ sample: Int64) -> Int64 { map.sampleToTick(sample - 1).raw + 1 }

    /// A linear lane (AUTO-004), held before the first and after the last point.
    struct Lane {
        var points: [(tick: Int64, value: Double)]

        func value(_ tick: Int64) -> Double {
            guard let first = points.first, let last = points.last else { return 0 }
            if tick <= first.tick { return first.value }
            if tick >= last.tick { return last.value }
            let i = points.lastIndex { $0.tick <= tick }!
            let a = points[i], b = points[i + 1]
            return a.value + (b.value - a.value) * Double(tick - a.tick) / Double(b.tick - a.tick)
        }
    }

    /// ParamMapping's db curve for the strip's 0…+12 dB fader: 0 is silence, else dB-linear from
    /// −60 dB to 20·log10(max).
    static func fader(_ v: Double) -> Double {
        guard v > 0 else { return 0 }
        let top = 20 * log10(Double(Float(3.981_071_71)))
        return pow(10, (-60 + v * (top + 60)) / 20)
    }

    /// The strip's output for `frames` frames of playback from 0 in `block`-frame blocks with an
    /// optional loop (samples), its gain lane evaluated per segment start (AUTO-002/003).
    static func expected(lane: Lane, frames: Int, block: Int, loop: (start: Int64, end: Int64, tick: Int64)? = nil) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(frames)
        var pos: Int64 = 0
        var previous: Double?
        while out.count < frames {
            let n = min(block, frames - out.count)
            let g0 = fader(lane.value(firstTick(pos)))
            let start = previous ?? g0  // the strip's first block doesn't ramp
            if let loop, pos < loop.end, pos + Int64(n) > loop.end {
                let k = Int(loop.end - pos)
                let g1 = fader(lane.value(max(firstTick(loop.start), loop.tick)))
                for i in 0..<k { out.append(start + (g0 - start) * Double(i + 1) / Double(k)) }
                for _ in k..<n { out.append(g1) }
                previous = g1
                pos = loop.start + Int64(n - k)
            } else {
                for i in 0..<n { out.append(start + (g0 - start) * Double(i + 1) / Double(n)) }
                previous = g0
                pos += Int64(n)
            }
        }
        return out.map { $0 * unity }
    }

    static func reference(_ name: String) throws -> AudioData {
        try AudioData(contentsOf: GoldenHarness.reference(name))
    }

    @Test("AUTO-002: automation_ramp follows the lane, evaluated at each block start, within one block of the analytic ramp")
    func rampReference() throws {
        let audio = try Self.reference("automation_ramp")
        let lane = Lane(points: [(0, 0), (3840, 1)])
        let expected = Self.expected(lane: lane, frames: 120_000, block: 512)
        #expect(audio.channels.count == 2 && audio.frameCount == expected.count)
        for channel in audio.channels {
            let worst = zip(channel, expected).map { abs(Double($0) - $1) }.max() ?? 1
            #expect(worst <= Self.tolerance, "largest deviation \(worst)")
            // Analytic: every frame lies between the lane one block earlier and at the frame itself
            // (from block 2, after the fader's step out of silence).
            var within = true
            for f in stride(from: 1024, to: 96_000, by: 37) {
                let now = Self.fader(lane.value(Int64(f) / 25)) * Self.unity
                let before = Self.fader(lane.value(Int64(f - 512) / 25)) * Self.unity
                within = within && Double(channel[f]) <= now + 1e-6 && Double(channel[f]) >= before - 1e-6
            }
            #expect(within)
        }
    }

    @Test("AUTO-003: automation_loop_wrap jumps at each wrap frame to the loop start's value; no ramp across the wrap")
    func loopWrapReference() throws {
        let audio = try Self.reference("automation_loop_wrap")
        let lane = Lane(points: [(960, 0.2), (1920, 1)])
        let expected = Self.expected(lane: lane, frames: 96_000, block: 700, loop: (24_000, 48_000, 960))
        #expect(audio.channels.count == 2 && audio.frameCount == expected.count)
        let atWrap = Self.fader(0.2) * Self.unity
        for channel in audio.channels {
            let worst = zip(channel, expected).map { abs(Double($0) - $1) }.max() ?? 1
            #expect(worst <= Self.tolerance, "largest deviation \(worst)")
            // Right before a wrap the lane is near +12 dB; from the wrap frame on, the loop start.
            #expect(Double(channel[47_999]) > 0.4)
            #expect(abs(Double(channel[48_000]) - atWrap) <= Self.tolerance)
            #expect(abs(Double(channel[72_000]) - atWrap) <= Self.tolerance)
        }
    }

    // MARK: AUTO-009

    /// `again` (gain param 0, normalized, identity mapping) on a constant 1.0 source, the lane
    /// rising 0 → 1 over one bar. The plugin gets each block's value as one IParameterChanges point
    /// at offset 0 and applies it to the whole block, so block k is exactly 0.5 · lane(block start).
    static func vst3FixtureText(pluginIdentifier: String) -> String {
        let device = #"{"format": "vst3", "identifier": "\#(pluginIdentifier)", "name": "AGain VST3", "vendor": "Steinberg", "version": ""}"#
        return #"""
        # @node {"kind": "audioClipPlayer", "type": "impulse", "samples": 1, "level": 1}
        # @expect {"field": "frames", "value": 96000}
        project.new {"name": "automation_vst3_again", "sampleRate": 48000}
        command.apply {"command": {"type": "RestoreTrack", "index": 0, "track": {"id": 2, "name": "Again", "kind": "audio", "color": {"red": 0.5, "green": 0.5, "blue": 0.5}, "clips": [], "takeFolders": [], "inserts": [{"id": 3, "kind": \#(device), "params": [], "bypass": false}], "strip": {"gain": 1, "pan": 0, "mute": false, "solo": false, "phaseInvert": false}, "sends": [], "output": {"kind": "master"}, "armed": false, "monitoring": "auto"}}}
        command.apply {"command": {"type": "AddAutomationPoints", "target": {"kind": "device", "slot": 3, "index": 0}, "points": [{"tick": 0, "value": 0}, {"tick": 3840, "value": 1}]}}
        render.offline {"from": 0, "to": 3840, "path": "automation_vst3_again.wav", "tail": false, "blockSize": 480}
        """#
    }

    @Test("AUTO-009: a VST3 param lane reaches the plugin through IParameterChanges: again's gain follows the lane block by block; 0 RT violations")
    func vst3AgainLane() async throws {
        try buildTestPlugins()
        let path = VST3GoldenTests.repoRoot.appending(path: ".build/test-plugins/again.vst3").path
        let text = Self.vst3FixtureText(pluginIdentifier: "\(path)#84E8DE5F92554F5396FAE4133C935A18")
        let fixture = try GoldenFixture(name: "automation_vst3_again", text: text)
        let run = await GoldenHarness.run(fixture, reference: nil)
        defer { if run.failures.isEmpty { try? FileManager.default.removeItem(at: run.workDirectory) } }
        #expect(run.failures.isEmpty, "\(run.failures)")
        let audio = try AudioData(contentsOf: try #require(run.golden))
        #expect(audio.channels.count == 2 && audio.frameCount == 96_000)
        let centre = Double(Float(0.5.squareRoot())) * Double(Float(0.5.squareRoot()))
        let lane = Lane(points: [(0, 0), (3840, 1)])
        for channel in audio.channels {
            var worst = 0.0
            for f in 0..<96_000 {
                let blockStart = Int64(f / 480 * 480)
                let gain = Float(lane.value(Self.firstTick(blockStart)))  // again's fGain is a float
                worst = max(worst, abs(Double(channel[f]) - Double(gain) * centre))
            }
            #expect(worst <= Self.tolerance, "largest deviation \(worst)")
            #expect(channel[95_999] > 0.49, "the lane's end, 1.0, reached the plugin")
        }
    }
}
