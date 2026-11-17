import Foundation
import os

/// REC-004 (T-052): turns a finished take (`recordingFinalized`, `RecordedTake`) into one undoable
/// edit: `ImportAsset` of the take's file plus `AddClip` on its track, as a single
/// `CompositeCommand` ("Record"). Undo removes both; the file stays on disk. REC-030 (T-080): a
/// loop recording of two passes or more gets `CreateTakeFolder` in place of `AddClip`, in the same
/// composite (one undo step), one take per pass, all of them views into the one file.
///
/// Placement (REC-003). The engine reports `startSample`, the timeline sample of the file's first
/// frame, latency already compensated. Clips start on ticks, so the clip starts at the first tick
/// at or after that sample, and `sourceOffsetSamples` skips the frames before it: the file's
/// frame k still plays at sample `startSample + k`, exactly (a take that starts before 0 starts
/// at tick 0 with the frames before 0 skipped). At most one tick's worth of frames is hidden at
/// the start (25 samples at 120 bpm, 48 kHz), which a left trim can uncover.
public enum RecordingImport {
    /// The command for `take` as asset `asset` in `project`, or nil when the take holds nothing
    /// that would play (no file, no frames, or everything before 0).
    public static func command(for take: RecordedTake, asset: AssetRef, in project: Project) -> CompositeCommand? {
        guard !take.file.isEmpty, take.frames > 0, take.sampleRate > 0 else { return nil }
        // REC-030 (T-080): a loop recording of two passes or more becomes a take folder.
        if let folder = takeFolderCommand(for: take, asset: asset, in: project) {
            return CompositeCommand("Record", [ImportAsset(asset: asset), folder])
        }
        let rate = project.sessionSampleRate
        // The session rate can have changed since the take was recorded (the asset is converted
        // to it in RAM, D-27); its timeline position scales with it.
        let start = take.sampleRate == rate
            ? take.startSample
            : SamplePos((Double(take.startSample) * rate / take.sampleRate).rounded())
        let frames = Int64((Double(take.frames) * rate / take.sampleRate).rounded())
        let tick = start <= 0 ? Tick(0) : Tick(project.tempoMap.sampleToTick(start - 1).raw + 1)
        let offset = project.tempoMap.tickToSample(tick) - start
        guard offset >= 0, offset < frames else { return nil }
        return CompositeCommand("Record", [
            ImportAsset(asset: asset),
            AddClip(trackID: take.track, start: tick, assetID: asset.id, sourceOffsetSamples: offset),
        ])
    }

    /// REC-012 (T-053): the command for a MIDI take, `AddClip` plus `AddNotes` as one composite,
    /// or nil when no note would land on the timeline. A note starts at the tick nearest its
    /// sample (clips and notes live in ticks, and exact ticks round-trip); one that began before
    /// 0 starts at 0, and one wholly before 0 is dropped. The clip runs from the compensated
    /// record start to the stop, far enough to hold every note, at least one tick.
    public static func midiCommand(for take: RecordedTake, in project: Project) -> CompositeCommand? {
        guard let recorded = take.notes, !recorded.isEmpty, take.sampleRate > 0 else { return nil }
        let rate = project.sessionSampleRate
        let map = project.tempoMap
        // The session rate can have changed since it was recorded, like audio takes.
        func scaled(_ sample: SamplePos) -> SamplePos {
            take.sampleRate == rate ? sample : SamplePos((Double(sample) * rate / take.sampleRate).rounded())
        }
        func nearestTick(_ sample: SamplePos) -> Int64 {
            guard sample > 0 else { return 0 }
            let before = map.sampleToTick(sample)
            let after = Tick(before.raw + 1)
            return abs(map.tickToSample(after) - sample) < abs(map.tickToSample(before) - sample) ? after.raw : before.raw
        }

        var notes: [(start: Int64, length: Int64, note: RecordedMidiNote)] = []
        for note in recorded {
            let end = scaled(note.end)
            guard end > 0 else { continue }  // over before the timeline begins
            let start = nearestTick(max(scaled(note.start), 0))
            let length = max(nearestTick(end) - start, 1)
            notes.append((start, length, note))
        }
        guard let firstStart = notes.map(\.start).min(), let lastEnd = notes.map({ $0.start + $0.length }).max() else { return nil }
        let clipStart = min(nearestTick(max(scaled(take.startSample), 0)), firstStart)
        let clipEnd = max(nearestTick(scaled(take.endSample ?? take.startSample)), lastEnd)

        let specs = notes.map {
            AddNotes.NoteSpec(start: Tick($0.start - clipStart), length: Tick($0.length), pitch: $0.note.pitch,
                              velocity: $0.note.velocity, channel: $0.note.channel)
        }
        return CompositeCommand("Record", [
            AddClip(trackID: take.track, start: Tick(clipStart), length: Tick(max(clipEnd - clipStart, 1))),
            AddNotes(clipID: project.ids.next, notes: specs),  // AddClip claims this ID
        ])
    }

