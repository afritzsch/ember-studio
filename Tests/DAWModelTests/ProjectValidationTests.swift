import DAWModel
import Foundation
import Testing

// MODEL-032 and DW-031: Project.validate(), the Debug hook in UndoStack, and the ID allocator on
// decoding.

@Suite("Project validation")
struct ProjectValidationTests {
    init() { TestCommands.register() }

    let p = RoutingProject.make()

    private func expectInvalid(
        _ error: DAWError, sourceLocation: SourceLocation = #_sourceLocation, _ edit: (inout Project) -> Void
    ) {
        var q = p
        edit(&q)
        #expect(throws: error, sourceLocation: sourceLocation) { try q.validate() }
    }

    @Test("MODEL-032: fixture and test projects are valid")
    @MainActor
    func validProjects() throws {
        try p.validate()
        try Project().validate()
        for name in GraphFixtures.names { try GraphFixtures.project(named: name).validate() }
        try SyncCostTests.largeProject().validate()
    }

    @Test("MODEL-032, DW-094: IDs are unique, in 1…maxModelID and below the allocator's next")
    func ids() {
        let vox = p.vox.id
        expectInvalid(.brokenInvariant("send id \(vox) is used twice")) { $0.tracks[1].sends[0].id = vox }
        expectInvalid(.brokenInvariant("track id \(vox) is used twice")) { $0.tracks[1].id = vox }
        expectInvalid(.brokenInvariant("device slot id 0 is outside 1…\(GraphNodeID.maxModelID)")) { $0.master.inserts[0].id = 0 }
        let big = GraphNodeID.maxModelID + 1
        expectInvalid(.brokenInvariant("bus id \(big) is outside 1…\(GraphNodeID.maxModelID)")) {
            // Retarget everything at the bus so only the ID is wrong.
            $0.buses[1].id = big
            $0.tracks[0].sends[0].target = big
        }
        let next = p.ids.next
        expectInvalid(.brokenInvariant("asset id \(next) is not below the allocator's next id \(next)")) {
            $0.assets = [AssetRef(id: next, path: "a.wav", channels: 1, originalSampleRate: 48_000, frames: 1)]
        }
    }

    @Test("MODEL-032: routing references exist and the routing is acyclic")
    func routing() {
        expectInvalid(.brokenInvariant("channel \(p.kick.id) outputs to missing bus 999")) { $0.tracks[1].output = .bus(999) }
        expectInvalid(.brokenInvariant("send \(p.vox.sends[0].id) targets missing bus \(p.vox.id)")) { $0.tracks[0].sends[0].target = p.vox.id }
        expectInvalid(.brokenInvariant("device slot \(p.master.inserts[0].id) has sidechain source \(p.master.id), which is no track or bus")) {
            $0.master.inserts[0].sidechainSource = SidechainRef(source: $0.master.id)
        }
        expectInvalid(.routingCycle(path: [p.a.id, p.b.id, p.a.id])) {
            $0.buses[0].output = .bus($0.buses[1].id)
            $0.buses[1].sends = [Send(id: $0.ids.allocate(), target: $0.buses[0].id)]
        }
        expectInvalid(.routingCycle(path: [p.vox.id, p.vox.id])) {
            $0.tracks[0].inserts[0].sidechainSource = SidechainRef(source: $0.tracks[0].id)
        }
    }

