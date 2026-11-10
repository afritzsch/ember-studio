import DAWModel
import Foundation

// Fixture projects for the GraphDescriptionBuilder snapshot tests (MODEL-020). Routing commands
// don't exist yet (T-022/T-030), so projects are put together directly. Each is also committed as
// JSON under Tests/Fixtures/projects/ (the snapshot tests build from that file, and check it still
// decodes to the project defined here); snapshots live in Tests/Fixtures/graph_snapshots/.
//
// To regenerate both after an intended change: DAW_RECORD_SNAPSHOTS=1 swift test --filter GraphDescriptionBuilder
// and explain the change in the commit.

enum GraphFixtures {
    static let names = ["empty", "audio_tracks", "routing", "midi_tempo"]

    static func project(named name: String) throws -> Project {
        switch name {
        case "empty": return empty()
        case "audio_tracks": return audioTracks()
        case "routing": return routing()
        case "midi_tempo": return try midiTempo()
        default: fatalError("no fixture \(name)")
        }
    }

    static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static let fixedID = UUID(uuidString: "00000000-0000-0000-0000-000000000016")!

    /// Just the master.
    static func empty() -> Project {
        Project(id: fixedID, name: "empty")
    }

    /// Two audio tracks with clips, straight to the master.
    static func audioTracks() -> Project {
        var p = Project(id: fixedID, name: "audio_tracks")
        let asset = p.ids.allocate()
        p.assets = [AssetRef(id: asset, path: "Audio/loop.wav", channels: 2, originalSampleRate: 48_000, frames: 96_000)]
        let a = p.ids.allocate()
        let b = p.ids.allocate()
        let clips: [Clip] = [
            .audio(AudioClip(id: p.ids.allocate(), assetID: asset, start: 0, length: 3840)),
            .audio(AudioClip(id: p.ids.allocate(), assetID: asset, start: 3840, length: 1920, sourceOffsetSamples: 24_000,
                             gain: 0.5, fadeIn: 120, fadeOut: 240)),
        ]
        p.tracks = [
            Track(id: a, name: "Drums", kind: .audio, clips: clips, strip: ChannelStripState(gain: 0.8, pan: -0.25)),
            Track(id: b, name: "Empty", kind: .audio),
        ]
        return p
    }

    /// Tracks → bus chain, pre- and post-fader sends, inserts (one bypassed), a sidechain, master inserts.
    ///
    ///   Vox (eq, comp[sidechain ← Kick pre]) → Group → Main → master; Vox post-send → Verb
    ///   Kick → master; Kick pre-send → Verb
    ///   Verb (reverb) → master
    ///   Group (comp bypassed) → Main;  Main (eq) → master
    ///   master (delay) → out
    static func routing() -> Project {
        var p = Project(id: fixedID, name: "routing")
        let vox = p.ids.allocate()
        let kick = p.ids.allocate()
        let group = p.ids.allocate()
        let main = p.ids.allocate()
        let verb = p.ids.allocate()
        let voxEQ = p.ids.allocate()
        let voxComp = p.ids.allocate()
        let groupComp = p.ids.allocate()
        let mainEQ = p.ids.allocate()
        let verbRev = p.ids.allocate()
        let masterDelay = p.ids.allocate()
        let voxSend = p.ids.allocate()
        let kickSend = p.ids.allocate()

        p.tracks = [
            Track(id: vox, name: "Vox", kind: .audio,
                  inserts: [
                      DeviceSlot(id: voxEQ, kind: .builtin(.eq), params: [ParamValue(index: 0, value: 0.3)]),
                      DeviceSlot(id: voxComp, kind: .builtin(.compressor),
                                 sidechainSource: SidechainRef(source: kick, tap: .preFader)),
                  ],
                  sends: [Send(id: voxSend, target: verb, level: 0.5, tap: .postFader)],
                  output: .bus(group)),
            Track(id: kick, name: "Kick", kind: .audio,
                  sends: [Send(id: kickSend, target: verb, level: 0.25, tap: .preFader)]),
        ]
        p.buses = [
            Bus(id: group, name: "Group",
                inserts: [DeviceSlot(id: groupComp, kind: .builtin(.compressor), bypass: true)],
                output: .bus(main)),
            Bus(id: main, name: "Main", inserts: [DeviceSlot(id: mainEQ, kind: .builtin(.eq))]),
            Bus(id: verb, name: "Verb", inserts: [DeviceSlot(id: verbRev, kind: .builtin(.reverb))]),
        ]
        p.master.inserts = [DeviceSlot(id: masterDelay, kind: .builtin(.delay))]
        return p
    }

