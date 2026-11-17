import Foundation
import Testing

@testable import DAWModel

// T-080 model side: take folders (REC-030/031), CreateTakeFolder and SetCompSelection (MODEL-005,
// REC-033), loop takes imported in the "Record" composite (REC-030, REC-034), and the comp flattened
// into clips with 64-sample crossfade overlaps (REC-032).

/// 48 kHz, 120 bpm (one tick = 25 samples). An audio track "Mic", a MIDI track "Keys" and a long
/// recorded asset.
private enum TakeProject {
    static func make() -> Project {
        var p = Project(id: GraphFixtures.fixedID, name: "takes")
        let asset = p.ids.allocate()
        p.assets = [AssetRef(id: asset, path: "Audio/Recordings/Track 2 Take 1.caf", channels: 2,
                             originalSampleRate: 48_000, frames: 133_120)]
        p.tracks = [
            Track(id: p.ids.allocate(), name: "Mic", kind: .audio),
            Track(id: p.ids.allocate(), name: "Keys", kind: .midi),
        ]
        return p
    }
}

private extension Project {
    var micTrack: Track { tracks[0] }
    var keysTrack: Track { tracks[1] }
    var takeAsset: ModelID { assets[0].id }
}

@Suite("Take folders and comping (REC-030..034, MODEL-005)")
@MainActor
struct TakeFolderTests {
    init() { TestCommands.register() }

    let p = TakeProject.make()

    /// Three passes of the loop [0, 1920): two whole, the last ends at tick 960.
    var threeTakes: CreateTakeFolder {
        CreateTakeFolder(trackID: p.micTrack.id, takes: [
            .init(start: 0, length: 1920, assetID: p.takeAsset, sourceOffsetSamples: 0),
            .init(start: 0, length: 1920, assetID: p.takeAsset, sourceOffsetSamples: 48_000),
            .init(start: 0, length: 960, assetID: p.takeAsset, sourceOffsetSamples: 96_000),
        ])
    }

