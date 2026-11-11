import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// DW-156 (T-090, docs/autobuild/DECISIONS.md "T-090 one engine"): one live engine per app. Only the
// front (main) window's project holds it; switching windows stops the transport and hands it over;
// the other windows keep offline engines (peaks, export, no device); closing the front window hands
// it to the next. With `--engine offline` nothing changes (`AppModelTests`).

/// An AppModel with a shared live engine (a realtime FakeEngine) and offline FakeEngines, without
/// windows. Records every engine it makes.
@MainActor
final class LiveTestApp {
    let clock = TestClock()
    var live: [FakeEngine] = []
    var offline: [FakeEngine] = []
    var app: AppModel!

    init() {
        app = AppModel(
            engine: .fake,
            makeEngine: { [unowned self] rate throws(DAWError) in
                let engine = FakeEngine(mode: .realtime(DriverConfig(sampleRate: rate, bufferFrames: 256, driver: .fake)))
                live.append(engine)
                return engine
            },
            makeOfflineEngine: { [unowned self] rate throws(DAWError) in
                let engine = FakeEngine(mode: .offline(sampleRate: rate))
                offline.append(engine)
                return engine
            },
            now: { [unowned self] in clock.now })
    }

    /// The windows holding the live engine (exactly one, the main window, while there are windows).
    var liveHolders: [Int] { app.windows.filter { $0.engine === live.first }.map(\.id) }

    func checkOneLiveEngine(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(live.count <= 1, "only one live engine is ever made", sourceLocation: sourceLocation)
        #expect(liveHolders == app.mainWindowID.map { [$0] } ?? [], "the main window, and only it, holds it",
                sourceLocation: sourceLocation)
        for window in app.windows where window.id != app.mainWindowID {
            #expect(window.engine.map { if case .offline = $0.mode { true } else { false } } == true,
                    "window \(window.id) is offline", sourceLocation: sourceLocation)
        }
        #expect(app.dispatcher.engine === app.mainWindow?.engine, "the Dispatcher controls the main window's engine",
                sourceLocation: sourceLocation)
    }
}

/// An asset whose file exists (engine sync loads readable files only).
private func asset(_ id: ModelID, in dir: TempDir) throws -> AssetRef {
    let file = dir.file("t090-\(id).wav")
    try Data([0]).write(to: file)
    return AssetRef(id: id, path: file.path, channels: 2, originalSampleRate: 48_000, frames: 48_000)
}

@MainActor
@Suite("One live engine per app (DW-156)")
struct LiveEngineTests {
    @Test("DW-156: two windows; only the front one ever holds the live engine, the other is offline")
    func onlyFrontWindowIsLive() async throws {
        let t = LiveTestApp()
        #expect(t.app.sharesLiveEngine)
        let a = t.app.newProject()
        #expect(t.live.count == 1 && a.engine === t.live[0] && a.hasLiveEngine)
        #expect(t.offline.isEmpty, "the first window needs no offline engine")
        t.checkOneLiveEngine()

        let b = t.app.newProject()
        t.checkOneLiveEngine()
        #expect(b.engine === t.live[0] && t.offline.count == 1 && a.engine === t.offline[0])
        #expect(!a.hasLiveEngine && b.hasLiveEngine && t.app.liveWindow?.id == b.id)

        // ui.state says which window plays.
        let state = UIStateDumper.dump(t.app)
        #expect(state["liveWindow"] == .int(Int64(b.id)))
        #expect(state["windows"]?[0]?["engine"] == ["live": false, "mode": "offline"])
        #expect(state["windows"]?[1]?["engine"] == ["live": true, "mode": "realtime"])

        // Focus goes back and forth: the same engines move; nothing new is made.
        for _ in 0..<3 {
            t.app.becameMain(a.id)
            t.checkOneLiveEngine()
            t.app.becameMain(b.id)
            t.checkOneLiveEngine()
        }
        #expect(t.live.count == 1 && t.offline.count == 2, "each project keeps its own offline engine")
        await t.app.quit()
        #expect(t.app.liveEngine == nil && a.engine == nil && b.engine == nil)
    }

