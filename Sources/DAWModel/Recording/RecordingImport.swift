import Foundation
import os

/// REC-004 (T-052): turns a finished take (`recordingFinalized`, `RecordedTake`) into one undoable
/// edit: `ImportAsset` of the take's file plus `AddClip` on its track, as a single
/// `CompositeCommand` ("Record"). Undo removes both; the file stays on disk.
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

    /// T-052: what `attachEngine` hooks up: the recordings folder follows `folderURL`, and each
    /// finished take is imported. A take that can't be imported is logged; its file stays.
    func connectRecording(_ sync: EngineSync) {
        sync.projectFolder = { [weak self] in self?.folderURL }
        sync.onRecordingFinalized = { [weak self] take, error in
            if let error { Self.recordingLog.error("take on track \(take.track): \(error)") }
            do {
                try self?.importRecording(take)
            } catch {
                Self.recordingLog.error("couldn't import the take \(take.file): \(error)")
            }
        }
    }
}
