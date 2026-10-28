import Foundation
import Synchronization
import Testing

@testable import DAWModel

// MODEL-040..046 (T-031): the project folder, atomic save, migrations, plugin-state files,
// autosave, recovery and offline assets, in process. Killing a real process mid-save and
// recovering after a crash are in ProjectCrashTests.

/// A fresh folder under $TMPDIR (CONV §9), removed by `remove()`.
struct TempFolder {
    let url: URL

    init(_ prefix: String) throws {
        url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// A mono 32-bit float WAV of a 1 kHz sine at half scale, 48 kHz.
func writeSineWAV(_ url: URL, frames: Int) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 4))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(3)); append(UInt16(1))
    append(UInt32(48_000)); append(UInt32(192_000)); append(UInt16(4)); append(UInt16(32))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 4))
    for i in 0..<frames { append(Float(0.5 * sin(2 * Double.pi * 1000 * Double(i) / 48_000)).bitPattern) }
    try data.write(to: url)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Polls `condition` until it holds or `timeout` passes.
@MainActor
private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@Suite("Persistence (MODEL-040..046)")
@MainActor
struct PersistenceTests {
    init() { TestCommands.register() }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: GraphFixtures.fixturesDir.appending(path: "projects/\(name).json"))
    }

    /// A project folder holding `fixture` as its project.json.
    private func folder(with fixture: String, in temp: TempFolder) throws -> URL {
        let folder = temp.url.appending(path: "\(fixture).dawproject")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try self.fixture(fixture).write(to: folder.appending(path: "project.json"))
        return folder
    }

    /// Opens `folder` with autosave off.
    private func open(_ folder: URL, recover: Bool = false) async throws -> ProjectStore {
        let store = try await ProjectStore.open(folder, recover: recover)
        store.autosavePolicy = nil
        return store
    }

    // MARK: MODEL-040

    @Test("MODEL-040: save writes Name.dawproject/ with a pretty, key-sorted project.json, Audio/, Plugins/ and Cache/; open reads it back")
    func folderLayout() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        let folder = temp.url.appending(path: "Song.dawproject")
        let store = ProjectStore(project: try GraphFixtures.project(named: "routing"))
        store.autosavePolicy = nil
        try store.perform(AddTrack(name: "New", kind: .midi))
        #expect(store.isDirty && store.folderURL == nil)

        try await store.save(to: folder)
        #expect(!store.isDirty && store.folderURL == folder)
        for name in ["Audio", "Plugins", "Cache"] {
            var isFolder: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path, isDirectory: &isFolder) && isFolder.boolValue, "\(name)/")
        }
        #expect(!exists(folder.appending(path: "autosave")), "autosave/ only appears when autosaving")
        #expect(!exists(folder.appending(path: "project.json.tmp")))

        let data = try Data(contentsOf: folder.appending(path: "project.json"))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.hasPrefix("{\n  \"assets\" : "), "pretty-printed, keys sorted")
        #expect(text.contains("\"formatVersion\" : \(Project.currentFormatVersion)"))
        let keys = text.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map { $0.split(separator: "\"")[1] }
        #expect(keys == keys.sorted() && keys.contains("formatVersion"))
        #expect(data == (try ProjectFile.encode(store.project)), "the same project gives the same bytes")

        let reopened = try await open(folder)
        #expect(reopened.project == store.project)
        #expect(reopened.project.ids == store.project.ids, "the allocator is persisted too")
        #expect(reopened.folderURL == folder && !reopened.isDirty)
        #expect(reopened.loadReport == ProjectLoadReport())

        // save(to: nil) goes back to the same folder.
        try reopened.perform(RenameTrack(trackID: reopened.project.tracks[0].id, name: "Renamed"))
        try await reopened.save(to: nil)
        #expect(try await open(folder).project.tracks[0].name == "Renamed")
    }

    @Test("MODEL-040: a project that was never saved needs a path")
    func saveWithoutFolder() async throws {
        let store = ProjectStore()
        await #expect(throws: DAWError.self) { try await store.save(to: nil) }
        await #expect(throws: DAWError.self) {
            _ = try await ProjectStore.open(URL(fileURLWithPath: "/nonexistent/x.dawproject"), recover: false)
        }
    }

    @Test("MODEL-040: every fixture project opens from a folder unchanged")
    func fixturesOpen() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        for name in GraphFixtures.names {
            let store = try await open(folder(with: name, in: temp))
            #expect(store.project == (try GraphFixtures.project(named: name)), "\(name)")
            #expect(store.loadReport.migratedFrom == nil && store.loadReport.repairs.isEmpty)
        }
    }

    // MARK: MODEL-041

    @Test("MODEL-041: save replaces project.json through project.json.tmp; a leftover tmp from a crash is ignored and replaced")
    func atomicReplace() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        let folder = temp.url.appending(path: "A.dawproject")
        let store = ProjectStore(project: Project(name: "one"))
        store.autosavePolicy = nil
        try await store.save(to: folder)

        // What a save killed mid-write leaves: a partial tmp file next to the intact project.json.
        let tmp = folder.appending(path: "project.json.tmp")
        try Data("{\"formatVersion\": 1, \"na".utf8).write(to: tmp)
        #expect(try await open(folder).project.name == "one")

        try store.perform(AddTrack(name: "T", kind: .audio))
        try await store.save(to: nil)
        #expect(!exists(tmp), "the next save renames its own tmp over project.json")
        #expect(try await open(folder).project.tracks.count == 1)
    }

    @Test("MODEL-041: a save that can't write leaves the old project.json as it was")
    func failedSaveKeepsOldFile() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        let folder = temp.url.appending(path: "A.dawproject")
        let store = ProjectStore(project: Project(name: "one"))
        store.autosavePolicy = nil
        try await store.save(to: folder)
        let before = try Data(contentsOf: folder.appending(path: "project.json"))

        // The tmp path is taken by a folder, so the write fails before anything is renamed.
        try FileManager.default.createDirectory(at: folder.appending(path: "project.json.tmp"), withIntermediateDirectories: false)
        try store.perform(AddTrack(name: "T", kind: .audio))
        await #expect(throws: DAWError.self) { try await store.save(to: nil) }
        #expect(try Data(contentsOf: folder.appending(path: "project.json")) == before)
        #expect(store.isDirty, "still unsaved")
    }

    // MARK: MODEL-042

    /// The dummy v1 → v2 step: tracks' `title` became `name`.
    private nonisolated static let titleToName: Migrations.Step = { json in
        guard var tracks = json["tracks"]?.arrayValue else { return }
        for i in tracks.indices {
            tracks[i]["name"] = tracks[i]["title"]
            tracks[i]["title"] = nil
        }
        json["tracks"] = .array(tracks)
    }

    @Test("MODEL-042: migrations run in order from the file's version; the v1 fixture becomes the v2 fixture")
    func migrationV1toV2() throws {
        var json = try JSON(parsing: fixture("migration_v1"))
        let original = try Migrations.migrate(&json, to: 2, steps: [1: Self.titleToName])
        #expect(original == 1)
        #expect(json == (try JSON(parsing: fixture("migration_v2"))))

        // The decode path open uses: migrate, then decode as a Project.
        let (project, migratedFrom) = try ProjectFile.decode(fixture("migration_v1"), currentVersion: 2, steps: [1: Self.titleToName])
        #expect(migratedFrom == 1)
        #expect(project == (try ProjectFile.decode(fixture("migration_v2"), currentVersion: 2).project))
        #expect(project.tracks.map(\.name) == ["Drums", "Empty"])

        // Steps chain: v1 → v2 → v3, each stamping its version.
        var chained = try JSON(parsing: fixture("migration_v1"))
        let order = Mutex<[Int]>([])
        try Migrations.migrate(&chained, to: 3, steps: [
            1: { json in order.withLock { $0.append(1) }; try Self.titleToName(&json) },
            2: { json in order.withLock { $0.append(json["formatVersion"]?.intValue.map(Int.init) ?? 0) } },
        ])
        #expect(order.withLock { $0 } == [1, 2] && chained["formatVersion"] == .int(3))
    }

    @Test("MODEL-042: a newer file, a missing step, a failing step and a missing formatVersion are rejected")
    func migrationErrors() throws {
        struct Broken: Error {}
        let v1 = try fixture("migration_v1")
        func isInvalidProject(_ body: () throws -> Void) -> Bool {
            do { try body() } catch let error as DAWError { if case .invalidProject = error { return true } } catch {}
            return false
        }
        #expect(isInvalidProject { _ = try ProjectFile.decode(v1, currentVersion: 2, steps: [:]) }, "no step from 1")
        #expect(isInvalidProject { _ = try ProjectFile.decode(fixture("migration_v2"), currentVersion: 1) }, "newer than this build")
        #expect(isInvalidProject { _ = try ProjectFile.decode(v1, currentVersion: 2, steps: [1: { _ in throw Broken() }]) })
        var json = try JSON(parsing: v1)
        json["formatVersion"] = nil
        let noVersion = try json.encoded()
        #expect(isInvalidProject { _ = try ProjectFile.decode(noVersion) })
        #expect(isInvalidProject { _ = try ProjectFile.decode(Data("not json".utf8)) })
        #expect(Migrations.steps.keys.allSatisfy { $0 < Project.currentFormatVersion })
    }

    @Test("MODEL-042: JSON keeps 64-bit integers exact and round-trips a project file")
    func jsonRoundTrip() throws {
        let big = Int64(GraphNodeID.maxModelID)
        let json = try JSON(parsing: Data("{\"a\": \(big), \"b\": 0.25, \"c\": [true, null, \"x\"], \"d\": 48000}".utf8))
        #expect(json["a"] == .int(big) && json["b"] == .double(0.25) && json["d"] == .int(48_000))
        #expect(json["c"] == .array([.bool(true), .null, .string("x")]))
        let file = try fixture("midi_tempo")
        let decoded = try JSONDecoder().decode(Project.self, from: try JSON(parsing: file).encoded())
        #expect(decoded == (try GraphFixtures.project(named: "midi_tempo")))
    }

    // MARK: MODEL-043 (seam)

    /// A project with an AU insert and a VST3 instrument, both holding state.
    private func pluginProject() throws -> (Project, au: NodeIDValue, vst: NodeIDValue) {
        var project = Project(name: "plugins")
        let track = project.ids.allocate()
        let au = project.ids.allocate()
        let vst = project.ids.allocate()
        project.tracks = [Track(
            id: track, name: "Synth", kind: .midi,
            instrument: DeviceSlot(id: vst, kind: .vst3(VST3Descriptor(identifier: "/x.vst3#1", name: "V"))),
            inserts: [DeviceSlot(id: au, kind: .au(AUDescriptor(identifier: "aufx:dely:appl", name: "Delay")),
                                 pluginState: Data([1, 2, 3]))])]
        try project.validate()
        return (project, au, vst)
    }

    @Test("MODEL-043 (seam): plugin state goes to Plugins/<slotID>.state, not into project.json, and comes back into the slots and through the provider")
    func pluginStateFiles() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        let folder = temp.url.appending(path: "P.dawproject")
        let (project, au, vst) = try pluginProject()

        // The "fake plugin": FakeEngine holds the VST3's state as a hosted plugin would.
        let engine = FakeEngine()
        engine.setPluginState(slot: vst, Data("vst state".utf8))
        let store = ProjectStore(project: project)
        store.autosavePolicy = nil
        store.pluginStateProvider = EnginePluginStates(engine: engine)
        try await store.save(to: folder)

        let plugins = folder.appending(path: "Plugins")
        #expect(try Data(contentsOf: plugins.appending(path: "\(au).state")) == Data([1, 2, 3]), "stored state")
        #expect(try Data(contentsOf: plugins.appending(path: "\(vst).state")) == Data("vst state".utf8), "captured from the engine")
        let json = try String(contentsOf: folder.appending(path: "project.json"), encoding: .utf8)
        #expect(!json.contains("pluginState"))

        let reopened = try await open(folder)
        #expect(reopened.project.pluginStates == [au: Data([1, 2, 3]), vst: Data("vst state".utf8)])
        let next = FakeEngine()
        reopened.pluginStateProvider = EnginePluginStates(engine: next)
        reopened.restorePluginStates()
        #expect(next.pluginState(slot: vst) == Data("vst state".utf8) && next.pluginState(slot: au) == Data([1, 2, 3]))

        // A slot that is gone loses its file at the next save.
        var smaller = reopened.project
        smaller.tracks[0].inserts = []
        let third = ProjectStore(project: smaller)
        third.autosavePolicy = nil
        try await third.save(to: folder)
        #expect(!exists(plugins.appending(path: "\(au).state")) && exists(plugins.appending(path: "\(vst).state")))
    }

    // MARK: MODEL-044

    @Test("MODEL-044: an edit is autosaved after the debounce into autosave/; project.json is never touched")
    func debouncedAutosave() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        let folder = temp.url.appending(path: "A.dawproject")
        let (project, _, vst) = try pluginProject()
        let store = ProjectStore(project: project)
        store.autosavePolicy = AutosavePolicy(interval: .seconds(3600), debounce: .milliseconds(30))
        let engine = FakeEngine()
        engine.setPluginState(slot: vst, Data([9]))
        store.pluginStateProvider = EnginePluginStates(engine: engine)
        try await store.save(to: folder)
        let main = try Data(contentsOf: folder.appending(path: "project.json"))
        let autosave = folder.appending(path: "autosave/project.json")

        try store.perform(AddTrack(name: "Unsaved", kind: .audio))
        #expect(await eventually { exists(autosave) })
        #expect(try Data(contentsOf: folder.appending(path: "project.json")) == main, "never overwrites the main file")
        let saved = try ProjectFile.decode(Data(contentsOf: autosave)).project
        #expect(saved.tracks.map(\.name) == ["Synth", "Unsaved"])
        #expect(try Data(contentsOf: folder.appending(path: "autosave/Plugins/\(vst).state")) == Data([9]), "plus plugin states")
        #expect(store.isDirty, "autosave doesn't clear the dirty flag")

        // Back at the saved state, the autosave this store wrote goes away.
        store.undo()
        #expect(await eventually { !exists(autosave) })

        // A save removes it too.
        try store.perform(AddTrack(name: "Again", kind: .audio))
        #expect(await eventually { exists(autosave) })
        try await store.save(to: nil)
        #expect(!exists(folder.appending(path: "autosave")))
    }

    @Test("MODEL-044: the periodic autosave writes while dirty, and nothing is written for a project without a folder")
    func periodicAutosave() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        let folder = temp.url.appending(path: "A.dawproject")
        let store = ProjectStore(project: Project(name: "p"))
        store.autosavePolicy = AutosavePolicy(interval: .milliseconds(40), debounce: .seconds(3600))
        try store.perform(AddTrack(name: "Before save", kind: .audio))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!exists(temp.url.appending(path: "autosave")), "no folder, nowhere to autosave")

        try await store.save(to: folder)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!exists(folder.appending(path: "autosave")), "clean: nothing to autosave")

        try store.perform(AddTrack(name: "After save", kind: .audio))
        #expect(await eventually { exists(folder.appending(path: "autosave/project.json")) })

        // Turning autosave off stops it.
        try await store.autosave()
        store.autosavePolicy = nil
        try FileManager.default.removeItem(at: folder.appending(path: "autosave"))
        try store.perform(AddTrack(name: "Off", kind: .audio))
        try await Task.sleep(for: .milliseconds(150))
        #expect(!exists(folder.appending(path: "autosave")))
    }

    // MARK: MODEL-045

    @Test("MODEL-045: a newer autosave is reported on open, opened with recover (dirty), and gone after a save or a clean close")
    func recovery() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        let folder = temp.url.appending(path: "R.dawproject")
        let store = ProjectStore(project: Project(name: "r"))
        store.autosavePolicy = nil
        try await store.save(to: folder)
        try store.perform(AddTrack(name: "Unsaved", kind: .audio))
        try await store.autosave()
        // The store is dropped without close(): a crash.

        let plain = try await open(folder)
        #expect(plain.project.tracks.isEmpty && !plain.isDirty)
        #expect(plain.loadReport.recoveryAvailable && !plain.loadReport.recovered)

        let recovered = try await open(folder, recover: true)
        #expect(recovered.project.tracks.map(\.name) == ["Unsaved"])
        #expect(recovered.loadReport.recovered && !recovered.loadReport.recoveryAvailable)
        #expect(recovered.isDirty, "the recovered state isn't in project.json yet")
        #expect(recovered.folderURL == folder)

        try await recovered.save(to: nil)
        #expect(!recovered.isDirty && !exists(folder.appending(path: "autosave")))
        let after = try await open(folder)
        #expect(after.project.tracks.map(\.name) == ["Unsaved"] && !after.loadReport.recoveryAvailable)

        // recover with no autosave just opens the file.
        #expect(try await open(folder, recover: true).loadReport.recovered == false)

        // A clean quit deletes the autosave.
        try after.perform(AddTrack(name: "Quit", kind: .audio))
        try await after.autosave()
        #expect(exists(folder.appending(path: "autosave/project.json")))
        await after.close()
        #expect(!exists(folder.appending(path: "autosave")))
        #expect(try await open(folder).loadReport.recoveryAvailable == false)
    }

    @Test("MODEL-045: an autosave older than project.json is not offered; only an autosave and no project.json needs recover")
    func staleAutosave() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        let folder = temp.url.appending(path: "R.dawproject")
        let store = ProjectStore(project: Project(name: "r"))
        store.autosavePolicy = nil
        try await store.save(to: folder)
        try store.perform(AddTrack(name: "A", kind: .audio))
        try await store.autosave()
        let autosave = folder.appending(path: "autosave/project.json")
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: autosave.path)
        #expect(try await open(folder).loadReport.recoveryAvailable == false)
        #expect(try await open(folder, recover: true).project.tracks.isEmpty)

        try FileManager.default.removeItem(at: folder.appending(path: "project.json"))
        await #expect(throws: DAWError.self) { _ = try await ProjectStore.open(folder, recover: false) }
        #expect(try await open(folder, recover: true).project.tracks.map(\.name) == ["A"])
    }

    // MARK: MODEL-046, DW-097

    @Test("MODEL-046: a missing audio file leaves its asset offline in the load report; clips are kept and the file is not loaded")
    func offlineAsset() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        let folder = try folder(with: "audio_tracks", in: temp)  // references Audio/loop.wav, which isn't there
        let store = try await open(folder)
        let fixture = try GraphFixtures.project(named: "audio_tracks")
        #expect(store.loadReport.offlineAssets == [2])
        #expect(store.project == fixture, "clips and the asset are kept")

        let engine = FakeEngine()
        try store.attachEngine(engine, debounce: .zero)
        #expect(await store.loadAssets().offlineAssets == [2])
        #expect(!engine.calls.contains { if case .loadAsset = $0 { true } else { false } })

        // The file comes back: the next load finds it, by its path inside the folder.
        try FileManager.default.createDirectory(at: folder.appending(path: "Audio"), withIntermediateDirectories: true)
        try writeSineWAV(folder.appending(path: "Audio/loop.wav"), frames: 4800)
        #expect(await store.loadAssets().offlineAssets == [])
        #expect(engine.calls.contains(.loadAsset(2, path: folder.appending(path: "Audio/loop.wav").path)))

        // A file the engine can't decode is offline too.
        let broken = folder.appending(path: "Audio/loop.wav").path
        engine.failLoads(of: broken)
        #expect(await store.loadAssets().offlineAssets == [2])
    }

    @Test("MODEL-046, DW-097, DW-124, DW-123: against the real engine, a saved project's copied audio plays after open; a missing file renders silence; the loop reaches the transport")
    func realEngineRoundTrip() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        let wav = temp.url.appending(path: "outside.wav")
        try writeSineWAV(wav, frames: 48_000)
        let folder = temp.url.appending(path: "Real.dawproject")

        // Built the way asset.import does it, with the file outside any project folder.
        let store = ProjectStore(project: Project(name: "real"))
        store.autosavePolicy = nil
        try store.perform(AddTrack(name: "Src", kind: .audio))
        let id = store.project.ids.next
        try store.perform(ImportAsset(asset: AssetRef(id: id, path: wav.path, channels: 1, originalSampleRate: 48_000, frames: 48_000)))
        try store.perform(AddClip(trackID: store.project.tracks[0].id, start: 0, assetID: id))
        try store.perform(SetLoop(loop: LoopRange(start: 0, end: 1920)))
        try await store.save(to: folder)
        #expect(store.project.assets[0].path == "Audio/outside.wav", "DW-124: copied in, path made relative")
        #expect(FileManager.default.contentsEqual(atPath: wav.path, andPath: folder.appending(path: "Audio/outside.wav").path))
        try FileManager.default.removeItem(at: wav)  // the project no longer needs the original

        func renderPeak(_ store: ProjectStore) async throws -> (peak: Float, engine: EngineClient) {
            let engine = try EngineClient(.offline(sampleRate: 48_000))
            let sync = try store.attachEngine(engine)
            _ = await store.loadAssets()
            _ = sync.pollEvents()
            await sync.settle()
            #expect(await engine.graphApplied(engine.graphStatus().submittedVersion).lastError == nil)
            let path = temp.url.appending(path: "render-\(UUID().uuidString).wav").path
            let result = try #require(await engine.waitForJob(engine.renderOffline(
                from: 0, to: 1920, spec: ExportSpec(path: path, blockSize: 256, tailEnabled: false))).render)
            #expect(result.rtViolations == 0)
            return (engine.meter(store.project.tracks[0].id)?.peak ?? 0, engine)
        }

        let opened = try await open(folder)
        #expect(opened.loadReport.offlineAssets.isEmpty)
        let (peak, engine) = try await renderPeak(opened)
        #expect(peak > 0.3, "the clip plays from Audio/")
        let transport = engine.transport()
        #expect(transport.loopEnabled && transport.loopStart == 0 && transport.loopEnd == 1920, "DW-123: the project's loop")
        #expect(engine.telemetry().rtViolations == 0)

        try FileManager.default.removeItem(at: folder.appending(path: "Audio/outside.wav"))
        let missing = try await open(folder)
        #expect(missing.loadReport.offlineAssets == [id])
        #expect(missing.project.tracks[0].clips.count == 1)
        let (silent, other) = try await renderPeak(missing)
        #expect(silent == 0, "an offline asset renders silence")
        #expect(await missing.loadAssets().offlineAssets == [id])
        #expect(other.telemetry().rtViolations == 0)
    }

    // MARK: DW-124

    @Test("DW-124: save copies outside audio into Audio/ once, renames on a clash, keeps missing files absolute, and Save As copies the project's own audio")
    func assetCopies() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }
        let elsewhere = temp.url.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere.appending(path: "b"), withIntermediateDirectories: true)
        try writeSineWAV(elsewhere.appending(path: "kick.wav"), frames: 100)
        try writeSineWAV(elsewhere.appending(path: "b/kick.wav"), frames: 200)  // same name, other contents

        var project = Project(name: "copies")
        func asset(_ path: String) -> AssetRef {
            AssetRef(id: project.ids.allocate(), path: path, channels: 1, originalSampleRate: 48_000, frames: 100)
        }
        project.assets = [asset(elsewhere.appending(path: "kick.wav").path),
                          asset(elsewhere.appending(path: "b/kick.wav").path),
                          asset(elsewhere.appending(path: "gone.wav").path)]
        let store = ProjectStore(project: project)
        store.autosavePolicy = nil
        let folder = temp.url.appending(path: "C.dawproject")
        try await store.save(to: folder)
        #expect(store.project.assets.map(\.path) == ["Audio/kick.wav", "Audio/kick-2.wav", elsewhere.appending(path: "gone.wav").path])
        #expect(try await open(folder).loadReport.offlineAssets == [store.project.assets[2].id])

        // Undoing to an asset with its old absolute path (as redo of an import does) and saving
        // again reuses the copy instead of making a third.
        var again = store.project
        again.assets[0].path = elsewhere.appending(path: "kick.wav").path
        let second = ProjectStore(project: again)
        second.autosavePolicy = nil
        try await second.save(to: folder)
        #expect(second.project.assets[0].path == "Audio/kick.wav")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Audio").path).sorted() == ["kick-2.wav", "kick.wav"])

        // Save As: relative paths resolve against the old folder and are copied into the new one.
        let reopened = try await open(folder)
        let copy = temp.url.appending(path: "Copy.dawproject")
        try await reopened.save(to: copy)
        #expect(reopened.folderURL == copy)
        #expect(reopened.project.assets.map(\.path).prefix(2) == ["Audio/kick.wav", "Audio/kick-2.wav"])
        #expect(FileManager.default.contentsEqual(atPath: copy.appending(path: "Audio/kick-2.wav").path,
                                                  andPath: elsewhere.appending(path: "b/kick.wav").path))
        #expect(try await open(copy).loadReport.offlineAssets == [store.project.assets[2].id])
    }

    // MARK: DW-111

    @Test("DW-111: open checks the project; unsorted clips and notes are repaired and reported, other broken invariants are errors")
    func validateOnOpen() async throws {
        let temp = try TempFolder("persist")
        defer { temp.remove() }

        // Clips of the first audio track reversed, notes of the MIDI clip reversed.
        var json = try JSON(parsing: fixture("midi_tempo"))
        var tracks = try #require(json["tracks"]?.arrayValue)
        var reversedSomething = false
        for t in tracks.indices {
            guard var clips = tracks[t]["clips"]?.arrayValue else { continue }
            for c in clips.indices {
                guard let notes = clips[c]["notes"]?.arrayValue, notes.count > 1 else { continue }
                clips[c]["notes"] = .array(notes.reversed())
                reversedSomething = true
            }
            if clips.count > 1 { clips.reverse(); reversedSomething = true }
            tracks[t]["clips"] = .array(clips)
        }
        #expect(reversedSomething, "the fixture has something to reorder")
        json["tracks"] = .array(tracks)
        let folder = temp.url.appending(path: "V.dawproject")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json.encoded().write(to: folder.appending(path: "project.json"))
        let store = try await open(folder)
        #expect(!store.loadReport.repairs.isEmpty)
        #expect(store.project == (try GraphFixtures.project(named: "midi_tempo")), "the repair restores the canonical order")

        // An output to a bus that doesn't exist can't be repaired safely.
        var dangling = try JSON(parsing: fixture("audio_tracks"))
        var danglingTracks = try #require(dangling["tracks"]?.arrayValue)
        danglingTracks[0]["output"] = .object(["kind": .string("bus"), "id": .int(6)])
        dangling["tracks"] = .array(danglingTracks)
        try dangling.encoded().write(to: folder.appending(path: "project.json"))
        do {
            _ = try await ProjectStore.open(folder, recover: false)
            Issue.record("expected invalidProject")
        } catch {
            guard case .invalidProject(let detail) = error else { Issue.record("got \(error)"); return }
            #expect(detail.contains("invariant"))
        }

        try Data("{".utf8).write(to: folder.appending(path: "project.json"))
        await #expect(throws: DAWError.self) { _ = try await ProjectStore.open(folder, recover: false) }
    }

    // MARK: DW-123

    @Test("DW-123: engine sync gives the transport the project's loop on attach, after SetLoop and after undo; an unchanged loop isn't pushed")
    func loopFollowsProject() throws {
        var project = Project(name: "loop")
        project.loop = LoopRange(start: 960, end: 3840)
        let store = ProjectStore(project: project)
        let engine = FakeEngine()
        try store.attachEngine(engine, debounce: .zero)
        #expect(engine.calls.contains(.setLoop(enabled: true, start: 960, end: 3840)))

        engine.clearCalls()
        try store.perform(AddTrack(name: "T", kind: .audio))
        #expect(!engine.calls.contains { if case .setLoop = $0 { true } else { false } })

        try store.perform(SetLoop(loop: LoopRange(start: 0, end: 1920, isEnabled: false)))
        #expect(engine.calls.last { if case .setLoop = $0 { true } else { false } } == .setLoop(enabled: false, start: 0, end: 1920))
        store.undo()
        #expect(engine.transport().loopEnabled && engine.transport().loopStart == 960)
        try store.perform(SetLoop(loop: nil))
        #expect(!engine.transport().loopEnabled)
    }
}