    @Test("DW-156: switching windows stops the transport and moves the live engine with the project's graph, params and assets")
    func switchingHandsOver() async throws {
        let t = LiveTestApp()
        let dir = try TempDir()
        let a = t.app.newProject()
        a.addTrack(.audio)
        try a.store.perform(ImportAsset(asset: asset(11, in: dir)))
        _ = await a.store.loadAssets()
        let b = t.app.newProject()
        b.addTrack(.audio)
        b.addTrack(.midi)
        try b.store.perform(ImportAsset(asset: asset(22, in: dir)))
        _ = await b.store.loadAssets()
        let live = t.live[0]
        b.store.engineSync?.flush()  // structural changes are debounced (MODEL-021)
        #expect(live.calls.contains(.loadAsset(11, path: dir.file("t090-11.wav").path)), "A's asset loaded while A was front")
        #expect(live.appliedGraphs.last?.nodes.contains { $0.id == b.project.tracks[1].id } == true)

        live.play()
        b.pollTransport()
        #expect(b.isPlaying)
        live.clearCalls()
        t.app.becameMain(a.id)
        t.checkOneLiveEngine()
        #expect(live.calls.contains(.stop) && !live.transport().playing, "the transport stops")
        #expect(!b.isPlaying && !a.isPlaying)
        // A's graph is on the live engine now; B's (offline) engine has B's graph.
        let graph = try #require(live.appliedGraphs.last)
        #expect(graph.nodes.contains { $0.id == a.project.tracks[0].id })
        #expect(!graph.nodes.contains { $0.id == b.project.tracks[1].id })
        let bOffline = try #require(b.engine as? FakeEngine)
        #expect(bOffline.appliedGraphs.last?.nodes.contains { $0.id == b.project.tracks[1].id } == true)
        // B's assets load into its offline engine (peaks, export); the live engine had A's already.
        #expect(bOffline.calls.contains(.loadAsset(22, path: dir.file("t090-22.wav").path)))
        #expect(!live.calls.contains { if case .loadAsset(11, _) = $0 { true } else { false } }, "A's asset was loaded before")

        // Strip params go to the live engine's slots for A: a mute reaches it at once.
        live.clearCalls()
        a.setStrip(a.project.tracks[0].id, .mute, on: true)
        #expect(live.calls.contains { if case .setParam(_, 1) = $0 { true } else { false } })

        // Back to B: its offline engine is parked again (kept), the live engine loads B's asset only
        // if it hasn't got it.
        live.clearCalls()
        t.app.becameMain(b.id)
        t.checkOneLiveEngine()
        #expect(!live.calls.contains { if case .loadAsset = $0 { true } else { false } }, "B's asset is still in the live engine")
        #expect(a.engine === t.offline[0], "A gets its own offline engine back")
        await t.app.quit()
    }

    @Test("DW-156: closing the front window hands the live engine to the next; closing the last releases it")
    func closingHandsOver() async throws {
        let t = LiveTestApp()
        let a = t.app.newProject()
        let b = t.app.newProject()
        let c = t.app.newProject()
        t.app.becameMain(b.id)
        t.checkOneLiveEngine()

        await t.app.closeWindow(b.id)
        #expect(t.app.mainWindowID == c.id, "the last window opened comes forward")
        t.checkOneLiveEngine()
        #expect(c.engine === t.live[0] && b.store.engineSync == nil)

        // A background window closes: the live engine stays where it is.
        await t.app.closeWindow(a.id)
        t.checkOneLiveEngine()
        #expect(c.engine === t.live[0])

        await t.app.closeWindow(c.id)
        #expect(t.app.windows.isEmpty && t.app.dispatcher.store == nil && c.store.engineSync == nil)
        // A new window takes the same live engine.
        let d = t.app.newProject()
        #expect(d.engine === t.live[0] && t.live.count == 1)
        await t.app.quit()
    }

    @Test("DW-156, REC-004: a take recording in the front window ends at the switch and lands in that project, not the next")
    func recordingEndsInItsProject() async throws {
        let t = LiveTestApp()
        let a = t.app.newProject()
        a.addTrack(.audio)
        let track = a.project.tracks[0].id
        a.perform(ArmTrack(trackID: track, armed: true))
        let b = t.app.newProject()
        t.app.becameMain(a.id)
        let live = t.live[0]
        #expect(live.calls.contains(.armInput(track: track, pair: 0, armed: true)))
        a.toggleRecord()
        live.play()
        #expect(live.transport().recording)

        // The engine finalizes the take when recording stops (the fake posts it by hand).
        live.post(EngineEvent(recording: RecordedTake(track: track, file: "/tmp/t090-take.caf", startSample: 0,
                                                      frames: 48_000, sampleRate: 48_000)))
        live.clearCalls()
        t.app.becameMain(b.id)
        #expect(live.calls.contains(.setRecording(false)) && live.calls.contains(.stop))
        #expect(live.calls.contains(.armInput(track: track, pair: 0, armed: false)), "A's arm leaves the live engine")
        #expect(a.project.assets.count == 1 && a.project.tracks[0].clips.count == 1, "the take is A's")
        #expect(b.project.assets.isEmpty)
        #expect(a.toasts.toasts.contains { $0.kind == .recordingFinalized })
        #expect(a.project.tracks[0].armed, "the arm stays in the document; it reaches the live engine when A is front again")
        t.app.becameMain(a.id)
        #expect(live.calls.last { if case .armInput = $0 { true } else { false } } == .armInput(track: track, pair: 0, armed: true))
        await t.app.quit()
    }

