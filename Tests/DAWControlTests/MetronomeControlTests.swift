import DAWControl
import DAWModel
import Foundation
import Testing

// T-026: the project metronome through the control protocol. `transport.setMetronome` performs
// SetMetronome (TIME-010, not undoable), and `render.offline` leaves the click out unless
// `includeMetronome: true` (docs/autobuild/DECISIONS.md T-026 Q1).

@Suite("Project metronome control (TIME-010, T-026)")
@MainActor
struct MetronomeControlTests {
    @Test("TIME-010: transport.setMetronome sets the project's metronome, outside undo history, as slot writes")
    func setMetronome() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        #expect(await dispatcher.failure(.transportSetMetronome, ["enabled": true])?.dawError == "noProject")
        _ = try await dispatcher.ok(.projectNew, ["name": "m"])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "T", "kind": "audio"]])
        box.last.clearCalls()

        let on = try await dispatcher.ok(.transportSetMetronome, ["enabled": true])
        #expect(on == ["enabled": true, "level": 0.25, "accent": 2])
        let levels = try await dispatcher.ok(.transportSetMetronome, ["level": 0.5, "accent": 1.5])
        #expect(levels == ["enabled": true, "level": 0.5, "accent": 1.5])
        #expect(try await dispatcher.ok(.projectGet, ["path": "/metronome"]) == levels)
        #expect(dispatcher.store?.isDirty == true)
        #expect(!box.last.calls.contains { if case .applyGraph = $0 { true } else { false } }, "MODEL-021: no rebuild")

        // Not undoable: undo takes back the AddTrack, the metronome stays.
        #expect(try await dispatcher.ok(.undo)["label"] == "Add Track")
        #expect(try await dispatcher.ok(.projectGet, ["path": "/metronome/enabled"]) == true)

        for bad: JSONValue in [[:], ["level": -1], ["accent": 4], ["enabled": true, "level": 100]] {
            #expect(await dispatcher.failure(.transportSetMetronome, bad)?.dawError == "invalidArgument", "\(bad.jsonString())")
        }
        #expect(await dispatcher.failure(.transportSetMetronome, ["enabled": "yes"])?.dawError == "invalidParams")
        #expect(try await dispatcher.ok(.projectGet, ["path": "/metronome"]) == levels, "failures change nothing")

        // The command works through command.apply too, and a composite can't carry it.
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "SetMetronome", "enabled": false]])
        #expect(try await dispatcher.ok(.projectGet, ["path": "/metronome/enabled"]) == false)
        let batch = await dispatcher.failure(.commandBatch, ["atomic": true, "commands": [["type": "SetMetronome", "enabled": true]]])
        #expect(batch?.dawError == "invalidArgument")
    }

    @Test("TIME-010 (DECISIONS.md Q1): render.offline holds the on slot at 0 for the render unless includeMetronome")
    func renderSuppression() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "m"])
        _ = try await dispatcher.ok(.transportSetMetronome, ["enabled": true])
        let sync = try #require(dispatcher.store?.engineSync)
        let master = try #require(dispatcher.store?.project.master.id)
        let on = try #require(sync.runtime.metronomeParam(master, ParamLayout.Metronome.on))

        func onWrites(around render: JSONValue) async throws -> [Float] {
            box.last.clearCalls()
            _ = try await dispatcher.ok(.renderOffline, render)
            var out: [Float] = []
            for call in box.last.calls {
                switch call {
                case .setParam(let id, let value) where id == on: out.append(value)
                case .renderOffline: out.append(-1)  // marks where the render ran
                default: break
                }
            }
            return out
        }
        #expect(try await onWrites(around: ["from": 0, "to": 960, "path": "a.wav"]) == [0, -1, 1], "default: left out")
        #expect(try await onWrites(around: ["from": 0, "to": 960, "path": "a.wav", "includeMetronome": false]) == [0, -1, 1])
        #expect(try await onWrites(around: ["from": 0, "to": 960, "path": "a.wav", "includeMetronome": true]) == [-1])
        #expect(box.last.getParam(on) == 1 && !sync.isMetronomeSuppressed)
    }

    @Test("TIME-010: real engine — clicks on every beat, accented downbeats, past mute and master fader; exports leave them out")
    func realRender() async throws {
        let dir = try TempDir()
        try TestAudio.write([TestAudio.sine(frequency: 441, amplitude: 0.5, sampleRate: 48_000, frames: 192_000)],
                            sampleRate: 48_000, to: dir.file("tone.wav"))
        // IDs: master 1, asset 2, track 3. 120 bpm 4/4 at 48 kHz: a beat every 24000 samples.
        // The track is soloed and then muted, and the master fader is down: only the click is left.
        let script = try ControlScript(parsing: """
            project.new {"name": "click", "sampleRate": 48000}
            asset.import {"path": "tone.wav"}
            command.apply {"command": {"type": "AddTrack", "name": "Tone", "kind": "audio"}}
            command.apply {"command": {"type": "AddClip", "trackID": 3, "assetID": 2, "start": 0}}
            command.apply {"command": {"type": "SetParam", "target": {"kind": "strip", "channel": 3, "param": "solo"}, "value": 1}}
            command.apply {"command": {"type": "SetParam", "target": {"kind": "strip", "channel": 3, "param": "mute"}, "value": 1}}
            command.apply {"command": {"type": "SetParam", "target": {"kind": "strip", "channel": 1, "param": "gain"}, "value": 0}}
            render.offline {"from": 0, "to": 7680, "path": "off.wav", "tail": false, "includeMetronome": true}
            transport.setMetronome {"enabled": true}
            render.offline {"from": 0, "to": 7680, "path": "with.wav", "tail": false, "includeMetronome": true}
            render.offline {"from": 0, "to": 7680, "path": "without.wav", "tail": false, "includeMetronome": false}
            render.offline {"from": 0, "to": 7680, "path": "default.wav", "tail": false}
            render.offline {"from": 0, "to": 7680, "path": "again.wav", "tail": false, "includeMetronome": true}
            """)
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        for line in script.lines {
            let response = try #require(await dispatcher.handle(line.request))
            #expect(response.error == nil, "line \(line.number): \(response.error?.message ?? "")")
            if line.request.method == "render.offline" {
                #expect(response.result?["frames"] == 192_000)
                #expect(response.result?["rtViolations"] == 0)
            }
        }

        let with = try AudioData(contentsOf: dir.file("with.wav"))
        #expect(with.channels.count == 2 && with.channels[0] == with.channels[1])
        let click = with.channels[0]
        guard click.count == 192_000 else { Issue.record("\(click.count) frames"); return }
        // A click's first sample is its amplitude: level 0.25 on beats, × accent 2 on downbeats.
        for beat in 0..<8 {
            let at = beat * 24_000
            #expect(click[at] == (beat % 4 == 0 ? 0.5 : 0.25), "beat \(beat) at \(at)")
            #expect(click[at - (beat == 0 ? 0 : 1)] == (beat == 0 ? 0.5 : 0), "nothing just before beat \(beat)")
            // 20 ms clicks: silence from 960 samples after the onset to the next beat.
            #expect(click[(at + 960)..<(at + 24_000)].allSatisfy { $0 == 0 }, "silence after beat \(beat)")
        }
        let peak = click.map(abs).max() ?? 0
        #expect(peak == 0.5)

        for name in ["off.wav", "without.wav", "default.wav"] {
            let data = try AudioData(contentsOf: dir.file(name))
            #expect(data.channels.allSatisfy { $0.count == 192_000 && $0.allSatisfy { $0 == 0 } }, "\(name) is silent")
        }
        // Suppression is undone after each export: the next one with the click is the same.
        #expect(try AudioData(contentsOf: dir.file("again.wav")).channels == with.channels)

        // A failed export lets go of the slot too: the next one with the click still has it.
        let failed = await dispatcher.failure(.renderOffline, ["from": 0, "to": 7680, "path": "bad.wav", "blockSize": 0])
        #expect(failed != nil && dispatcher.store?.engineSync?.isMetronomeSuppressed == false)
        _ = try await dispatcher.ok(.renderOffline, ["from": 0, "to": 7680, "path": "after.wav", "tail": false, "includeMetronome": true])
        #expect(try AudioData(contentsOf: dir.file("after.wav")).channels == with.channels)

        let telemetry = try await dispatcher.ok(.engineTelemetry)
        #expect(telemetry["rtViolations"] == 0)
    }
}
