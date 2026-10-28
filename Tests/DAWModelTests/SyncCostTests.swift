import DAWModel
import Foundation
import Testing

// DW-032: change detection diffs the whole project after every command and gesture step, and
// EngineSync rebuilds the graph to compare it. This measures what that costs per step on a large
// project and prints it (`swift test --filter DW-032`, add `-c release` for optimized numbers).
// The bound is loose on purpose: it catches an accidental blow-up, not a slow machine.

@Suite("Sync cost (DW-032)")
@MainActor
struct SyncCostTests {
    init() { TestCommands.register() }

    /// 128 audio tracks × 100 clips with two inserts and a send each, 8 FX buses, 16 MIDI tracks
    /// × 8 clips × 125 notes: 12 800 clips, 16 000 notes, ~460 graph nodes.
    static func largeProject() -> Project {
        var p = Project(name: "large")
        let asset = p.ids.allocate()
        p.assets = [AssetRef(id: asset, path: "Audio/a.wav", channels: 2, originalSampleRate: 48_000, frames: 480_000)]
        p.buses = (0..<8).map { i in
            Bus(id: p.ids.allocate(), name: "FX \(i)", inserts: [DeviceSlot(id: p.ids.allocate(), kind: .builtin(.reverb))])
        }
        for i in 0..<128 {
            let clips = (0..<100).map { c in
                Clip.audio(AudioClip(id: p.ids.allocate(), assetID: asset, start: Tick(Int64(c) * 3840), length: 3000))
            }
            p.tracks.append(Track(
                id: p.ids.allocate(), name: "Audio \(i)", kind: .audio, clips: clips,
                inserts: [DeviceSlot(id: p.ids.allocate(), kind: .builtin(.eq), params: [ParamValue(index: 0, value: 0.5)]),
                          DeviceSlot(id: p.ids.allocate(), kind: .builtin(.compressor))],
                sends: [Send(id: p.ids.allocate(), target: p.buses[i % 8].id, level: 0.3)]))
        }
        for i in 0..<16 {
            let clips = (0..<8).map { c in
                let notes = (0..<125).map { n in
                    Note(id: p.ids.allocate(), start: Tick(Int64(n) * 120), length: 100, pitch: UInt8(36 + n % 48))
                }
                return Clip.midi(MidiClip(id: p.ids.allocate(), start: Tick(Int64(c) * 15_360), length: 15_360, notes: notes))
            }
            p.tracks.append(Track(id: p.ids.allocate(), name: "MIDI \(i)", kind: .midi, clips: clips,
                                  instrument: DeviceSlot(id: p.ids.allocate(), kind: .builtin(.sampler))))
        }
        return p
    }

    /// Mean wall time of `body` over `steps` runs, in ms.
    private func measure(_ steps: Int, _ body: (Int) throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        let elapsed = try clock.measure { for i in 0..<steps { try body(i) } }
        let (s, atto) = elapsed.components
        return (Double(s) + Double(atto) / 1e18) * 1000 / Double(steps)
    }

    @Test("DW-032: per-step cost of change detection and engine sync on a large project")
    func largeProjectCost() throws {
        let project = Self.largeProject()
        let track = project.tracks[0].id
        let clip = project.tracks[0].clips[0].id
        let steps = 50

        var edited = project
        edited.tracks[0].strip.gain = 0.5
        let diff = measure(steps) { _ in _ = ProjectChange(cause: .perform, label: "x", from: project, to: edited) }
        let runtime = GraphDescriptionBuilder.paramRequirements(project, catalog: ParamCatalog()).count
        let build = measure(steps) { _ in _ = GraphDescriptionBuilder.build(project, runtime: RuntimeIDs()) }

        let bare = ProjectStore(project: project)
        bare.beginGesture("Fader")
        let bareStep = try measure(steps) { i in try bare.perform(TestSetGain(trackID: track, gain: Float(i) / 100)) }
        bare.endGesture()

        let store = ProjectStore(project: project)
        let engine = FakeEngine()
        let attach = try measure(1) { _ in try store.attachEngine(engine) }
        let sync = try #require(store.engineSync)

        store.beginGesture("Fader")
        let paramStep = try measure(steps) { i in try store.perform(TestSetGain(trackID: track, gain: Float(i) / 100)) }
        store.endGesture()
        #expect(!sync.hasPendingApply)

        store.beginGesture("Move Clip")
        let structuralStep = try measure(steps) { _ in try store.perform(TestNudgeClip(trackID: track, clipID: clip, delta: 1)) }
        store.endGesture()
        let flush = measure(1) { _ in sync.flush() }

        // EngineSync's own share, without the store's diff.
        var faded = store.project
        let syncParam = measure(steps) { i in
            faded.tracks[0].strip.gain = Float(i) / 50
            sync.update(to: faded)
        }
        let syncStructural = measure(steps) { i in
            if case .audio(var c) = faded.tracks[0].clips[0] { c.start = Tick(Int64(i)); faded.tracks[0].clips[0] = .audio(c) }
            sync.update(to: faded)
        }
        sync.flush()

        print("""
            DW-032: large project: \(project.tracks.count) tracks, \(project.buses.count) buses, \
            12800 clips, 16000 notes, \(sync.appliedGraph?.nodes.count ?? 0) nodes, \(runtime) param ranges
            DW-032: ProjectChange diff            \(String(format: "%.3f", diff)) ms/step
            DW-032: graph build                   \(String(format: "%.3f", build)) ms
            DW-032: perform, no engine            \(String(format: "%.3f", bareStep)) ms/step (fader)
            DW-032: perform + sync, param-only    \(String(format: "%.3f", paramStep)) ms/step (fader)
            DW-032: perform + sync, structural    \(String(format: "%.3f", structuralStep)) ms/step (clip drag)
            DW-032: EngineSync.update, param-only \(String(format: "%.3f", syncParam)) ms/step
            DW-032: EngineSync.update, structural \(String(format: "%.3f", syncStructural)) ms/step
            DW-032: flush (bump + applyGraph)     \(String(format: "%.3f", flush)) ms
            DW-032: attach (alloc + write + apply) \(String(format: "%.3f", attach)) ms
            """)
        #expect(paramStep < 250 && structuralStep < 500 && syncParam < 100, "an accidental blow-up, not a tuning target")
    }
}
