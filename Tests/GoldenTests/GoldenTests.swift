import DAWControl
import DAWModel
import Foundation
import Testing

// TEST-001..004 (14-testing): golden fixtures (fixtures/*.jsonl) rendered in-process on the golden
// engine and compared with references/*.wav. See GoldenHarness for what a pass means and
// scripts/update-goldens.sh for regenerating a reference.

@Suite("Golden renders (TEST-001, TEST-002)")
struct GoldenRenderTests {
    @Test("TEST-001/002: renders null against its reference (≤ −100 dBFS) with 0 RT violations",
          arguments: GoldenHarness.fixtureNames())
    @MainActor func golden(_ name: String) async {
        let failures = await GoldenHarness.check(name, update: GoldenHarness.namesToUpdate.contains(name))
        for failure in failures { Issue.record(Comment(rawValue: failure)) }
    }

    @Test("TEST-002: every fixture has a reference and every reference a fixture")
    func referencesMatchFixtures() {
        let fixtures = Set(GoldenHarness.fixtureNames())
        #expect(!fixtures.isEmpty)
        let references = Set(GoldenHarness.referenceNames())
        let updating = GoldenHarness.namesToUpdate
        #expect(fixtures.subtracting(references).subtracting(updating).sorted() == [],
                "no reference yet: run scripts/update-goldens.sh <name>")
        #expect(references.subtracting(fixtures).sorted() == [], "a reference without a fixture")
    }

    @Test("TEST-003: update-goldens names only existing fixtures")
    func updateNamesExist() {
        #expect(GoldenHarness.namesToUpdate.subtracting(GoldenHarness.fixtureNames()).sorted() == [])
    }
}