    /// REC-030 (T-080): the take folder of an audio loop recording, or nil when it has fewer than
    /// two passes that land on the timeline. Pass i is the file's frames `[passStarts[i],
    /// passStarts[i + 1])` (the last one to the end of the file, possibly partial); the first plays
    /// from `startSample`, every other one from the loop start. Each becomes a take: a clip view
    /// into the file placed like a plain take (the first tick at or after its sample, the offset
    /// skipping the frames before it), ending at the first tick at or after its last frame.
    public static func takeFolderCommand(for take: RecordedTake, asset: AssetRef, in project: Project) -> CreateTakeFolder? {
        guard take.passStarts.count >= 2, take.frames > 0, take.sampleRate > 0 else { return nil }
        let rate = project.sessionSampleRate
        let map = project.tempoMap
        func scaled(_ sample: SamplePos) -> SamplePos {
            take.sampleRate == rate ? sample : SamplePos((Double(sample) * rate / take.sampleRate).rounded())
        }
        func tickAtOrAfter(_ sample: SamplePos) -> Tick {
            sample <= 0 ? Tick(0) : Tick(map.sampleToTick(sample - 1).raw + 1)
        }
        let frames = scaled(take.frames)
        var specs: [CreateTakeFolder.TakeSpec] = []
        for (i, passStart) in take.passStarts.enumerated() {
            let from = scaled(passStart)
            let until = i + 1 < take.passStarts.count ? scaled(take.passStarts[i + 1]) : frames
            let at = i == 0 ? scaled(take.startSample) : scaled(take.loopStartSample)  // timeline sample of `from`
            let start = tickAtOrAfter(at)
            let offset = from + map.tickToSample(start) - at
            guard until > from, offset >= from, offset < until else { continue }  // all before 0 (or empty)
            let end = tickAtOrAfter(at + (until - from))
            specs.append(CreateTakeFolder.TakeSpec(start: start, length: Tick(max(end.raw - start.raw, 1)),
                                                   assetID: asset.id, sourceOffsetSamples: offset))
        }
        guard specs.count >= 2 else { return nil }
        return CreateTakeFolder(trackID: take.track, takes: specs)
    }

    /// REC-034 (T-080): with the `midiLoopTakes` record option, a MIDI loop recording of two passes
    /// or more becomes a take folder, one take per pass (a pass without notes is an empty take).
    /// Pass 0 runs from the record start, every other one from the loop start; all but the last end
    /// at the loop end, the last at the stop. Each take is placed like a merged MIDI take
    /// (`midiCommand`): notes and the take's ends at their nearest ticks, the take at least one
    /// tick long and long enough for its notes. nil without the option or with one pass; then
    /// `midiCommand` merges (the default).
    public static func midiTakeFolderCommand(for take: RecordedTake, in project: Project) -> CompositeCommand? {
        guard take.midiLoopTakes, take.passes >= 2, let recorded = take.notes, take.sampleRate > 0 else { return nil }
        let rate = project.sessionSampleRate
        let map = project.tempoMap
        func scaled(_ sample: SamplePos) -> SamplePos {
            take.sampleRate == rate ? sample : SamplePos((Double(sample) * rate / take.sampleRate).rounded())
        }
        func nearestTick(_ sample: SamplePos) -> Int64 {
            guard sample > 0 else { return 0 }
            let before = map.sampleToTick(sample)
            let after = Tick(before.raw + 1)
            return abs(map.tickToSample(after) - sample) < abs(map.tickToSample(before) - sample) ? after.raw : before.raw
        }
        let last = take.passes - 1
        var specs: [CreateTakeFolder.TakeSpec] = []
        for pass in 0...last {
            let from = pass == 0 ? scaled(take.startSample) : scaled(take.loopStartSample)
            let until = pass == last ? scaled(take.endSample ?? take.startSample) : scaled(take.loopEndSample)
            var notes: [(start: Int64, length: Int64, note: RecordedMidiNote)] = []
            for note in recorded where note.pass == pass {
                let end = scaled(note.end)
                guard end > 0 else { continue }
                let start = nearestTick(max(scaled(note.start), 0))
                notes.append((start, max(nearestTick(end) - start, 1), note))
            }
            guard until > 0 || !notes.isEmpty else { continue }  // a pass wholly before the timeline
            let clipStart = min(nearestTick(max(from, 0)), notes.map(\.start).min() ?? .max)
            let clipEnd = max(nearestTick(until), notes.map { $0.start + $0.length }.max() ?? 0)
            specs.append(CreateTakeFolder.TakeSpec(
                start: Tick(clipStart), length: Tick(max(clipEnd - clipStart, 1)),
                notes: notes.map {
                    AddNotes.NoteSpec(start: Tick($0.start - clipStart), length: Tick($0.length), pitch: $0.note.pitch,
                                      velocity: $0.note.velocity, channel: $0.note.channel)
                }))
        }
        guard specs.count >= 2 else { return nil }
        return CompositeCommand("Record", [CreateTakeFolder(trackID: take.track, takes: specs)])
    }
}