    /// MIDI tracks (one with a sampler, one without an instrument), notes trimmed by the clip,
    /// and a tempo/time-signature change.
    static func midiTempo() throws -> Project {
        var p = Project(id: fixedID, name: "midi_tempo")
        try p.setTempoMap(
            tempoEvents: [TempoEvent(tick: 0, bpm: 120), TempoEvent(tick: 7680, bpm: 90)],
            timeSignatures: [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4),
                             TimeSignatureEvent(tick: 7680, numerator: 3, denominator: 4)])
        let keys = p.ids.allocate()
        let bare = p.ids.allocate()
        let sampler = p.ids.allocate()
        let clipID = p.ids.allocate()
        let notes = [
            Note(id: p.ids.allocate(), start: 0, length: 480, pitch: 60),
            Note(id: p.ids.allocate(), start: 480, length: 480, pitch: 64, velocity: 80, channel: 1),
            // Runs past the clip end (1920): trimmed to 240 ticks.
            Note(id: p.ids.allocate(), start: 1680, length: 960, pitch: 67),
            // Starts after the clip end: dropped.
            Note(id: p.ids.allocate(), start: 2000, length: 100, pitch: 72),
        ]
        p.tracks = [
            Track(id: keys, name: "Keys", kind: .midi,
                  clips: [.midi(MidiClip(id: clipID, start: 3840, length: 1920, notes: notes))],
                  instrument: DeviceSlot(id: sampler, kind: .builtin(.sampler))),
            Track(id: bare, name: "No instrument", kind: .midi,
                  clips: [.midi(MidiClip(id: p.ids.allocate(), start: 0, length: 960,
                                         notes: [Note(id: p.ids.allocate(), start: 0, length: 960, pitch: 40)]))]),
        ]
        return p
    }
}

extension RuntimeIDs {
    /// Slots handed out in NodeID order from 0, as a fresh engine would for an attach.
    static func sequential(for project: Project, catalog: ParamCatalog = ParamCatalog()) -> RuntimeIDs {
        var runtime = RuntimeIDs()
        var next: ParamID = 0
        let required = GraphDescriptionBuilder.paramRequirements(project, catalog: catalog)
        for (node, count) in required.sorted(by: { $0.key < $1.key }) {
            runtime.params[node] = .init(first: next, count: count)
            next += count
        }
        return runtime
    }
}

/// A text rendering of a graph for snapshots: one line per node, edge, clip and note, with
/// NodeIDs written as `<role>:<owner>` so a diff reads in model terms.
enum GraphSnapshot {
    static func name(_ node: NodeIDValue) -> String {
        let owner = GraphNodeID.owner(of: node)
        switch GraphNodeID.role(of: node) {
        case .entity: return "\(owner)"
        case .source: return "source:\(owner)"
        case .input: return "input:\(owner)"
        case .output: return "output:\(owner)"
        case .metronome: return "metronome:\(owner)"
        case .bypass: return "bypass:\(owner)"
        case nil: return "?\(node)"
        }
    }

    static func render(_ g: EngineGraph) -> String {
        var lines = ["master \(name(g.master))", "nodes:"]
        for n in g.nodes {
            var line = "  \(name(n.id)) \(n.kind.rawValue) v\(n.configVersion)"
            if n.numParams > 0 { line += " params \(n.firstParam)+\(n.numParams)" }
            if !n.configJSON.isEmpty { line += " config \(n.configJSON)" }
            if let bypass = n.bypassParam { line += " bypass \(bypass)" }  // PLUG-018
            lines.append(line)
        }
        lines.append("edges:")
        for e in g.edges {
            lines.append("  \(name(e.from)) -> \(name(e.to)) \(e.kind.rawValue) port \(e.toPort) id \(String(e.id, radix: 16))")
        }
        lines.append("clips:")
        for c in g.audioClips {
            lines.append("  \(name(c.player)) clip \(c.clipID) asset \(c.assetID) @\(c.start.raw)+\(c.length.raw)"
                + " offset \(c.sourceOffsetSamples) gain \(c.gain) fades \(c.fadeIn.raw)/\(c.fadeOut.raw)")
        }
        lines.append("notes:")
        for n in g.notes {
            lines.append("  \(name(n.player)) @\(n.start.raw)+\(n.length.raw) pitch \(n.pitch) vel \(n.velocity) ch \(n.channel)")
        }
        lines.append("tempo:")
        for t in g.tempoEvents { lines.append("  @\(t.tick.raw) \(t.bpm) bpm") }
        for s in g.timeSignatures { lines.append("  @\(s.tick.raw) \(s.numerator)/\(s.denominator)") }
        return lines.joined(separator: "\n") + "\n"
    }
}