@Suite("Golden references (ENG-022, MIX-004/005/007/021/023)")
struct GoldenReferenceTests {
    /// The reference itself shows the spec's ramp, so a regenerated reference can't hide a
    /// broken smoother: silence before block 25 (frame 12800, where the lane steps to unity),
    /// block 25 is 0.5 · (i + 1) / 512, everything after is 0.5. (T-089: the step is inside the
    /// render now; DW-063 resets every node before a render.)
    @Test("ENG-022: gain_ramp_smoothing's gain step 0 → 1 is a linear ramp over one block")
    func gainRampIsLinearOverOneBlock() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("gain_ramp_smoothing"))
        #expect(audio.sampleRate == 48000)
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == 24000)
        for channel in audio.channels {
            var worst = 0.0
            for (i, x) in channel.enumerated() {
                let expected = Self.stepRamp(i, full: 0.5)
                worst = max(worst, abs(Double(x) - expected))
            }
            #expect(worst < 1e-6)
        }
    }

    /// gain_ramp_smoothing and send_ramps: 0 before block 25 (frames 12800..<13312), a linear
    /// ramp to `full` over it, `full` after.
    static func stepRamp(_ i: Int, full: Double) -> Double {
        let start = 25 * 512
        if i < start { return 0 }
        return i < start + 512 ? full * Double(i - start + 1) / 512 : full
    }

    /// MIX-005 constant power: whatever the pan, L² + R² of the tone through both strips is
    /// ½ · tone² (track law cos²θ + sin²θ = 1, master centre √½ per side). Checked per sample in
    /// all five 12000-frame segments (pan −1, −0.5, 0, +0.5, +1).
    @Test("MIX-005: pan_law's L² + R² is the same at every pan position")
    func panLawIsConstantPower() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("pan_law"))
        #expect(audio.sampleRate == 48000)
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == 60000)
        guard audio.channels.count == 2, audio.frameCount == 60000 else { return }
        let (l, r) = (audio.channels[0], audio.channels[1])
        for segment in 0..<5 {
            var worst = 0.0
            for n in 0..<12000 {
                let i = segment * 12000 + n
                let tone = 0.5 * sin(2 * Double.pi * 1000 * Double(n) / 48000)
                let power = Double(l[i]) * Double(l[i]) + Double(r[i]) * Double(r[i])
                worst = max(worst, abs(power - 0.5 * tone * tone))
            }
            #expect(worst < 1e-6, "segment \(segment)")
        }
    }

    /// MIX-004/007: each 12000-frame segment of bus_send_sum is the tone times the factors its
    /// fixture derives: post-fader follows gain 0.5 and pan −1, pre-fader ignores them, both
    /// sum in FX, and a muted track's pre- and post-fader sends are silent.
    @Test("MIX-004/007: bus_send_sum's sends tap pre/post fader, sum in the bus, and mute with the track")
    func busSendSumSamples() throws {
        // Gains from the clip to the output (the fixture's levels ÷ the tone's 0.5).
        try expectToneSegments("bus_send_sum", [(0.25, 0), (0.25, 0.25), (0.5, 0.25), (0, 0)])
    }

    /// MIX-007/ENG-022: a send level step 0 → 1 on a post-fader (L) and a pre-fader send (R)
    /// ramps linearly over block 25, then holds. (T-089: automation steps inside the render;
    /// the send-mute ramp is checked by the C++ SendTests.)
    @Test("MIX-007: send_ramps' send level steps ramp linearly over one block")
    func sendRampsAreLinearOverOneBlock() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("send_ramps"))
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == 24000)
        guard audio.channels.count == 2 else { return }
        for (channel, full) in zip(audio.channels, [0.5, 0.5.squareRoot()]) {
            var worst = 0.0
            for (i, x) in channel.enumerated() {
                let expected = Self.stepRamp(i, full: full)
                worst = max(worst, abs(Double(x) - expected))
            }
            #expect(worst < 1e-6)
        }
    }

    /// MIX-021/023, exact to the sample: L (dry + phase-inverted 1000-frame latent copy) is 0
    /// everywhere; R is the click at frame 0 (0.5), then the 300-frame latent tone starting at
    /// frame 12000 exactly (0.5 × tone), and nothing else.
    @Test("MIX-021/023: pdc_alignment_null nulls L and keeps the click and tone on their samples")
    func pdcAlignmentSamples() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("pdc_alignment_null"))
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == 36000)
        guard audio.channels.count == 2, audio.frameCount == 36000 else { return }
        #expect(audio.channels[0].allSatisfy { abs($0) < 1e-6 })
        let r = audio.channels[1]
        #expect(abs(Double(r[0]) - 0.5) < 1e-6)
        var worst = 0.0
        for i in 1..<36000 {
            let n = i - 12000
            let expected = (0..<12000).contains(n) ? 0.5 * 0.5 * sin(2 * Double.pi * 1000 * Double(n) / 48000) : 0
            worst = max(worst, abs(Double(r[i]) - expected))
        }
        #expect(worst < 1e-6)
    }

    /// The alignment above only means something if the latent inserts are really in the graph:
    /// the golden engine reports a graph latency of 1000 (delay) + 500 (Master FX compressor).
    @Test("MIX-020/023: pdc_alignment_null renders with a graph latency of 1500 frames")
    @MainActor func pdcGraphLatency() async throws {
        let fixture = try GoldenFixture(name: "pdc_alignment_null", contentsOf:
            GoldenHarness.fixturesDirectory.appending(path: "pdc_alignment_null.jsonl"))
        let run = await GoldenHarness.run(fixture, reference: nil)
        #expect(run.failures == [])
        #expect(run.telemetry?["graphLatency"]?.int64Value == 1500)
        if run.failures.isEmpty { try? FileManager.default.removeItem(at: run.workDirectory) }
    }

    /// PLUG-018 (T-064), exact to the sample: L (a bypassed 1000-frame latent device against a plain
    /// phase-inverted copy) is 0 everywhere; R is only the reference tone (0.5 × the centre pan's
    /// 0.7071) from frame 0, so the running latent device next to it really was silent.
    @Test("PLUG-018: plugin_bypass_null nulls the bypassed latent path; the running one is silent")
    func pluginBypassNullSamples() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("plugin_bypass_null"))
        #expect(audio.channels.count == 2 && audio.frameCount == 36000)
        guard audio.channels.count == 2, audio.frameCount == 36000 else { return }
        #expect(audio.channels[0].allSatisfy { $0 == 0 })
        var worst = 0.0
        for i in 0..<36000 {
            let expected = i < 12000 ? 0.5 * 0.5.squareRoot() * sin(2 * Double.pi * 1000 * Double(i) / 48000) : 0
            worst = max(worst, abs(Double(audio.channels[1][i]) - expected))
        }
        #expect(worst < 1e-6)
    }

    /// The null above means something only because PDC planned with the bypassed device's latency.
    @Test("PLUG-018: plugin_bypass_null renders with a graph latency of 1000 frames (bypass keeps PDC)")
    @MainActor func pluginBypassGraphLatency() async throws {
        let fixture = try GoldenFixture(name: "plugin_bypass_null", contentsOf:
            GoldenHarness.fixturesDirectory.appending(path: "plugin_bypass_null.jsonl"))
        let run = await GoldenHarness.run(fixture, reference: nil)
        #expect(run.failures == [])
        #expect(run.telemetry?["graphLatency"]?.int64Value == 1000)
        if run.failures.isEmpty { try? FileManager.default.removeItem(at: run.workDirectory) }
    }

    /// The reference is `[(left, right)]` gains × the 1 kHz tone at 0.5 (`assets/tone_1k_48k.wav`),
    /// one 12000-frame segment per factor pair, with the tone restarting in each segment.
    private func expectToneSegments(_ name: String, _ factors: [(Double, Double)],
                                    sourceLocation: SourceLocation = #_sourceLocation) throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference(name))
        #expect(audio.channels.count == 2, sourceLocation: sourceLocation)
        #expect(audio.frameCount == factors.count * 12000, sourceLocation: sourceLocation)
        guard audio.channels.count == 2, audio.frameCount == factors.count * 12000 else { return }
        for (segment, (left, right)) in factors.enumerated() {
            var worst = 0.0
            for n in 0..<12000 {
                let tone = 0.5 * sin(2 * Double.pi * 1000 * Double(n) / 48000)
                let i = segment * 12000 + n
                worst = max(worst, abs(Double(audio.channels[0][i]) - left * tone),
                            abs(Double(audio.channels[1][i]) - right * tone))
            }
            #expect(worst < 1e-6, "segment \(segment)", sourceLocation: sourceLocation)
        }
    }
}