    @Test("MODEL-032: clips are non-negative and match the track; notes are sorted and in MIDI range")
    func clipsAndNotes() {
        let clip = AudioClip(id: 900, assetID: 0, start: 0, length: 960)
        func withClip(_ clip: Clip, kind: Track.Kind = .audio) -> (inout Project) -> Void {
            { $0.ids.reserve(1000); $0.tracks[1].kind = kind; $0.tracks[1].clips = [clip] }
        }
        expectInvalid(.brokenInvariant("clip 900 has start -1, length 960"), withClip(.audio(AudioClip(id: 900, assetID: 0, start: -1, length: 960))))
        expectInvalid(.brokenInvariant("clip 900 has start 0, length 0"), withClip(.audio(AudioClip(id: 900, assetID: 0, start: 0, length: 0))))
        var fade = clip
        fade.fadeOut = -1
        expectInvalid(.brokenInvariant("audio clip 900 has a negative offset or fade"), withClip(.audio(fade)))
        expectInvalid(.brokenInvariant("audio clip 900 on MIDI track \(p.kick.id)"), withClip(.audio(clip), kind: .midi))

        let notes = [Note(id: 901, start: 480, length: 10, pitch: 60), Note(id: 902, start: 0, length: 10, pitch: 62)]
        let midi = MidiClip(id: 900, start: 0, length: 960, notes: notes)
        expectInvalid(.brokenInvariant("MIDI clip 900 on audio track \(p.kick.id)"), withClip(.midi(midi)))
        expectInvalid(.brokenInvariant("notes of clip 900 are not sorted by start"), withClip(.midi(midi), kind: .midi))
        let loud = MidiClip(id: 900, start: 0, length: 960, notes: [Note(id: 901, start: 0, length: 10, pitch: 128)])
        expectInvalid(.brokenInvariant("note 901 has length 10, pitch 128, velocity 100, channel 0"), withClip(.midi(loud), kind: .midi))
    }

    @Test("MODEL-032: strip, send and device param values are in range")
    func ranges() {
        expectInvalid(.brokenInvariant("channel \(p.vox.id) gain 4.0 is outside 0…3.9810717")) { $0.tracks[0].strip.gain = 4 }
        expectInvalid(.brokenInvariant("channel \(p.master.id) pan nan is outside −1…1")) { $0.master.strip.pan = .nan }
        expectInvalid(.brokenInvariant("send \(p.kick.sends[0].id) level -1.0 is outside 0…3.9810717")) { $0.tracks[1].sends[0].level = -1 }
        let comp = p.vox.inserts[0].id
        expectInvalid(.brokenInvariant("device slot \(comp) has a bad or repeated param index 2")) {
            $0.tracks[0].inserts[0].params = [ParamValue(index: 2, value: 0), ParamValue(index: 2, value: 1)]
        }
        expectInvalid(.brokenInvariant("device slot \(comp) param 0 is not finite")) {
            $0.tracks[0].inserts[0].params = [ParamValue(index: 0, value: .infinity)]
        }
    }

    #if DEBUG
    @Test("MODEL-032, DW-031: in Debug, UndoStack rejects a command that leaves the project invalid")
    func debugHook() throws {
        var project = p
        var stack = UndoStack()
        var broken = p
        broken.buses[0].output = .bus(broken.buses[1].id)
        broken.buses[1].output = .bus(broken.buses[0].id)
        #expect(throws: DAWError.routingCycle(path: [p.a.id, p.b.id, p.a.id])) {
            try stack.perform(TestSetProject(project: broken), on: &project)
        }
        #expect(project == p && !stack.canUndo)
    }

    @Test("MODEL-032, DW-031: in Debug, the store reports the broken invariant and keeps its project")
    @MainActor
    func debugHookThroughStore() {
        let store = ProjectStore(project: p)
        var gain = p
        gain.tracks[0].strip.gain = 10
        #expect(throws: DAWError.brokenInvariant("channel \(p.vox.id) gain 10.0 is outside 0…3.9810717")) {
            try store.perform(TestSetProject(project: gain))
        }
        #expect(store.project == p && !store.isDirty && !store.canUndo)
    }
    #endif

    @Test("DW-031: decoding moves the ID allocator past the largest ID in the file")
    func decodingReservesIDs() throws {
        var stale = p
        stale.tracks[1].sends[0].id = 500
        stale.ids = IDAllocator(next: 3)  // as if hand-edited
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(stale))
        #expect(decoded.ids.next == 501)
        try decoded.validate()

        var next = decoded
        _ = try AddTrack(name: "New", kind: .audio).apply(to: &next)
        #expect(next.tracks.last?.id == 501, "a new entity never takes an ID in use")

        // A file whose allocator is already ahead keeps it.
        var ahead = p
        ahead.ids = IDAllocator(next: 10_000)
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(ahead)).ids.next == 10_000)
    }

    @Test("DW-031, DW-094: decoding rejects an ID in the NodeID role bits")
    func decodingRejectsHugeIDs() throws {
        var huge = p
        huge.assets = [AssetRef(id: UInt64.max, path: "a.wav", channels: 1, originalSampleRate: 48_000, frames: 1)]
        let data = try JSONEncoder().encode(huge)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Project.self, from: data) }
    }
}
