import DAWModel
import Foundation
import Testing

// MODEL-005 (clip/tempo subset), MODEL-031, MODEL-032 and DW-110: asset, clip, tempo, time
// signature and loop commands (T-030).

/// 48 kHz, 120 bpm (one beat = 960 ticks = 24 000 samples). A 2 s stereo asset (96 000 frames),
/// an audio track with two clips of it and a MIDI track with one clip of two notes:
///
///   Gtr:  [clip @0 +3840]  [clip @7680 +1920, offset 24 000, gain 0.5, fades 120/240]
///   Keys: [clip @3840 +3840: notes @0 +480 (60), @960 +480 (64)]
enum ClipProject {
    static func make() -> Project {
        var p = Project(id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!, name: "clips")
        let asset = p.ids.allocate()
        p.assets = [AssetRef(id: asset, path: "Audio/loop.wav", channels: 2, originalSampleRate: 48_000, frames: 96_000)]
        let gtr = p.ids.allocate()
        let keys = p.ids.allocate()
        p.tracks = [
            Track(id: gtr, name: "Gtr", kind: .audio, clips: [
                .audio(AudioClip(id: p.ids.allocate(), assetID: asset, start: 0, length: 3840)),
                .audio(AudioClip(id: p.ids.allocate(), assetID: asset, start: 7680, length: 1920, sourceOffsetSamples: 24_000,
                                 gain: 0.5, fadeIn: 120, fadeOut: 240)),
            ]),
            Track(id: keys, name: "Keys", kind: .midi, clips: [
                .midi(MidiClip(id: p.ids.allocate(), start: 3840, length: 3840, notes: [
                    Note(id: p.ids.allocate(), start: 0, length: 480, pitch: 60),
                    Note(id: p.ids.allocate(), start: 960, length: 480, pitch: 64),
                ])),
            ]),
        ]
        return p
    }
}

extension Project {
    var gtr: Track { tracks[0] }
    var keys: Track { tracks[1] }
    var loopAsset: AssetRef { assets[0] }

    func audioClip(_ id: ModelID) -> AudioClip? {
        if case .audio(let clip) = clip(id) { clip } else { nil }
    }

    func midiClip(_ id: ModelID) -> MidiClip? {
        if case .midi(let clip) = clip(id) { clip } else { nil }
    }
}

@Suite("Clip, tempo and loop commands")
struct ClipCommandTests {
    init() { TestCommands.register() }

    let p = ClipProject.make()

    // MARK: ImportAsset

    @Test("MODEL-005, DW-105: ImportAsset reserves the asset's own ID and appends it; the inverse removes it")
    func importAsset() throws {
        let id = p.ids.next  // asset.import loads under this ID first
        let asset = AssetRef(id: id, path: "Audio/kick.wav", channels: 1, originalSampleRate: 44_100, frames: 22_050)
        let imported = try expectApplyRoundTrip(ImportAsset(asset: asset), on: p)
        #expect(imported.assets.last == asset && imported.ids.next == id + 1)
        var next = imported
        _ = try AddTrack(name: "x", kind: .audio).applyChecked(to: &next)
        #expect(next.tracks.last?.id == id + 1, "the next entity doesn't take the asset's ID")

        // An absolute path (a referenced file, or a project without a folder yet) is kept as given.
        let absolute = AssetRef(id: id, path: "/tmp/x.wav", channels: 2, originalSampleRate: 48_000, frames: 0)
        #expect(try expectApplyRoundTrip(ImportAsset(asset: absolute), on: p).assets.last?.path == "/tmp/x.wav")

        // RemoveAsset's inverse puts the asset back where it was.
        var two = p
        _ = try ImportAsset(asset: asset).applyChecked(to: &two)
        let removed = try expectApplyRoundTrip(RemoveAsset(assetID: id), on: two)
        #expect(removed.assets == p.assets)
        var first = two
        first.tracks = []
        #expect(try expectApplyRoundTrip(RemoveAsset(assetID: p.loopAsset.id), on: first).assets == [asset])
    }

    @Test("DW-105: the wire shape asset.import performs decodes to ImportAsset")
    func importAssetWireShape() throws {
        let json = #"{"type":"ImportAsset","asset":{"id":9,"path":"/a/b.wav","channels":2,"originalSampleRate":48000,"frames":480}}"#
        let command = try #require(try CommandRegistry.decode(Data(json.utf8)) as? ImportAsset)
        #expect(command.asset == AssetRef(id: 9, path: "/a/b.wav", channels: 2, originalSampleRate: 48_000, frames: 480))
        #expect(command.index == nil)
        #expect(String(decoding: try CommandRegistry.encode(command), as: UTF8.self)
            == #"{"asset":{"channels":2,"frames":480,"id":9,"originalSampleRate":48000,"path":"/a/b.wav"},"type":"ImportAsset"}"#)
    }

