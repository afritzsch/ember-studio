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

    @Test("MODEL-005: MoveClip moves within a track and onto another track of the same kind; order follows (DW-110)")
    func moveClip() throws {
        let first = p.gtr.clips[0].id
        let moved = try expectApplyRoundTrip(MoveClip(clipID: first, start: 9000), on: p)
        #expect(moved.gtr.clips.map(\.id) == [p.gtr.clips[1].id, first] && moved.audioClip(first)?.start == 9000)
        #expect(moved.audioClip(first)?.sourceOffsetSamples == 0, "the audio moves with the clip")

        var two = p
        _ = try AddTrack(name: "Bass", kind: .audio).applyChecked(to: &two)
        let bass = two.tracks[2].id
        let across = try expectApplyRoundTrip(MoveClip(clipID: first, start: 480, trackID: bass), on: two)
        #expect(across.gtr.clips.count == 1 && across.tracks[2].clips.map(\.start) == [480])
        let notes = try expectApplyRoundTrip(MoveClip(clipID: p.keys.clips[0].id, start: 0), on: p)
        #expect(notes.midiClip(p.keys.clips[0].id)?.notes == p.keys.clips[0].midiNotes, "notes are relative and move along")
    }

    @Test("MODEL-005: ResizeClip trims either edge; content stays put (audio offset, MIDI note starts)")
    func resizeClip() throws {
        let clip = p.gtr.clips[1].id  // @7680 +1920, offset 24 000; 25 samples a tick
        let left = try expectApplyRoundTrip(ResizeClip(clipID: clip, start: 7000, length: 2600), on: p).audioClip(clip)!
        #expect(left.start == 7000 && left.length == 2600 && left.sourceOffsetSamples == 24_000 - 680 * 25)
        #expect(left.fadeIn == 120 && left.fadeOut == 240, "fades are left alone")
        let right = try expectApplyRoundTrip(ResizeClip(clipID: clip, start: 7680, length: 100), on: p).audioClip(clip)!
        #expect(right.length == 100 && right.sourceOffsetSamples == 24_000)
        let later = try expectApplyRoundTrip(ResizeClip(clipID: clip, start: 8000, length: 1600), on: p).audioClip(clip)!
        #expect(later.sourceOffsetSamples == 24_000 + 320 * 25)

        let keys = p.keys.clips[0].id  // @3840 +3840, notes @0 and @960
        let trimmed = try expectApplyRoundTrip(ResizeClip(clipID: keys, start: 4800, length: 2880), on: p).midiClip(keys)!
        #expect(trimmed.notes.map(\.start) == [-960, 0], "the first note is outside the window but kept")
    }

    @Test("MODEL-005: SplitClip splits audio and MIDI clips; undo and redo keep every ID")
    func splitClip() throws {
        let clip = p.gtr.clips[1].id  // @7680 +1920, offset 24 000, gain 0.5, fades 120/240
        let split = try expectApplyRoundTrip(SplitClip(clipID: clip, at: 8160), on: p)
        #expect(split.gtr.clips.map(\.id) == [p.gtr.clips[0].id, clip, p.ids.next])
        #expect(split.audioClip(clip) == AudioClip(id: clip, assetID: p.loopAsset.id, start: 7680, length: 480,
                                                   sourceOffsetSamples: 24_000, gain: 0.5, fadeIn: 120, fadeOut: 0))
        #expect(split.audioClip(p.ids.next) == AudioClip(id: p.ids.next, assetID: p.loopAsset.id, start: 8160, length: 1440,
                                                         sourceOffsetSamples: 24_000 + 480 * 25, gain: 0.5, fadeIn: 0, fadeOut: 240))

        let keys = p.keys.clips[0]  // @3840 +3840, notes @0 +480 and @960 +480
        let notes = keys.midiNotes
        let atBeat = try expectApplyRoundTrip(SplitClip(clipID: keys.id, at: 4800), on: p)
        #expect(atBeat.midiClip(keys.id) == MidiClip(id: keys.id, start: 3840, length: 960, notes: [notes[0]]))
        var second = notes[1]
        second.start = 0
        #expect(atBeat.midiClip(p.ids.next) == MidiClip(id: p.ids.next, start: 4800, length: 2880, notes: [second]))
        // A note crossing the split stays in the first clip, cut there by the window.
        let crossing = try expectApplyRoundTrip(SplitClip(clipID: keys.id, at: 4000), on: p)
        #expect(crossing.midiClip(keys.id)?.notes == [notes[0]] && crossing.midiClip(p.ids.next)?.notes.map(\.start) == [800])

        // Undo/redo through the stack: redo recreates the new clip with its ID.
        var project = p
        var stack = UndoStack()
        try stack.perform(SplitClip(clipID: keys.id, at: 4800), on: &project)
        try stack.perform(SetClipGain(clipID: clip, gain: 2), on: &project)
        try stack.perform(MoveClip(clipID: p.ids.next, start: 9600), on: &project)
        let final = project
        #expect(stack.undoEntries.count == 3)
        while try stack.undo(&project) != nil {}
        #expect(project == p)
        while try stack.redo(&project) != nil {}
        #expect(project == final)
    }

    @Test("MODEL-005: SetClipGain and SetClipFades round-trip on audio clips")
    func gainAndFades() throws {
        let clip = p.gtr.clips[0].id
        #expect(try expectApplyRoundTrip(SetClipGain(clipID: clip, gain: AudioClip.maxGain), on: p).audioClip(clip)?.gain == AudioClip.maxGain)
        #expect(try expectApplyRoundTrip(SetClipGain(clipID: clip, gain: 0), on: p).audioClip(clip)?.gain == 0)
        let faded = try expectApplyRoundTrip(SetClipFades(clipID: clip, fadeIn: 3840, fadeOut: 960), on: p).audioClip(clip)!
        #expect(faded.fadeIn == 3840 && faded.fadeOut == 960, "fades may overlap; each fits in the clip")
        #expect(try expectApplyRoundTrip(SetClipFades(clipID: p.gtr.clips[1].id, fadeIn: 0, fadeOut: 0), on: p)
            .audioClip(p.gtr.clips[1].id)?.fadeIn == 0)
    }

    // MARK: Tempo and time signature

    @Test("MODEL-005: SetTempoEvent adds or changes a tempo event; RemoveTempoEvent removes one")
    func tempoEvents() throws {
        let slower = try expectApplyRoundTrip(SetTempoEvent(tick: 0, bpm: 60), on: p)
        #expect(slower.tempoMap.tempoEvents == [TempoEvent(tick: 0, bpm: 60)])
        let change = try expectApplyRoundTrip(SetTempoEvent(tick: 3840, bpm: 90), on: p)
        #expect(change.tempoMap.tempoEvents == [TempoEvent(tick: 0, bpm: 120), TempoEvent(tick: 3840, bpm: 90)])
        let between = try expectApplyRoundTrip(SetTempoEvent(tick: 1920, bpm: 100), on: change)
        #expect(between.tempoMap.tempoEvents.map(\.tick) == [0, 1920, 3840])
        #expect(try expectApplyRoundTrip(SetTempoEvent(tick: 3840, bpm: 140), on: change).tempoMap.bpmAt(4000) == 140)
        #expect(try expectApplyRoundTrip(RemoveTempoEvent(tick: 3840), on: change).tempoMap == p.tempoMap)
        #expect(change.tempoMap.sampleRate == p.sessionSampleRate, "the map stays at the session rate")
    }

    @Test("MODEL-005, D-06: a tempo edit moves audio clips on the sample timeline but doesn't stretch them")
    func tempoMovesClips() throws {
        let clip = p.gtr.clips[1]
        let slower = try expectApplyRoundTrip(SetTempoEvent(tick: 0, bpm: 60), on: p)
        #expect(slower.gtr.clips[1] == clip, "ticks, length and source offset are unchanged")
        #expect(p.tempoMap.tickToSample(clip.start) == 192_000 && slower.tempoMap.tickToSample(clip.start) == 384_000)
    }

    @Test("MODEL-005: SetTimeSignature adds or changes a signature; RemoveTimeSignature removes one")
    func timeSignatures() throws {
        let waltz = try expectApplyRoundTrip(SetTimeSignature(tick: 0, numerator: 3, denominator: 4), on: p)
        #expect(waltz.tempoMap.timeSignatures == [TimeSignatureEvent(tick: 0, numerator: 3, denominator: 4)])
        let seven = try expectApplyRoundTrip(SetTimeSignature(tick: 3840, numerator: 7, denominator: 8), on: p)
        #expect(seven.tempoMap.tickToBBT(3840) == BBT(bar: 2, beat: 1, tick: 0))
        #expect(seven.tempoMap.tickToBBT(Tick(3840 + 7 * 480)) == BBT(bar: 3, beat: 1, tick: 0))
        #expect(try expectApplyRoundTrip(SetTimeSignature(tick: 3840, numerator: 6, denominator: 8), on: seven)
            .tempoMap.timeSignatures.last == TimeSignatureEvent(tick: 3840, numerator: 6, denominator: 8))
        #expect(try expectApplyRoundTrip(RemoveTimeSignature(tick: 3840), on: seven).tempoMap == p.tempoMap)
    }

    // MARK: Loop

    @Test("MODEL-005, DW-106: SetLoop sets, changes, disables and clears the loop region")
    func setLoop() throws {
        let looped = try expectApplyRoundTrip(SetLoop(start: 0, end: 3840), on: p)
        #expect(looped.loop == LoopRange(start: 0, end: 3840, isEnabled: true))
        let off = try expectApplyRoundTrip(SetLoop(start: 0, end: 3840, isEnabled: false), on: looped)
        #expect(off.loop?.isEnabled == false)
        #expect(try expectApplyRoundTrip(SetLoop(loop: nil), on: looped).loop == nil)
        #expect(SetLoop(loop: nil).label == "Set Loop")
    }

    @Test("DW-060: an enabled loop shorter than the engine's largest block is rejected; undo never is")
    func loopMinimumLength() throws {
        // 120 bpm at 48 kHz: 25 samples a tick, so 4096 samples are 163.84 ticks.
        var q = p
        #expect(throws: DAWError.invalidArgument("loop [0, 163) is 4075 samples, shorter than 4096")) {
            _ = try SetLoop(start: 0, end: 163).applyChecked(to: &q)
        }
        #expect(q == p)
        try expectApplyRoundTrip(SetLoop(start: 0, end: 164), on: p)
        try expectApplyRoundTrip(SetLoop(start: 0, end: 10, isEnabled: false), on: p)

        // A tempo edit may shrink a loop below the minimum. Undoing a later SetLoop puts it back
        // anyway (RestoreLoop), so the history stays usable.
        var project = p
        var stack = UndoStack()
        try stack.perform(SetLoop(start: 0, end: 200), on: &project)  // 5000 samples
        try stack.perform(SetTempoEvent(tick: 0, bpm: 240), on: &project)  // now 2500
        try stack.perform(SetLoop(start: 0, end: 3840), on: &project)
        let final = project
        try stack.undo(&project)
        #expect(project.loop == LoopRange(start: 0, end: 200))
        while try stack.undo(&project) != nil {}
        #expect(project == p)
        while try stack.redo(&project) != nil {}
        #expect(project == final)
        #expect(throws: DAWError.invalidArgument("loop [0, 200) is 2500 samples, shorter than 4096"), "re-enabling it is checked") {
            var r = final
            _ = try SetLoop(start: 0, end: 200).applyChecked(to: &r)
        }
    }

    // MARK: MODEL-031

    @Test("MODEL-031: unknown IDs and bad arguments throw and change nothing")
    func invalidCommands() {
        let missing: ModelID = 999
        let gtr = p.gtr.id, keys = p.keys.id
        let audio = p.gtr.clips[0].id, faded = p.gtr.clips[1].id, midi = p.keys.clips[0].id
        let asset = p.loopAsset.id
        let end = Tick.timelineEnd.raw
        let cases: [(any Command, DAWError)] = [
            (ImportAsset(asset: AssetRef(id: asset, path: "a.wav", channels: 1, originalSampleRate: 48_000, frames: 1)),
             .invalidArgument("asset id \(asset) is already in use")),
            (ImportAsset(asset: AssetRef(id: 0, path: "a.wav", channels: 1, originalSampleRate: 48_000, frames: 1)),
             .invalidArgument("asset id 0 is outside 1…\(GraphNodeID.maxModelID)")),
            (ImportAsset(asset: AssetRef(id: 900, path: "", channels: 1, originalSampleRate: 48_000, frames: 1)),
             .brokenInvariant("asset 900 has no path")),
            (ImportAsset(asset: AssetRef(id: 900, path: "a.wav", channels: 0, originalSampleRate: 48_000, frames: 1)),
             .brokenInvariant("asset 900 has 0 channels")),
            (ImportAsset(asset: AssetRef(id: 900, path: "a.wav", channels: 1, originalSampleRate: .nan, frames: 1)),
             .brokenInvariant("asset 900 has sample rate nan")),
            (ImportAsset(asset: AssetRef(id: 900, path: "a.wav", channels: 1, originalSampleRate: 48_000, frames: -1)),
             .brokenInvariant("asset 900 has -1 frames")),
            (ImportAsset(asset: AssetRef(id: 900, path: "a.wav", channels: 1, originalSampleRate: 48_000, frames: 1), index: 2),
             .invalidArgument("asset index 2 is outside 0…1")),
            (RemoveAsset(assetID: missing), .notFound(kind: "asset", id: missing)),
            (RemoveAsset(assetID: asset), .invalidArgument("asset \(asset) is used by clip \(audio)")),

            (AddClip(trackID: missing, start: 0, length: 960, assetID: asset), .notFound(kind: "track", id: missing)),
            (AddClip(trackID: gtr, start: -1, length: 960, assetID: asset), .invalidArgument("clip start -1 is negative")),
            (AddClip(trackID: gtr, start: 0, length: 960), .invalidArgument("an audio clip needs an assetID")),
            (AddClip(trackID: gtr, start: 0, length: 960, assetID: missing), .notFound(kind: "asset", id: missing)),
            (AddClip(trackID: gtr, start: 0, length: 0, assetID: asset), .brokenInvariant("clip \(p.ids.next) has start 0, length 0")),
            (AddClip(trackID: gtr, start: Tick(end), length: 1, assetID: asset),
             .brokenInvariant("clip \(p.ids.next) ends past the end of the timeline")),
            (AddClip(trackID: gtr, start: 0, assetID: asset, sourceOffsetSamples: 96_000),
             .invalidArgument("source offset 96000 is outside the asset's 96000 frames")),
            (AddClip(trackID: gtr, start: 0, length: 960, assetID: asset, sourceOffsetSamples: -1),
             .brokenInvariant("audio clip \(p.ids.next) has a negative offset or fade")),
            (AddClip(trackID: gtr, start: 0, length: 960, assetID: asset, gain: 5), .invalidArgument("clip gain 5.0 is outside 0…3.9810717")),
            (AddClip(trackID: gtr, start: 0, length: 960, assetID: asset, fadeIn: 961),
             .invalidArgument("fades 961/0 don't fit in a clip of length 960")),
            (AddClip(trackID: keys, start: 0, length: 960, assetID: asset), .invalidArgument("MIDI clips have no asset, offset, gain or fades")),
            (AddClip(trackID: keys, start: 0), .invalidArgument("a MIDI clip needs a length")),

            (RemoveClip(clipID: missing), .notFound(kind: "clip", id: missing)),
            (RemoveClip(clipID: gtr), .notFound(kind: "clip", id: gtr)),
            (RestoreClip(trackID: keys, clip: p.gtr.clips[0]), .invalidArgument("audio clip \(audio) can't go on MIDI track \(keys)")),
            (RestoreClip(trackID: gtr, clip: .audio(AudioClip(id: audio, assetID: asset, start: 0, length: 1))),
             .invalidArgument("clip id \(audio) is already in use")),
            (RestoreClip(trackID: missing, clip: p.gtr.clips[0]), .notFound(kind: "track", id: missing)),

            (MoveClip(clipID: missing, start: 0), .notFound(kind: "clip", id: missing)),
            (MoveClip(clipID: audio, start: -5), .brokenInvariant("clip \(audio) has start -5, length 3840")),
            (MoveClip(clipID: audio, start: Tick(end)), .brokenInvariant("clip \(audio) ends past the end of the timeline")),
            (MoveClip(clipID: audio, start: 0, trackID: keys), .invalidArgument("audio clip \(audio) can't go on MIDI track \(keys)")),
            (MoveClip(clipID: midi, start: 0, trackID: gtr), .invalidArgument("MIDI clip \(midi) can't go on audio track \(gtr)")),
            (MoveClip(clipID: audio, start: 0, trackID: missing), .notFound(kind: "track", id: missing)),

            (ResizeClip(clipID: missing, start: 0, length: 1), .notFound(kind: "clip", id: missing)),
            (ResizeClip(clipID: audio, start: 0, length: 0), .invalidArgument("clip window [0, +0) is empty or off the timeline")),
            (ResizeClip(clipID: audio, start: -1, length: 10), .invalidArgument("clip window [-1, +10) is empty or off the timeline")),
            (ResizeClip(clipID: faded, start: 6000, length: 3600), .invalidArgument("clip \(faded) can't start 18000 samples before its audio")),

            (SplitClip(clipID: missing, at: 10), .notFound(kind: "clip", id: missing)),
            (SplitClip(clipID: audio, at: 0), .invalidArgument("split point 0 is not inside clip \(audio) [0, 3840)")),
            (SplitClip(clipID: audio, at: 3840), .invalidArgument("split point 3840 is not inside clip \(audio) [0, 3840)")),

            (SetClip(clip: .audio(AudioClip(id: missing, assetID: asset, start: 0, length: 1))), .notFound(kind: "clip", id: missing)),
            (SetClip(clip: .midi(MidiClip(id: audio, start: 0, length: 1))), .invalidArgument("MIDI clip \(audio) can't go on audio track \(gtr)")),

            (SetClipGain(clipID: midi, gain: 1), .invalidArgument("clip \(midi) is not an audio clip")),
            (SetClipGain(clipID: missing, gain: 1), .notFound(kind: "clip", id: missing)),
            (SetClipGain(clipID: audio, gain: -0.5), .invalidArgument("clip gain -0.5 is outside 0…3.9810717")),
            (SetClipGain(clipID: audio, gain: .infinity), .invalidArgument("clip gain inf is outside 0…3.9810717")),
            (SetClipFades(clipID: audio, fadeIn: 3841, fadeOut: 0), .invalidArgument("fades 3841/0 don't fit in a clip of length 3840")),
            (SetClipFades(clipID: audio, fadeIn: 0, fadeOut: -1), .invalidArgument("fades 0/-1 don't fit in a clip of length 3840")),
            (SetClipFades(clipID: midi, fadeIn: 0, fadeOut: 0), .invalidArgument("clip \(midi) is not an audio clip")),

            (SetTempoEvent(tick: 0, bpm: 0), .invalidTempoMap(reason: .tempoOutOfRange)),
            (SetTempoEvent(tick: 960, bpm: .nan), .invalidTempoMap(reason: .tempoOutOfRange)),
            (SetTempoEvent(tick: -1, bpm: 100), .invalidArgument("tick -1 is outside 0…\(end)")),
            (SetTempoEvent(tick: Tick(end + 1), bpm: 100), .invalidArgument("tick \(end + 1) is outside 0…\(end)")),
            (RemoveTempoEvent(tick: 0), .invalidArgument("the tempo event at tick 0 can't be removed")),
            (RemoveTempoEvent(tick: 960), .invalidArgument("no tempo event at tick 960")),
            (SetTimeSignature(tick: 0, numerator: 0, denominator: 4), .invalidTempoMap(reason: .invalidTimeSignature)),
            (SetTimeSignature(tick: 0, numerator: 4, denominator: 3), .invalidTempoMap(reason: .invalidTimeSignature)),
            (SetTimeSignature(tick: -960, numerator: 4, denominator: 4), .invalidArgument("tick -960 is outside 0…\(end)")),
            (RemoveTimeSignature(tick: 0), .invalidArgument("the time signature at tick 0 can't be removed")),
            (RemoveTimeSignature(tick: 3840), .invalidArgument("no time signature at tick 3840")),

            (SetLoop(start: 960, end: 960), .invalidArgument("loop [960, 960) is empty or off the timeline")),
            (SetLoop(start: -960, end: 960), .invalidArgument("loop [-960, 960) is empty or off the timeline")),
            (SetLoop(start: 0, end: Tick(end + 1)), .invalidArgument("loop [0, \(end + 1)) is empty or off the timeline")),
            (RestoreLoop(loop: LoopRange(start: 10, end: 5)), .invalidArgument("loop [10, 5) is empty or off the timeline")),
        ]
        for (command, error) in cases {
            var q = p
            #expect(throws: error, "\(type(of: command).type)") { _ = try command.applyChecked(to: &q) }
            #expect(q == p)
        }
    }

    @Test("MODEL-031: fuzz — random clip, tempo and loop commands, valid or not, never break an invariant; undo-all restores the start")
    func fuzz() throws {
        var rng = SplitMix64(seed: 0x7_0030)
        var performed = 0
        var rejected = 0
        for _ in 0..<150 {
            var project = p
            var stack = UndoStack()
            for _ in 0..<40 {
                let command = randomClipCommand(for: project, using: &rng)
                let before = project
                do {
                    try stack.perform(command, on: &project)
                    performed += 1
                } catch {
                    rejected += 1
                    #expect(project == before)
                }
                try project.validate()
            }
            let final = project
            while try stack.undo(&project) != nil { try project.validate() }
            #expect(project == p)
            while try stack.redo(&project) != nil { try project.validate() }
            #expect(project == final)
        }
        #expect(performed > 2000 && rejected > 1000, "performed \(performed), rejected \(rejected)")
    }

    // MARK: MODEL-032

    @Test("MODEL-032, DW-110: validate() checks clip order, asset references, asset fields, clip ranges and the loop")
    func validation() {
        func expectInvalid(_ error: DAWError, sourceLocation: SourceLocation = #_sourceLocation, _ edit: (inout Project) -> Void) {
            var q = p
            edit(&q)
            #expect(throws: error, sourceLocation: sourceLocation) { try q.validate() }
        }
        let gtr = p.gtr.id
        expectInvalid(.brokenInvariant("clips of track \(gtr) are not sorted by start (then id)")) { $0.tracks[0].clips.reverse() }
        expectInvalid(.brokenInvariant("clips of track \(gtr) are not sorted by start (then id)")) {
            // Same start: the lower ID goes first.
            $0.tracks[0].clips[1].start = 0
            $0.tracks[0].clips.reverse()
        }
        expectInvalid(.brokenInvariant("audio clip \(p.gtr.clips[0].id) uses missing asset \(p.loopAsset.id)")) { $0.assets = [] }
        expectInvalid(.brokenInvariant("asset \(p.loopAsset.id) has 0 channels")) { $0.assets[0].channels = 0 }
        expectInvalid(.brokenInvariant("audio clip \(p.gtr.clips[1].id) gain 5.0 is outside 0…3.9810717")) {
            if case .audio(var clip) = $0.tracks[0].clips[1] {
                clip.gain = 5
                $0.tracks[0].clips[1] = .audio(clip)
            }
        }
        expectInvalid(.brokenInvariant("loop [960, 0) is empty or off the timeline")) { $0.loop = LoopRange(start: 960, end: 0) }
        var short = p
        short.loop = LoopRange(start: 0, end: 1)
        #expect(throws: Never.self, "the minimum length is SetLoop's check, not an invariant") { try short.validate() }
    }

    // MARK: Engine sync (DW-051, DW-072)

    @Test("DW-072: clip edits reach the engine as a new graph with the player's configVersion bumped; tempo edits rebuild")
    @MainActor
    func engineSync() async throws {
        let store = ProjectStore(project: p)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine)
        let player = GraphNodeID.source(of: p.gtr.id)
        func version() throws -> UInt32 { try #require(engine.appliedGraphs.last?.nodes.first { $0.id == player }).configVersion }
        let v0 = try version()

        try store.perform(SplitClip(clipID: p.gtr.clips[1].id, at: 8160))
        await sync.settle()
        #expect(try version() > v0)
        #expect(engine.appliedGraphs.last?.audioClips.filter { $0.player == player }.count == 3)

        let v1 = try version()
        try store.perform(SetClipGain(clipID: p.gtr.clips[0].id, gain: 0.5))
        await sync.settle()
        #expect(try version() > v1, "clip gain is clip data, so the player is re-created")

        try store.perform(SetTempoEvent(tick: 3840, bpm: 90))
        await sync.settle()
        #expect(engine.appliedGraphs.last?.tempoEvents == [TempoEvent(tick: 0, bpm: 120), TempoEvent(tick: 3840, bpm: 90)])

        let applied = engine.appliedGraphs.count
        try store.perform(SetLoop(start: 0, end: 3840))
        await sync.settle()
        #expect(engine.appliedGraphs.count == applied, "the loop isn't part of the graph")
        store.undo()
        store.undo()
        await sync.settle()
        #expect(engine.appliedGraphs.last?.tempoEvents == [TempoEvent(tick: 0, bpm: 120)])
    }
}