@Suite("Golden harness (TEST-001..003)")
@MainActor struct GoldenHarnessTests {
    static let sine = """
        # @node {"kind": "audioClipPlayer", "type": "sine", "frequency": 1000, "level": 1}
        project.new {"name": "t"}
        command.apply {"command": {"type": "AddTrack", "name": "Sine", "kind": "audio"}}
        render.offline {"from": 0, "to": 480, "path": "t.wav", "tail": false}
        """

    @Test("TEST-001: @node/@expect directives parse; dawctl reads them as comments")
    func directives() throws {
        let fixture = try GoldenFixture(name: "t", text: Self.sine + """

            # @expect {"field": "peakDb", "value": -6, "tolerance": 0.1, "range": {"start": 0, "end": 10}}
            // @node is only a directive after "# "
            """)
        #expect(fixture.script.lines.map(\.request.method) == ["project.new", "command.apply", "render.offline"])
        #expect(fixture.testNodes == [.init(kind: .audioClipPlayer, type: .sine, frequency: 1000, level: 1)])
        #expect(fixture.expectations.first?.range == FrameRange(start: 0, end: 10))
        #expect(throws: GoldenFixture.ParseError.self) { try GoldenFixture(name: "t", text: "# @nodes {}") }
        #expect(throws: GoldenFixture.ParseError.self) { try GoldenFixture(name: "t", text: "# @node {\"kind\": \"eq\"}") }
        #expect(throws: GoldenFixture.ParseError.self) {
            try GoldenFixture(name: "t", text: """
                # @node {"kind": "eq", "type": "nan"}
                # @node {"kind": "eq", "type": "fakeLatency", "samples": 4}
                """)
        }
    }

    @Test("TEST-004: the golden engine renders the fixture's test node through the real graph")
    func testNodeReachesTheRender() async throws {
        let run = await GoldenHarness.run(try GoldenFixture(name: "t", text: Self.sine), reference: nil)
        #expect(run.failures == [])
        let audio = try AudioData(contentsOf: try #require(run.golden))
        #expect(audio.frameCount == 12000)
        // Two centre-pan strips: 0.5 · sin(2π · 1000 · n / 48000).
        var worst = 0.0
        for (n, x) in audio.channels[0].enumerated() {
            let expected = 0.5 * sin(2 * Double.pi * 1000 * Double(n) / 48000)
            worst = max(worst, abs(Double(x) - expected))
        }
        #expect(worst < 1e-6)
        try? FileManager.default.removeItem(at: run.workDirectory)
    }

    @Test("TEST-002: a render that doesn't null against its reference fails, and says by how much")
    func mismatchFails() async throws {
        let fixture = try GoldenFixture(name: "t", text: Self.sine)
        let run = await GoldenHarness.run(fixture, reference: GoldenHarness.reference("gain_ramp_smoothing"))
        #expect(run.failures.count == 1)
        #expect(run.failures.first?.contains("null residual") == true)
        #expect(try #require(run.comparison).nullResidualDb > GoldenHarness.toleranceDb)
        try? FileManager.default.removeItem(at: run.workDirectory)
    }

    @Test("TEST-003: a missing reference fails and names scripts/update-goldens.sh")
    func missingReferenceFails() async throws {
        let fixture = try GoldenFixture(name: "t", text: Self.sine)
        let run = await GoldenHarness.run(fixture, reference: GoldenHarness.reference("no_such_fixture"))
        #expect(run.failures.count == 1)
        #expect(run.failures.first?.contains("scripts/update-goldens.sh t") == true)
        try? FileManager.default.removeItem(at: run.workDirectory)
    }

    @Test("TEST-001: a failing line, a fixture without a render and a missed @expect all fail")
    func scriptFailures() async throws {
        let bad = try GoldenFixture(name: "t", text: """
            project.new {"name": "t"}
            command.apply {"command": {"type": "NoSuchCommand"}}
            """)
        let badRun = await GoldenHarness.run(bad, reference: nil)
        #expect(badRun.failures.first?.hasPrefix("t.jsonl:2 command.apply failed") == true)

        let noRender = try GoldenFixture(name: "t", text: #"project.new {"name": "t"}"#)
        #expect(await GoldenHarness.run(noRender, reference: nil).failures.first?.contains("never calls render.offline") == true)

        let missed = try GoldenFixture(name: "t", text: Self.sine + """

            # @expect {"field": "peakDb", "value": 0, "tolerance": 0.5}
            """)
        let missedRun = await GoldenHarness.run(missed, reference: nil)
        #expect(missedRun.failures.count == 1)
        #expect(missedRun.failures.first?.contains("@expect peakDb") == true)
        for run in [badRun, missedRun] { try? FileManager.default.removeItem(at: run.workDirectory) }
    }

    /// A hard-left pan (MIX-005) is loud on L and silent on R: `"channel"` checks one channel only.
    static let hardLeft = Self.sine.replacingOccurrences(of: "render.offline", with: """
        command.apply {"command": {"type": "SetParam", "target": {"kind": "strip", "channel": 2, "param": "pan"}, "value": -1}}
        render.offline
        """)

    @Test("TEST-001: @expect \"channel\" checks one channel; out of range or on a scalar field fails")
    func expectChannel() async throws {
        // L = sin · cos 0 · √½ → −3.01 dBFS; R silent (−240, the analyzer's floor).
        let pass = try GoldenFixture(name: "t", text: Self.hardLeft + """

            # @expect {"field": "peakDb", "value": -3.01, "tolerance": 0.01, "channel": 0}
            # @expect {"field": "peakDb", "value": -240, "tolerance": 1, "channel": 1}
            """)
        #expect(pass.expectations.map(\.channel) == [0, 1])
        let passRun = await GoldenHarness.run(pass, reference: nil)
        #expect(passRun.failures == [])

        // Without "channel" the same value must hold on both channels, so R fails it.
        let both = try GoldenFixture(name: "t", text: Self.hardLeft + """

            # @expect {"field": "peakDb", "value": -3.01, "tolerance": 0.01}
            """)
        let bothRun = await GoldenHarness.run(both, reference: nil)
        #expect(bothRun.failures.count == 1)

        let bad = try GoldenFixture(name: "t", text: Self.hardLeft + """

            # @expect {"field": "peakDb", "value": -3.01, "tolerance": 0.01, "channel": 2}
            # @expect {"field": "frames", "value": 12000, "channel": 0}
            """)
        let badRun = await GoldenHarness.run(bad, reference: nil)
        #expect(badRun.failures.count == 2)
        #expect(badRun.failures.first?.contains("no channel 2 (2 channels)") == true)
        #expect(badRun.failures.last?.contains("frames is not a per-channel field") == true)
        for run in [passRun, bothRun, badRun] { try? FileManager.default.removeItem(at: run.workDirectory) }
    }
}
