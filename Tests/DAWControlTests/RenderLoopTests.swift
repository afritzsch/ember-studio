import DAWControl
import DAWModel
import Foundation
import Testing

// T-036: `render.offline {loop: true}` reaches the real offline engine (ExportSpec.followLoop),
// and leaving it out keeps today's straight-through render.

@Suite("render.offline loop (T-036, TIME-005)")
@MainActor
struct RenderLoopTests {
    @Test("T-036: render.offline loop: true wraps at the transport's loop end; the default plays straight through")
    func loopFollowsTransport() async throws {
        let dir = try TempDir()
        try TestAudio.write([TestAudio.sine(frequency: 441, amplitude: 0.5, sampleRate: 48_000, frames: 48_000)],
                            sampleRate: 48_000, to: dir.file("tone.wav"))
        // IDs: master 1, asset 2, track 3. Loop [100, 490) ticks = samples [2500, 12250).
        let script = try ControlScript(parsing: """
            project.new {"name": "loop", "sampleRate": 48000}
            asset.import {"path": "tone.wav"}
            command.apply {"command": {"type": "AddTrack", "name": "Tone", "kind": "audio"}}
            command.apply {"command": {"type": "AddClip", "trackID": 3, "assetID": 2, "start": 0}}
            transport.setLoop {"enabled": true, "start": 100, "end": 490}
            render.offline {"from": 0, "to": 960, "path": "looped.wav", "tail": false, "loop": true}
            render.offline {"from": 0, "to": 960, "path": "default.wav", "tail": false}
            render.offline {"from": 0, "to": 960, "path": "straight.wav", "tail": false, "loop": false}
            """)
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        for line in script.lines {
            let response = try #require(await dispatcher.handle(line.request))
            #expect(response.error == nil, "line \(line.number): \(response.error?.message ?? "")")
            if line.request.method == "render.offline" {
                #expect(response.result?["frames"] == 24_000)
                #if DEBUG
                #expect(response.result?["rtViolations"] == 0)
                #endif
            }
        }

        let looped = try AudioData(contentsOf: dir.file("looped.wav")).channels[0]
        let plain = try AudioData(contentsOf: dir.file("default.wav")).channels[0]
        let straight = try AudioData(contentsOf: dir.file("straight.wav")).channels[0]
        #expect(plain == straight, "loop: false is the default")
        #expect(looped.count == 24_000 && plain.count == 24_000)
        guard looped.count == 24_000, plain.count == 24_000 else { return }
        // Up to the loop end both play the clip from tick 0.
        #expect(Array(looped[..<12_250]) == Array(plain[..<12_250]))
        // Past the 64-frame wrap crossfade, the looped render replays the loop from 2500.
        var worst: Float = 0
        for i in (12_250 + 64)..<(12_250 + 9_750) {
            worst = max(worst, abs(looped[i] - plain[i - 12_250 + 2_500]))
        }
        #expect(worst < 1e-6)
        // And it isn't what the straight render plays there.
        #expect(looped[12_250 + 100] != plain[12_250 + 100])
    }
}