extension ProjectStore {
    private static let recordingLog = Logger(subsystem: "dev.emberstudio", category: "recording")

    /// REC-004: loads the take into the attached engine under the next model ID and performs
    /// `RecordingImport.command` (one undo entry). The asset's path is relative when the file is
    /// inside the project folder (`Audio/Recordings/…`), otherwise absolute (a project without a
    /// folder; a save copies it into `Audio/`, DW-124). Returns the asset ID, or nil when there is
    /// nothing to import. Throws if the track is gone or isn't an audio track.
    @discardableResult
    public func importRecording(_ take: RecordedTake) throws(DAWError) -> ModelID? {
        guard let track = project.track(take.track) else { throw .notFound(kind: "track", id: take.track) }
        guard track.kind == .audio else { throw .invalidArgument("track \(take.track) isn't an audio track") }
        let file = URL(fileURLWithPath: take.file)
        let id = project.ids.next  // ImportAsset claims it (MODEL-005, DW-105)
        let path = folderURL.flatMap { ProjectFolder.relativePath(of: file, inside: $0) } ?? file.path
        let asset = AssetRef(id: id, path: path, channels: Int(take.channels), originalSampleRate: take.sampleRate,
                             frames: take.frames)
        guard let command = RecordingImport.command(for: take, asset: asset, in: project) else { return nil }
        // The engine loads under the ID first, like asset.import; its assetLoaded event makes the
        // clip player pick it up (DW-072).
        if let sync = engineSync {
            for load in sync.loadAssets([asset], folder: folderURL) { load.job.map(sync.trackLoad) }
        }
        try perform(command)
        return id
    }

    /// REC-012 (T-053): turns a MIDI take into a clip with its notes (one undo entry). Returns the
    /// clip's ID, or nil when no note lands on the timeline. Throws if the track is gone or isn't a
    /// MIDI track. REC-034 (T-080): a loop take recorded with `midiLoopTakes` becomes a take folder
    /// instead (`RecordingImport.midiTakeFolderCommand`); the folder's ID is returned.
    @discardableResult
    public func importMidiRecording(_ take: RecordedTake) throws(DAWError) -> ModelID? {
        guard let track = project.track(take.track) else { throw .notFound(kind: "track", id: take.track) }
        guard track.kind == .midi else { throw .invalidArgument("track \(take.track) isn't a MIDI track") }
        if let folder = RecordingImport.midiTakeFolderCommand(for: take, in: project) {
            let folderID = project.ids.next  // CreateTakeFolder allocates it first
            try perform(folder)
            return folderID
        }
        guard let command = RecordingImport.midiCommand(for: take, in: project) else { return nil }
        let clipID = project.ids.next
        try perform(command)
        return clipID
    }

    /// T-052: what `attachEngine` hooks up: the recordings folder follows `folderURL`, and each
    /// finished take is imported. A take that can't be imported is logged; its file stays.
    func connectRecording(_ sync: EngineSync) {
        sync.projectFolder = { [weak self] in self?.folderURL }
        sync.onRecordingFinalized = { [weak self] take, error in
            if let error { Self.recordingLog.error("take on track \(take.track): \(error)") }
            do {
                if take.isMidi { try self?.importMidiRecording(take) } else { try self?.importRecording(take) }  // T-053
            } catch {
                Self.recordingLog.error("couldn't import the take \(take.file): \(error)")
            }
        }
    }
}