    @Test("MODEL-005, DW-105: import an asset, then add a clip of it through the undo stack")
    func importThenAddClip() throws {
        var project = Project()
        var stack = UndoStack()
        try stack.perform(AddTrack(name: "Drums", kind: .audio), on: &project)
        let track = project.tracks[0].id
        let id = project.ids.next
        try stack.perform(ImportAsset(asset: AssetRef(id: id, path: "Audio/d.wav", channels: 2, originalSampleRate: 48_000, frames: 48_000)), on: &project)
        try stack.perform(AddClip(trackID: track, start: 0, assetID: id), on: &project)
        let clip = try #require(project.tracks[0].clips.first)
        #expect(clip == .audio(AudioClip(id: id + 1, assetID: id, start: 0, length: 1920)), "1 s at 120 bpm")
        let final = project
        while try stack.undo(&project) != nil {}
        #expect(project == Project(id: project.id, name: project.name))
        while try stack.redo(&project) != nil {}
        #expect(project == final)
    }

    // MARK: Clips

    @Test("MODEL-005: AddClip adds audio and MIDI clips with new IDs, in timeline order (DW-110)")
    func addClip() throws {
        let asset = p.loopAsset.id
        let added = try expectApplyRoundTrip(
            AddClip(trackID: p.gtr.id, start: 3840, length: 960, assetID: asset, sourceOffsetSamples: 100, gain: 2,
                    fadeIn: 10, fadeOut: 20), on: p)
        #expect(added.gtr.clips.map(\.start) == [0, 3840, 7680], "inserted between the two clips")
        #expect(added.gtr.clips[1] == .audio(AudioClip(id: p.ids.next, assetID: asset, start: 3840, length: 960,
                                                         sourceOffsetSamples: 100, gain: 2, fadeIn: 10, fadeOut: 20)))
        // Same start as an existing clip: the newer (higher) ID goes after it.
        #expect(try expectApplyRoundTrip(AddClip(trackID: p.gtr.id, start: 0, length: 10, assetID: asset), on: p)
            .gtr.clips.map(\.id) == [p.gtr.clips[0].id, p.ids.next, p.gtr.clips[1].id])

        // Default length: the rest of the asset after the offset, at the tempo now.
        #expect(try expectApplyRoundTrip(AddClip(trackID: p.gtr.id, start: 0, assetID: asset), on: p).gtr.clips[1].length == 3840)
        #expect(try expectApplyRoundTrip(AddClip(trackID: p.gtr.id, start: 0, assetID: asset, sourceOffsetSamples: 72_000), on: p)
            .gtr.clips[1].length == 960)
        // Not a whole tick: rounded up so the clip covers every frame. 44.1 kHz → 48 kHz session.
        var odd = p
        odd.assets[0] = AssetRef(id: asset, path: "a.wav", channels: 1, originalSampleRate: 44_100, frames: 44_101)
        let rounded = try expectApplyRoundTrip(AddClip(trackID: p.gtr.id, start: 1, assetID: asset), on: odd).audioClip(p.ids.next)!
        let map = p.tempoMap
        #expect(map.tickToSample(Tick(1 + rounded.length.raw)) - map.tickToSample(1) >= 48_001)
        #expect(map.tickToSample(Tick(rounded.length.raw)) - map.tickToSample(1) < 48_001)

        let midi = try expectApplyRoundTrip(AddClip(trackID: p.keys.id, start: 0, length: 1920), on: p)
        #expect(midi.keys.clips.first == .midi(MidiClip(id: p.ids.next, start: 0, length: 1920)))
    }

    @Test("MODEL-005: RemoveClip removes a clip with its notes; undo restores them with their IDs")
    func removeClip() throws {
        let removed = try expectApplyRoundTrip(RemoveClip(clipID: p.keys.clips[0].id), on: p)
        #expect(removed.keys.clips.isEmpty)
        #expect(try expectApplyRoundTrip(RemoveClip(clipID: p.gtr.clips[0].id), on: p).gtr.clips.map(\.start) == [7680])
    }

    @Test("MODEL-005: redoing AddClip recreates the same ID, so later history entries still apply")
    func redoKeepsClipIDs() throws {
        var project = p
        var stack = UndoStack()
        try stack.perform(AddClip(trackID: p.gtr.id, start: 1920, length: 960, assetID: p.loopAsset.id), on: &project)
        let id = project.gtr.clips[1].id
        try stack.perform(SetClipGain(clipID: id, gain: 0.25), on: &project)
        try stack.perform(MoveClip(clipID: id, start: 9600), on: &project)
        let final = project
        while try stack.undo(&project) != nil {}
        #expect(project == p)
        while try stack.redo(&project) != nil {}
        #expect(project == final)
    }
}
