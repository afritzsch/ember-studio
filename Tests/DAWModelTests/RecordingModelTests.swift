import Foundation
import Testing

@testable import DAWModel

// T-052 model side: ArmTrack / SetMonitoring (MODEL-005, REC-001), Track.inputPair, engine sync of
// arming and the recordings directory (REC-001, REC-002), and a finished take becoming one
// undoable ImportAsset + AddClip (REC-003, REC-004).

@Suite("Recording, model side (REC-001..004, MODEL-005)")
@MainActor
struct RecordingModelTests {
    init() { TestCommands.register() }

    /// 48 kHz, 120 bpm (one tick = 25 samples), an audio track "Mic" and a MIDI track "Keys".
    private func project() -> Project {
        var p = Project(id: GraphFixtures.fixedID, name: "rec")
        p.tracks = [
            Track(id: p.ids.allocate(), name: "Mic", kind: .audio),
            Track(id: p.ids.allocate(), name: "Keys", kind: .midi),
        ]
        return p
    }

    private func attached(_ project: Project) throws -> (ProjectStore, FakeEngine, EngineSync) {
        let store = ProjectStore(project: project)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        return (store, engine, sync)
    }

    private func arms(_ engine: FakeEngine) -> [FakeEngine.Call] {
        engine.calls.filter { if case .armInput = $0 { true } else { false } }
    }

    private func take(_ track: NodeIDValue, start: SamplePos, frames: Int64 = 48_000, rate: Double = 48_000,
                      file: String = "/tmp/rec/Track 1 Take 1.caf") -> RecordedTake
    {
        RecordedTake(track: track, file: file, startSample: start, frames: frames, sampleRate: rate)
    }

    // MARK: Commands

    @Test("MODEL-005, REC-001: ArmTrack and SetMonitoring are persisted and dirty, never in undo history")
    func historyExempt() throws {
        let store = ProjectStore(project: project())
        let mic = store.project.tracks[0].id
        try store.perform(RenameTrack(trackID: mic, name: "Vox"))
        let label = store.undoLabel
        try store.perform(ArmTrack(trackID: mic, armed: true, inputPair: 3))
        try store.perform(SetMonitoring(trackID: mic, mode: .auto))
        #expect(store.project.tracks[0].armed && store.project.tracks[0].inputPair == 3)
        #expect(store.project.tracks[0].monitoring == .auto && store.isDirty)
        #expect(store.undoLabel == label, "neither left an undo entry")
        store.undo()
        #expect(store.project.tracks[0].name == "Mic", "undo steps over them")
        #expect(store.project.tracks[0].armed && store.project.tracks[0].inputPair == 3)
        #expect(store.project.tracks[0].monitoring == .auto)
        // Leaving inputPair out keeps the track's.
        try store.perform(ArmTrack(trackID: mic, armed: false))
        #expect(!store.project.tracks[0].armed && store.project.tracks[0].inputPair == 3)
        #expect(throws: DAWError.self) { try store.perform(CompositeCommand("x", [ArmTrack(trackID: mic, armed: true)])) }
    }

    @Test("MODEL-005: ArmTrack refuses an input pair past Track.maxInputPair and an unknown track; inverses restore")
    func armValidation() throws {
        var p = project()
        let mic = p.tracks[0].id
        let before = p
        #expect(throws: DAWError.self) { _ = try ArmTrack(trackID: mic, armed: true, inputPair: 16).apply(to: &p) }
        #expect(throws: DAWError.self) { _ = try ArmTrack(trackID: 999, armed: true).apply(to: &p) }
        #expect(throws: DAWError.self) { _ = try SetMonitoring(trackID: 999, mode: .on).apply(to: &p) }
        #expect(p == before)
        let undoArm = try ArmTrack(trackID: mic, armed: true, inputPair: Track.maxInputPair).apply(to: &p)
        let undoMonitor = try SetMonitoring(trackID: mic, mode: .on).apply(to: &p)
        #expect(p.tracks[0].inputPair == 15 && p.tracks[0].monitoring == .on)
        _ = try undoMonitor.apply(to: &p)
        _ = try undoArm.apply(to: &p)
        #expect(p == before)
    }