    @Test("DW-156, MODEL-043: hosted plugin state follows the project between the live and its offline engine")
    func pluginStatesCarryOver() async throws {
        let t = LiveTestApp()
        let a = t.app.newProject()
        a.addTrack(.midi)
        a.perform(SetInstrument(trackID: a.project.tracks[0].id, device: .au(AUDescriptor(identifier: "aumu:samp:appl", name: "AUSampler"))))
        let slot = try #require(a.project.tracks[0].instrument?.id)
        let live = t.live[0]
        live.setPluginState(slot: slot, Data("tweaked live".utf8))  // the user turned a knob in the plugin's view

        _ = t.app.newProject()
        let parked = try #require(a.engine as? FakeEngine)
        #expect(parked.pluginState(slot: slot) == Data("tweaked live".utf8), "the offline engine has the live state")
        parked.setPluginState(slot: slot, Data("changed offline".utf8))
        t.app.becameMain(a.id)
        #expect(live.pluginState(slot: slot) == Data("changed offline".utf8))
        // Saves capture it from whichever engine the project has now.
        #expect(a.store.pluginStateProvider.map { ($0 as? EnginePluginStates)?.engine === live } == true)
        await t.app.quit()
    }

    @Test("DW-156: the live engine runs the front project's rate; a rate the device can't run makes the project follow (DW-130)")
    func sampleRates() async throws {
        let t = LiveTestApp()
        let a = t.app.newProject()
        let b = t.app.newProject()
        let live = t.live[0]
        b.perform(SetSessionSampleRate(sampleRate: 44_100))
        #expect(live.telemetry().sampleRate == 44_100)
        t.app.becameMain(a.id)
        #expect(live.telemetry().sampleRate == 48_000 && a.project.sessionSampleRate == 48_000)
        #expect(b.project.sessionSampleRate == 44_100 && b.engine?.telemetry().sampleRate == 44_100,
                "B's offline engine runs B's rate")

        live.refuseSessionRate(44_100)
        t.app.becameMain(b.id)
        t.checkOneLiveEngine()
        #expect(b.project.sessionSampleRate == 48_000 && live.telemetry().sampleRate == 48_000)
        #expect(b.toasts.toasts.last?.title == "Session rate changed")
        await t.app.quit()
    }

    @Test("DW-156: a running export holds the handover until it ends")
    func exportDefersHandover() async throws {
        let t = LiveTestApp()
        let a = t.app.newProject()
        let dir = try TempDir()
        a.exportDialog.unsavedDirectory = dir.url
        let b = t.app.newProject()
        t.app.becameMain(a.id)
        a.exportDialog.isOpen = true
        a.exportDialog.start()
        #expect(a.exportDialog.isRunning)
        t.app.becameMain(b.id)
        #expect(t.app.mainWindowID == b.id && a.engine === t.live[0], "A keeps the engine its export renders on")
        for _ in 0..<1000 where a.exportDialog.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(a.exportDialog.lastResult != nil)
        t.app.pump()
        t.checkOneLiveEngine()
        #expect(b.engine === t.live[0])
        await t.app.quit()
    }

    @Test("DW-156, CTL-002: project.new through the socket replaces the main window's document, which keeps the live engine")
    func dispatcherProjectNew() async throws {
        let t = LiveTestApp()
        let a = t.app.newProject()
        let b = t.app.newProject()
        let old = b.store
        _ = try await t.app.dispatcher.call(.projectNew, ["name": "from agent"])
        #expect(b.project.name == "from agent" && b.store !== old)
        #expect(old.engineSync == nil)
        t.checkOneLiveEngine()
        #expect(b.engine === t.live[0] && a.engine === t.offline[0])
        _ = try await t.app.dispatcher.call(.commandApply, ["command": ["type": "AddTrack", "name": "x", "kind": "audio"]])
        b.store.engineSync?.flush()
        #expect(t.live[0].appliedGraphs.last?.nodes.contains { $0.id == b.project.tracks[0].id } == true)
        await t.app.quit()
    }
}