extension Clip {
    var midiNotes: [Note] {
        if case .midi(let clip) = self { clip.notes } else { [] }
    }
}

/// Half of these name real tracks and clips; the rest pick from all IDs or a missing one.
func randomClipCommand(for project: Project, using rng: inout SplitMix64) -> any Command {
    let tracks = project.tracks.map(\.id)
    let clips = project.tracks.flatMap(\.clips).map(\.id)
    let assets = project.assets.map(\.id)
    let anything = tracks + clips + assets + [project.master.id, 999]
    func pick(_ ids: [ModelID]) -> ModelID {
        (Bool.random(using: &rng) ? ids.randomElement(using: &rng) : nil) ?? anything.randomElement(using: &rng)!
    }
    func tick(_ max: Int64 = 12_000) -> Tick { Tick(Int64.random(in: -100...max, using: &rng)) }
    func length() -> Tick { Tick([0, 1, 100, 960, 3840, 5000].randomElement(using: &rng)!) }

    switch Int.random(in: 0..<16, using: &rng) {
    case 0, 1:
        let audio = Bool.random(using: &rng)
        return AddClip(trackID: pick(tracks), start: tick(), length: Bool.random(using: &rng) ? length() : nil,
                       assetID: audio ? pick(assets) : nil,
                       sourceOffsetSamples: audio && Bool.random(using: &rng) ? Int64.random(in: -10...100_000, using: &rng) : nil,
                       gain: audio && Bool.random(using: &rng) ? 0.5 : nil)
    case 2: return RemoveClip(clipID: pick(clips))
    case 3, 4: return MoveClip(clipID: pick(clips), start: tick(), trackID: Bool.random(using: &rng) ? pick(tracks) : nil)
    case 5, 6: return ResizeClip(clipID: pick(clips), start: tick(), length: length())
    case 7, 8: return SplitClip(clipID: pick(clips), at: tick())
    case 9: return SetClipGain(clipID: pick(clips), gain: [0, 0.5, 1, 4, -1].randomElement(using: &rng)!)
    case 10: return SetClipFades(clipID: pick(clips), fadeIn: tick(4000), fadeOut: tick(4000))
    case 11: return SetTempoEvent(tick: tick(), bpm: [0, 60, 90, 120, 240, 1200].randomElement(using: &rng)!)
    case 12:
        let ticks = project.tempoMap.tempoEvents.map(\.tick)
        return RemoveTempoEvent(tick: Bool.random(using: &rng) ? ticks.randomElement(using: &rng)! : tick())
    case 13:
        return SetTimeSignature(tick: tick(), numerator: [0, 3, 4, 7].randomElement(using: &rng)!,
                                denominator: [3, 4, 8].randomElement(using: &rng)!)
    case 14:
        let ticks = project.tempoMap.timeSignatures.map(\.tick)
        return RemoveTimeSignature(tick: Bool.random(using: &rng) ? ticks.randomElement(using: &rng)! : tick())
    default:
        return Int.random(in: 0..<5, using: &rng) == 0
            ? SetLoop(loop: nil) : SetLoop(start: tick(), end: tick(), isEnabled: Bool.random(using: &rng))
    }
}