    func withFolder() throws -> (project: Project, folder: TakeFolder) {
        var q = p
        _ = try threeTakes.applyChecked(to: &q)
        return (q, try #require(q.micTrack.takeFolders.first))
    }

    // MARK: MODEL-005 CreateTakeFolder, REC-031 default comp

    @Test("MODEL-005, REC-030/031: CreateTakeFolder makes takes as clip views with new IDs; the default comp plays the latest take covering each position; round trip")
    func createAudio() throws {
        let next = p.ids.next
        let q = try expectApplyRoundTrip(threeTakes, on: p)
        let folder = try #require(q.micTrack.takeFolders.first)
        #expect(folder.id == next)
        #expect(folder.takes.map(\.id) == [next + 1, next + 3, next + 5])
        #expect(folder.takes.map(\.clip.id) == [next + 2, next + 4, next + 6])
        #expect(folder.start == 0 && folder.end == 1920)
        guard case .audio(let second) = folder.takes[1].clip else { Issue.record("not audio"); return }
        #expect(second.assetID == p.takeAsset && second.sourceOffsetSamples == 48_000 && second.length == 1920)
        // The partial last pass where it exists, the pass before it after that.
        #expect(folder.comp == [CompSegment(start: 0, end: 960, take: next + 5),
                                CompSegment(start: 960, end: 1920, take: next + 3)])
        #expect(q.micTrack.clips.isEmpty, "takes aren't track clips")
        #expect(q.clip(next + 2) == nil, "clip commands don't find take clips")
    }

    @Test("REC-031: the folder spans the takes' union; a first pass that began before the loop plays alone there")
    func defaultCompBeforeLoop() throws {
        var q = p
        _ = try CreateTakeFolder(trackID: p.micTrack.id, takes: [
            .init(start: 480, length: 1440, assetID: p.takeAsset),
            .init(start: 960, length: 960, assetID: p.takeAsset, sourceOffsetSamples: 36_000),
            .init(start: 960, length: 100, assetID: p.takeAsset, sourceOffsetSamples: 60_000),
        ]).applyChecked(to: &q)
        let folder = try #require(q.micTrack.takeFolders.first)
        let t = folder.takes.map(\.id)
        #expect(folder.start == 480 && folder.end == 1920)
        #expect(folder.comp == [CompSegment(start: 480, end: 960, take: t[0]), CompSegment(start: 960, end: 1060, take: t[2]),
                                CompSegment(start: 1060, end: 1920, take: t[1])])
    }

    @Test("MODEL-005, REC-034: a MIDI take folder holds the passes' notes with new IDs, sorted; round trip")
    func createMidi() throws {
        let next = p.ids.next
        let q = try expectApplyRoundTrip(CreateTakeFolder(trackID: p.keysTrack.id, takes: [
            .init(start: 0, length: 1920, notes: [AddNotes.NoteSpec(start: 960, length: 240, pitch: 64),
                                                 AddNotes.NoteSpec(start: 0, length: 480, pitch: 60, velocity: 90)]),
            .init(start: 0, length: 1920),
        ]), on: p)
        let folder = try #require(q.keysTrack.takeFolders.first)
        guard case .midi(let first) = folder.takes[0].clip else { Issue.record("not MIDI"); return }
        #expect(first.notes.map(\.pitch) == [60, 64] && first.notes.map(\.id) == [next + 4, next + 3])
        #expect(first.notes[0].velocity == 90)
        #expect(folder.comp == [CompSegment(start: 0, end: 1920, take: folder.takes[1].id)])
    }

    @Test("MODEL-031: CreateTakeFolder refuses bad tracks, takes, assets and fields, and changes nothing")
    func createRefusals() throws {
        let take = CreateTakeFolder.TakeSpec(start: 0, length: 960, assetID: p.takeAsset)
        let bad: [CreateTakeFolder] = [
            CreateTakeFolder(trackID: 999, takes: [take]),
            CreateTakeFolder(trackID: p.micTrack.id, takes: []),
            CreateTakeFolder(trackID: p.micTrack.id, takes: [.init(start: 0, length: 960)]),
            CreateTakeFolder(trackID: p.micTrack.id, takes: [.init(start: 0, length: 960, assetID: 999)]),
            CreateTakeFolder(trackID: p.micTrack.id, takes: [.init(start: 0, length: 0, assetID: p.takeAsset)]),
            CreateTakeFolder(trackID: p.micTrack.id, takes: [.init(start: -1, length: 960, assetID: p.takeAsset)]),
            CreateTakeFolder(trackID: p.micTrack.id, takes: [.init(start: 0, length: 960, assetID: p.takeAsset, sourceOffsetSamples: -1)]),
            CreateTakeFolder(trackID: p.micTrack.id, takes: [.init(start: 0, length: 960, assetID: p.takeAsset, gain: 5)]),
            CreateTakeFolder(trackID: p.micTrack.id, takes: [.init(start: 0, length: 960, assetID: p.takeAsset,
                                                              notes: [AddNotes.NoteSpec(start: 0, length: 1, pitch: 60)])]),
            CreateTakeFolder(trackID: p.keysTrack.id, takes: [take]),
            CreateTakeFolder(trackID: p.keysTrack.id, takes: [.init(start: 0, length: 960,
                                                               notes: [AddNotes.NoteSpec(start: 0, length: 1, pitch: 200)])]),
        ]
        for command in bad {
            var q = p
            #expect(throws: DAWError.self) { _ = try command.applyChecked(to: &q) }
            #expect(q == p)
        }
    }

    @Test("T-080: RemoveTakeFolder removes the folder with its takes; RestoreTakeFolder puts it back with its IDs at its index")
    func removeAndRestore() throws {
        let (q, folder) = try withFolder()
        let removed = try expectApplyRoundTrip(RemoveTakeFolder(folderID: folder.id), on: q)
        #expect(removed.micTrack.takeFolders.isEmpty && removed.assets == q.assets, "the asset stays")
        #expect(throws: DAWError.self) { var r = q; _ = try RemoveTakeFolder(folderID: 999).applyChecked(to: &r) }
        // Restoring over IDs in use, at a bad index, or on the other kind of track is refused.
        var r = q
        #expect(throws: DAWError.self) { _ = try RestoreTakeFolder(trackID: p.micTrack.id, index: 0, folder: folder).applyChecked(to: &r) }
        var s = removed
        #expect(throws: DAWError.self) { _ = try RestoreTakeFolder(trackID: p.micTrack.id, index: 1, folder: folder).applyChecked(to: &s) }
        #expect(throws: DAWError.self) { _ = try RestoreTakeFolder(trackID: p.keysTrack.id, index: 0, folder: folder).applyChecked(to: &s) }
        #expect(s == removed)
    }

    // MARK: REC-033 SetCompSelection

    @Test("REC-033: SetCompSelection splits segments around the range and merges neighbours of the same take; undoable, round trip")
    func compSelection() throws {
        let (q, folder) = try withFolder()
        let t = folder.takes.map(\.id)
        // Inside a segment and across a boundary: three segments become five, then merge.
        let split = try expectApplyRoundTrip(SetCompSelection(folderID: folder.id, start: 480, end: 1440, takeID: t[0]), on: q)
        #expect(split.micTrack.takeFolders[0].comp == [CompSegment(start: 0, end: 480, take: t[2]),
                                                  CompSegment(start: 480, end: 1440, take: t[0]),
                                                  CompSegment(start: 1440, end: 1920, take: t[1])])
        var r = split
        _ = try SetCompSelection(folderID: folder.id, start: 1440, end: 1920, takeID: t[0]).applyChecked(to: &r)
        #expect(r.micTrack.takeFolders[0].comp == [CompSegment(start: 0, end: 480, take: t[2]),
                                              CompSegment(start: 480, end: 1920, take: t[0])], "merged with its neighbour")
        _ = try SetCompSelection(folderID: folder.id, start: 0, end: 1920, takeID: t[1]).applyChecked(to: &r)
        #expect(r.micTrack.takeFolders[0].comp == [CompSegment(start: 0, end: 1920, take: t[1])], "the whole folder")
        // Selecting what is already there: an exact inverse all the same.
        let before = r
        let inverse = try SetCompSelection(folderID: folder.id, start: 0, end: 960, takeID: t[1]).applyChecked(to: &r)
        _ = try inverse.applyChecked(to: &r)
        #expect(r == before)
        // Through UndoStack: one entry per selection.
        var stack = UndoStack()
        var u = q
        try stack.perform(SetCompSelection(folderID: folder.id, start: 480, end: 1440, takeID: t[0]), on: &u)
        try stack.perform(SetCompSelection(folderID: folder.id, start: 100, end: 200, takeID: t[1]), on: &u)
        #expect(u.micTrack.takeFolders[0].comp.count == 5)
        _ = try stack.undo(&u)
        #expect(u == split)
        _ = try stack.undo(&u)
        #expect(u == q)
        _ = try stack.redo(&u)
        #expect(u == split)
    }

    @Test("MODEL-031: SetCompSelection refuses a range outside the folder, an empty range, a take of another folder; RestoreComp refuses a broken comp")
    func compRefusals() throws {
        let (q, folder) = try withFolder()
        let t = folder.takes.map(\.id)
        let bad: [any Command] = [
            SetCompSelection(folderID: 999, start: 0, end: 960, takeID: t[0]),
            SetCompSelection(folderID: folder.id, start: 0, end: 960, takeID: 999),
            SetCompSelection(folderID: folder.id, start: 960, end: 960, takeID: t[0]),
            SetCompSelection(folderID: folder.id, start: 0, end: 1921, takeID: t[0]),
            RestoreComp(folderID: folder.id, comp: []),
            RestoreComp(folderID: folder.id, comp: [CompSegment(start: 0, end: 900, take: t[0]),
                                                    CompSegment(start: 960, end: 1920, take: t[1])]),  // a gap
            RestoreComp(folderID: folder.id, comp: [CompSegment(start: 0, end: 960, take: t[0]),
                                                    CompSegment(start: 960, end: 1920, take: t[0])]),  // not merged
            RestoreComp(folderID: folder.id, comp: [CompSegment(start: 0, end: 1920, take: 999)]),
            RestoreComp(folderID: 999, comp: folder.comp),
        ]
        for command in bad {
            var r = q
            #expect(throws: DAWError.self) { _ = try command.applyChecked(to: &r) }
            #expect(r == q)
        }
    }

    @Test("MODEL-032: validate() checks folders: unique IDs across takes and clips, kinds, assets, a gapless comp")
    func validation() throws {
        let (q, folder) = try withFolder()
        try q.validate()
        var broken = q
        broken.tracks[0].takeFolders[0].comp[0].end = 900
        #expect(throws: DAWError.self) { try broken.validate() }
        broken = q
        broken.tracks[0].takeFolders[0].takes[1].id = folder.takes[0].id
        #expect(throws: DAWError.self) { try broken.validate() }
        broken = q
        broken.assets = []
        #expect(throws: DAWError.self) { try broken.validate() }
        broken = q
        broken.tracks[1].takeFolders = [folder]
        broken.tracks[0].takeFolders = []
        #expect(throws: DAWError.self) { try broken.validate() }
        // JSON round trip of a project with a folder.
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(q))
        #expect(decoded == q && decoded.ids.next == q.ids.next)
    }

    // MARK: REC-030 import

    /// The take facadeReportsLoopPasses records: the loop [0, 1920) from tick 0, latency 595, three passes.
    func loopTake(track: NodeIDValue, start: SamplePos = -595, loop: (SamplePos, SamplePos) = (0, 48_000),
                  passStarts: [Int64] = [0, 48_595, 96_595], frames: Int64 = 133_120, rate: Double = 48_000) -> RecordedTake {
        var take = RecordedTake(track: track, file: "/tmp/rec/Track 2 Take 1.caf", startSample: start, frames: frames, sampleRate: rate)
        take.passes = UInt32(max(passStarts.count, 1))
        take.loopStartSample = loop.0
        take.loopEndSample = loop.1
        take.passStarts = passStarts
        return take
    }

    @Test("REC-030: a take of 3 passes becomes ImportAsset + CreateTakeFolder (3 takes, views into the one file) in one \"Record\" composite")
    func importThreePasses() throws {
        let asset = AssetRef(id: 50, path: "a.caf", channels: 2, originalSampleRate: 48_000, frames: 133_120)
        let command = try #require(RecordingImport.command(for: loopTake(track: p.micTrack.id), asset: asset, in: p))
        #expect(command.label == "Record" && command.commands.count == 2)
        #expect(command.commands[0] is ImportAsset)
        let create = try #require(command.commands[1] as? CreateTakeFolder)
        #expect(create.trackID == p.micTrack.id)
        // Pass 0 from −595 (frames before 0 skipped), passes 1 and 2 from the loop start; the last
        // one ends with the file: 133120 − 96595 = 36525 samples = 1461 ticks.
        #expect(create.takes == [
            .init(start: 0, length: 1920, assetID: 50, sourceOffsetSamples: 595),
            .init(start: 0, length: 1920, assetID: 50, sourceOffsetSamples: 48_595),
            .init(start: 0, length: 1461, assetID: 50, sourceOffsetSamples: 96_595),
        ])
        // Recording began before a later loop: the first take runs from there to the loop end.
        let later = loopTake(track: p.micTrack.id, start: 12_000, loop: (24_000, 48_000), passStarts: [0, 36_000, 60_000], frames: 70_000)
        let folder = try #require(RecordingImport.takeFolderCommand(for: later, asset: asset, in: p))
        #expect(folder.takes == [
            .init(start: 480, length: 1440, assetID: 50, sourceOffsetSamples: 0),
            .init(start: 960, length: 960, assetID: 50, sourceOffsetSamples: 36_000),
            .init(start: 960, length: 400, assetID: 50, sourceOffsetSamples: 60_000),
        ])
        // At another session rate the positions scale (44.1 kHz recording, 48 kHz project).
        let scaled = loopTake(track: p.micTrack.id, start: 0, loop: (0, 44_100), passStarts: [0, 44_100], frames: 66_150, rate: 44_100)
        #expect(try #require(RecordingImport.takeFolderCommand(for: scaled, asset: asset, in: p)).takes == [
            .init(start: 0, length: 1920, assetID: 50, sourceOffsetSamples: 0),
            .init(start: 0, length: 960, assetID: 50, sourceOffsetSamples: 48_000),
        ])
        // One pass (no wrap): a plain clip, as before.
        let plain = try #require(RecordingImport.command(for: loopTake(track: p.micTrack.id, passStarts: []), asset: asset, in: p))
        #expect(plain.commands[1] is AddClip)
    }

    @Test("REC-030: the event imports as one undo step: undo removes the asset and the folder, redo brings both back with their IDs")
    func importEventUndo() async throws {
        let store = ProjectStore(project: p)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        let dir = FileManager.default.temporaryDirectory.appending(path: "takes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "Track 2 Take 1.caf").path
        try Data([0]).write(to: URL(fileURLWithPath: file))
        var take = loopTake(track: p.micTrack.id)
        take.file = file
        let next = store.project.ids.next
        engine.post(EngineEvent(recording: take))
        _ = sync.pollEvents()
        await sync.settleLoads()
        let folder = try #require(store.project.micTrack.takeFolders.first)
        #expect(folder.id == next + 1, "the asset claims `next`, the folder the one after")
        #expect(folder.takes.count == 3 && store.project.assets.contains { $0.id == next })
        #expect(store.undoLabel == "Record")
        let recorded = store.project
        store.undo()
        #expect(store.project == p)
        store.redo()
        #expect(store.project == recorded)
    }

    // MARK: REC-034 MIDI takes

    func midiLoopTake(option: Bool) -> RecordedTake {
        var take = RecordedTake(track: p.keysTrack.id, file: "", startSample: -100, frames: 0, sampleRate: 48_000, endSample: 12_000,
                                notes: [RecordedMidiNote(start: 1000, end: 13_000, pitch: 60, pass: 0),
                                        RecordedMidiNote(start: 24_000, end: 36_000, pitch: 62, pass: 1),
                                        RecordedMidiNote(start: 2500, end: 3000, pitch: 64, pass: 2)])
        take.passes = 3
        take.loopStartSample = 0
        take.loopEndSample = 48_000
        take.midiLoopTakes = option
        return take
    }

    @Test("REC-034: MIDI loop recording merges into one clip by default; with midiLoopTakes each pass becomes a take of a folder")
    func midiLoopTakes() throws {
        // Default: merged (today's overdub), AddClip + AddNotes.
        let merged = try #require(RecordingImport.midiCommand(for: midiLoopTake(option: false), in: p))
        #expect(merged.commands.first is AddClip)
        #expect(RecordingImport.midiTakeFolderCommand(for: midiLoopTake(option: false), in: p) == nil)

        let command = try #require(RecordingImport.midiTakeFolderCommand(for: midiLoopTake(option: true), in: p))
        let create = try #require(command.commands.first as? CreateTakeFolder)
        #expect(command.label == "Record")
        #expect(create.takes.count == 3)
        #expect(create.takes.map(\.start) == [0, 0, 0] && create.takes.map(\.length) == [1920, 1920, 480])
        #expect(create.takes.map { $0.notes?.map(\.pitch) ?? [] } == [[60], [62], [64]])
        #expect(create.takes[0].notes?.first == AddNotes.NoteSpec(start: 40, length: 480, pitch: 60, velocity: 100, channel: 0))

        // Through the store: one undo step; the folder's ID comes back.
        let store = ProjectStore(project: p)
        let next = store.project.ids.next
        #expect(try store.importMidiRecording(midiLoopTake(option: true)) == next)
        #expect(store.project.keysTrack.takeFolders.count == 1 && store.project.keysTrack.clips.isEmpty)
        store.undo()
        #expect(store.project == p)
        // One pass with the option on: merged as before.
        var single = midiLoopTake(option: true)
        single.passes = 1
        #expect(RecordingImport.midiTakeFolderCommand(for: single, in: p) == nil)
    }

    @Test("REC-034: the record option reaches the engine and reads back; it is neither saved nor undoable")
    func recordOption() throws {
        let engine = FakeEngine()
        engine.setRecordOptions(midiLoopTakes: true)
        #expect(engine.transport().midiLoopTakes)
        #expect(engine.calls.last == .setRecordOptions(midiLoopTakes: true))
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(!json.contains("midiLoopTakes"))
    }

    // MARK: REC-032 flattening

    @Test("REC-032: the comp flattens into the player's clips (IDs above every model ID), overlapping 64 samples at each boundary for DSP-002's crossfade")
    func flattening() throws {
        var (q, folder) = try withFolder()
        let t = folder.takes.map(\.id)
        // Comp: [0, 960) t2 (the partial pass, its audio ends there), [960, 1440) t1, [1440, 1920) t0.
        _ = try SetCompSelection(folderID: folder.id, start: 1440, end: 1920, takeID: t[0]).applyChecked(to: &q)
        let graph = GraphDescriptionBuilder.build(q, runtime: RuntimeIDs.sequential(for: q))
        let player = GraphNodeID.source(of: q.micTrack.id)
        let clips = graph.audioClips.filter { $0.player == player }
        let base: ModelID = 1 << 63
        #expect(clips.map(\.clipID) == [base, base + 1, base + 2])
        // t2 ends with its audio at 960: t1 starts 64 samples (3 ticks rounded down to 2.56) early,
        // under it, with its offset moved along. t1 runs on 64 samples (3 ticks) under t0.
        #expect(clips.map(\.start) == [0, 957, 1440])
        #expect(clips.map(\.length) == [960, 486, 480])
        let offsets: [Int64] = [96_000, 48_000 + 957 * 25, 1440 * 25]
        #expect(clips.map(\.sourceOffsetSamples) == offsets)
        #expect(clips.allSatisfy { $0.assetID == q.takeAsset })
        // The flattened clips follow the comp.
        _ = try SetCompSelection(folderID: folder.id, start: 0, end: 1920, takeID: t[1]).applyChecked(to: &q)
        let whole = GraphDescriptionBuilder.build(q, runtime: RuntimeIDs.sequential(for: q)).audioClips
        #expect(whole.map(\.start) == [0] && whole.map(\.length) == [1920] && whole.map(\.sourceOffsetSamples) == [48_000])

        // A MIDI comp adds each segment's notes, trimmed to it, with no overlap.
        var m = p
        _ = try CreateTakeFolder(trackID: p.keysTrack.id, takes: [
            .init(start: 0, length: 1920, notes: [AddNotes.NoteSpec(start: 0, length: 1920, pitch: 60)]),
            .init(start: 0, length: 960, notes: [AddNotes.NoteSpec(start: 480, length: 960, pitch: 62)]),
        ]).applyChecked(to: &m)
        _ = try SetInstrument(trackID: p.keysTrack.id, device: .builtin(.sampler)).applyChecked(to: &m)
        let notes = GraphDescriptionBuilder.build(m, runtime: RuntimeIDs.sequential(for: m)).notes
        #expect(notes.map(\.pitch) == [62, 60])
        #expect(notes.map(\.start) == [480, 960] && notes.map(\.length) == [480, 960])
    }

    @Test("REC-032: assetLoaded rebuilds the player whose comp uses the asset")
    func assetLoadedBumpsCompPlayer() async throws {
        let (q, _) = try withFolder()
        let store = ProjectStore(project: q)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        await sync.settle()
        engine.clearCalls()
        _ = engine.loadAsset(q.takeAsset, path: "Audio/x.caf")
        _ = sync.pollEvents()
        await sync.settle()
        let nodes = try #require(engine.appliedGraphs.last).nodes
        #expect(nodes.first { $0.id == GraphNodeID.source(of: q.micTrack.id) }?.configVersion == 1)
    }
}