    @Test("MODEL-040: Track.inputPair round-trips and defaults to 0 in a project saved before T-052")
    func inputPairDecoding() throws {
        var track = Track(id: 4, name: "Mic", kind: .audio)
        track.inputPair = 2
        track.armed = true
        let data = try JSONEncoder().encode(track)
        #expect(try JSONDecoder().decode(Track.self, from: data) == track)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["inputPair"] as? Int == 2)
        object["inputPair"] = nil
        let old = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.inputPair == 0)
        track.inputPair = 0
        #expect(old == track)
    }

    // MARK: Engine sync

    @Test("REC-001, REC-022: arming an audio track calls armInput with its pair; a pair change re-arms; removal disarms; MIDI isn't device input")
    func armSync() async throws {
        let (store, engine, _) = try attached(project())
        let mic = store.project.tracks[0].id
        let keys = store.project.tracks[1].id
        #expect(arms(engine).isEmpty)

        try store.perform(ArmTrack(trackID: mic, armed: true, inputPair: 1))
        try store.perform(ArmTrack(trackID: keys, armed: true))
        #expect(arms(engine) == [.armInput(track: mic, pair: 1, armed: true)])
        #expect(engine.telemetry().armedTracks == 1)

        engine.clearCalls()
        try store.perform(SetMonitoring(trackID: mic, mode: .on))
        try store.perform(RenameTrack(trackID: mic, name: "Vox"))
        #expect(arms(engine).isEmpty, "nothing else re-arms")

        try store.perform(ArmTrack(trackID: mic, armed: true, inputPair: 2))
        #expect(arms(engine) == [.armInput(track: mic, pair: 2, armed: true)])

        engine.clearCalls()
        try store.perform(RemoveTrack(trackID: mic))
        #expect(arms(engine) == [.armInput(track: mic, pair: 2, armed: false)])
        #expect(engine.telemetry().armedTracks == 0)

        engine.clearCalls()
        store.undo()
        #expect(arms(engine) == [.armInput(track: mic, pair: 2, armed: true)], "the restored track is armed again")
    }

    @Test("REC-001: a project opened with an armed track arms it on attach; detaching disarms")
    func armOnAttachAndDetach() throws {
        var p = project()
        p.tracks[0].armed = true
        p.tracks[0].inputPair = 4
        let (store, engine, sync) = try attached(p)
        let mic = store.project.tracks[0].id
        #expect(arms(engine) == [.armInput(track: mic, pair: 4, armed: true)])
        engine.clearCalls()
        sync.invalidate()
        #expect(arms(engine) == [.armInput(track: mic, pair: 4, armed: false)])
    }

    @Test("REC-002: takes of an unsaved project go to a per-project temp folder, of a saved one to <folder>/Audio/Recordings; pushed before recording starts")
    func recordingDirectory() async throws {
        let (store, engine, sync) = try attached(project())
        let temp = EngineSync.temporaryRecordingsDirectory(for: store.project)
        #expect(temp.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(temp.lastPathComponent == "\(store.project.id.uuidString)-\(ProcessInfo.processInfo.processIdentifier)")
        #expect(sync.recordingsDirectory() == temp)

        engine.clearCalls()
        sync.setRecording(true)
        #expect(engine.calls == [.setRecordingDirectory(temp.path), .setRecording(true)])
        engine.clearCalls()
        sync.setRecording(false)
        #expect(engine.calls == [.setRecording(false)])

        let folder = FileManager.default.temporaryDirectory.appending(path: "recdir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.save(to: folder)
        let saved = folder.appendingPathComponent("Audio/Recordings", isDirectory: true)
        #expect(sync.recordingsDirectory().standardizedFileURL.path == saved.standardizedFileURL.path)
        engine.clearCalls()
        sync.setRecording(true)
        #expect(engine.recordingDirectory == sync.recordingsDirectory().path)
        #expect(engine.calls.last == .setRecording(true))
    }

    // MARK: REC-003 placement, REC-004 import

    @Test("REC-003: the clip starts on the first tick at or after startSample and skips the frames before it")
    func placement() throws {
        let p = project()
        let mic = p.tracks[0].id
        let asset = AssetRef(id: 50, path: "a.caf", channels: 2, originalSampleRate: 48_000, frames: 48_000)
        func clip(_ take: RecordedTake) throws -> (Tick, SamplePos) {
            let command = try #require(RecordingImport.command(for: take, asset: asset, in: p))
            let add = try #require(command.commands[1] as? AddClip)
            #expect(add.trackID == mic && add.assetID == 50)
            return (add.start, add.sourceOffsetSamples ?? -1)
        }
        #expect(try clip(take(mic, start: 24_000)) == (960, 0))
        #expect(try clip(take(mic, start: 24_010)) == (961, 15), "tick 961 is sample 24025")
        #expect(try clip(take(mic, start: 24_001)) == (961, 24))
        #expect(try clip(take(mic, start: 0)) == (0, 0))
        #expect(try clip(take(mic, start: -595)) == (0, 595), "frames recorded before 0 are skipped")
        // A take recorded at 44.1 kHz in a project now at 48 kHz scales its position.
        #expect(try clip(take(mic, start: 22_050, frames: 44_100, rate: 44_100)) == (960, 0))
        // Nothing that would play: no frames, no file, all before 0.
        #expect(RecordingImport.command(for: take(mic, start: 0, frames: 0), asset: asset, in: p) == nil)
        #expect(RecordingImport.command(for: take(mic, start: 0, file: ""), asset: asset, in: p) == nil)
        #expect(RecordingImport.command(for: take(mic, start: -48_000), asset: asset, in: p) == nil)
    }

    @Test("REC-004: a recordingFinalized event becomes one undoable \"Record\" (ImportAsset + AddClip); the engine loads the file under the asset's ID")
    func importOnEvent() async throws {
        let (store, engine, sync) = try attached(project())
        let mic = store.project.tracks[0].id
        let next = store.project.ids.next
        // A file that exists: a missing one would be an offline asset with no load (MODEL-046).
        let dir = FileManager.default.temporaryDirectory.appending(path: "recevent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "Track \(mic) Take 1.caf").path
        try Data([0]).write(to: URL(fileURLWithPath: file))
        engine.clearCalls()
        engine.post(EngineEvent(recording: take(mic, start: 24_010, frames: 72_000, file: file)))
        let events = sync.pollEvents()
        #expect(events.contains { $0.kind == .recordingFinalized && $0.recording?.track == mic })

        let asset = try #require(store.project.assets.first { $0.id == next })
        #expect(asset.path == file, "absolute: the project has no folder")
        #expect(asset.channels == 2 && asset.frames == 72_000 && asset.originalSampleRate == 48_000)
        let clip = try #require(store.project.tracks[0].clips.first)
        guard case .audio(let audio) = clip else { Issue.record("not an audio clip"); return }
        #expect(audio.assetID == next && audio.start == 961 && audio.sourceOffsetSamples == 15)
        #expect(engine.calls.contains(.loadAsset(next, path: file)))
        #expect(store.undoLabel == "Record" && store.isDirty)
        await sync.settleLoads()

        store.undo()
        #expect(store.project.assets.isEmpty && store.project.tracks[0].clips.isEmpty, "one undo removes both")
        store.redo()
        #expect(store.project.assets.count == 1 && store.project.tracks[0].clips.count == 1)
    }

    @Test("REC-004: a take inside the project folder gets a relative path; one for a missing or MIDI track isn't imported")
    func importPathsAndRefusals() async throws {
        let (store, _, _) = try attached(project())
        let folder = FileManager.default.temporaryDirectory.appending(path: "recimport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.save(to: folder)
        let mic = store.project.tracks[0].id
        let keys = store.project.tracks[1].id
        let file = folder.appendingPathComponent("Audio/Recordings/Track \(mic) Take 1.caf").path
        let id = try #require(try store.importRecording(take(mic, start: 0, file: file)))
        #expect(store.project.assets.first { $0.id == id }?.path == "Audio/Recordings/Track \(mic) Take 1.caf")

        let before = store.project
        #expect(throws: DAWError.self) { try store.importRecording(take(keys, start: 0)) }
        #expect(throws: DAWError.self) { try store.importRecording(take(999, start: 0)) }
        #expect(try store.importRecording(take(mic, start: 0, frames: 0)) == nil)
        #expect(store.project == before)
    }
}
