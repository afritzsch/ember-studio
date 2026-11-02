import CoreGraphics
import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-013: clip gestures on the arrange view model, each one undo entry; UI-012 snapping while
// dragging (⌘ turns it off); UI-011 waveform level choice and mesh; UI-014 playhead source.
//
// Geometry used throughout: 32 px per beat, so 1 px = 30 ticks and a 4/4 bar is 128 px. The ruler
// is 22 px; row 0 spans y 22…86 (clip 23…85), row 1 86…150, row 2 150…214.

/// Two audio tracks (A, B), a MIDI track (M) and a 4-second stereo asset loaded in the FakeEngine.
@MainActor
func makeArrange() throws -> (ProjectWindowModel, FakeEngine, asset: ModelID) {
    let (model, engine) = try makeWindow(tracks: ["A", "B"])
    model.perform(AddTrack(name: "M", kind: .midi))
    let asset = model.project.ids.next
    _ = engine.loadAsset(asset, path: "/tmp/loop.wav")
    try model.store.perform(ImportAsset(asset: AssetRef(id: asset, path: "/tmp/loop.wav", channels: 2, originalSampleRate: 48_000,
                                                        frames: 4 * 48_000)))
    model.engineEventsArrived(engine.pollEvents())
    model.arrange.viewSize = CGSize(width: 1000, height: 22 + 3 * 64)
    model.arrange.snap = .beat
    return (model, engine, asset)
}

@MainActor
extension ProjectWindowModel {
    @discardableResult
    func addAudioClip(track: Int, start: Int64, length: Int64 = 3840, asset: ModelID) throws -> ModelID {
        let id = project.tracks[track].id
        let before = Set(project.tracks[track].clips.map(\.id))
        try store.perform(AddClip(trackID: id, start: Tick(start), length: Tick(length), assetID: asset))
        return try #require(project.tracks[track].clips.first { !before.contains($0.id) }?.id)
    }

    func audio(_ id: ModelID) throws -> AudioClip {
        guard case .audio(let clip) = try #require(project.clip(id)) else { throw DAWError.invalidArgument("not audio") }
        return clip
    }

    func trackOf(_ id: ModelID) -> NodeIDValue? { project.clipLocation(id)?.track }
}

@MainActor
@Suite("Arrange canvas view model (UI-010..014)")
struct ArrangeModelTests {
    @Test("UI-013, UI-012: a body drag moves the clip, snapped to the beat, as one undo entry however many steps")
    func moveSnapped() throws {
        let (model, _, asset) = try makeArrange()
        let clip = try model.addAudioClip(track: 0, start: 0, asset: asset)
        let a = model.arrange
        #expect(a.hitTest(CGPoint(x: 64, y: 62)) == ClipHit(clipID: clip, zone: .body))
        a.mouseDown(at: CGPoint(x: 64, y: 62))
        #expect(a.selection == [clip])
        a.mouseDragged(to: CGPoint(x: 65, y: 62))
        #expect(a.activeGesture == nil, "under the drag threshold")
        a.mouseDragged(to: CGPoint(x: 70, y: 62))
        #expect(a.activeGesture == "Move Clip")
        #expect(try model.audio(clip).start == 0, "180 ticks snaps back to beat 1")
        a.mouseDragged(to: CGPoint(x: 96, y: 62))
        #expect(try model.audio(clip).start == 960)
        a.mouseDragged(to: CGPoint(x: 130, y: 62))
        a.mouseUp(at: CGPoint(x: 130, y: 62))
        #expect(try model.audio(clip).start == 1920, "66 px = 1980 ticks snaps to beat 3")
        #expect(model.store.undoLabel == "Move Clip" && a.activeGesture == nil)
        model.store.undo()
        #expect(try model.audio(clip).start == 0, "one undo undoes the whole drag")
        #expect(model.store.undoLabel == "Add Clip")
    }

    @Test("UI-012: ⌘ during a drag disables snapping; snap off moves by the pixel")
    func commandDisablesSnap() throws {
        let (model, _, asset) = try makeArrange()
        let clip = try model.addAudioClip(track: 0, start: 0, asset: asset)
        let a = model.arrange
        a.mouseDown(at: CGPoint(x: 64, y: 62))
        a.mouseDragged(to: CGPoint(x: 134, y: 62), modifiers: .command)
        #expect(try model.audio(clip).start == 2100)
        a.mouseDragged(to: CGPoint(x: 134, y: 62))
        #expect(try model.audio(clip).start == 1920, "releasing ⌘ mid-drag snaps again")
        a.mouseUp(at: CGPoint(x: 134, y: 62))

        a.snap = .off
        a.mouseDown(at: CGPoint(x: 64 + 64, y: 62))
        a.mouseDragged(to: CGPoint(x: 64 + 64 + 10, y: 62))
        a.mouseUp(at: .zero)
        #expect(try model.audio(clip).start == 2220)
    }

    @Test("UI-013: a move crosses tracks of the same kind, never onto a MIDI track, and stops at 0")
    func moveCrossTrack() throws {
        let (model, _, asset) = try makeArrange()
        let clip = try model.addAudioClip(track: 0, start: 1920, asset: asset)
        let (trackA, trackB) = (model.project.tracks[0].id, model.project.tracks[1].id)
        let a = model.arrange
        a.mouseDown(at: CGPoint(x: 100, y: 62))
        a.mouseDragged(to: CGPoint(x: 100, y: 62 + 64))
        #expect(model.trackOf(clip) == trackB)
        a.mouseDragged(to: CGPoint(x: 100, y: 62 + 128))
        #expect(model.trackOf(clip) == trackA, "row 2 is MIDI: the clip stays on its own track")
        a.mouseDragged(to: CGPoint(x: -400, y: 62 + 64))
        a.mouseUp(at: .zero)
        #expect(try model.trackOf(clip) == trackB && model.audio(clip).start == 0, "clamped at the timeline start")
        #expect(model.store.undoLabel == "Move Clip")
        model.store.undo()
        #expect(try model.trackOf(clip) == trackA && model.audio(clip).start == 1920)
    }

    @Test("UI-013: dragging one of several selected clips moves them all, as one undo entry")
    func moveSelection() throws {
        let (model, _, asset) = try makeArrange()
        let c1 = try model.addAudioClip(track: 0, start: 0, asset: asset)
        let c2 = try model.addAudioClip(track: 1, start: 3840, length: 1920, asset: asset)
        let a = model.arrange
        a.mouseDown(at: CGPoint(x: 64, y: 62))
        a.mouseDown(at: CGPoint(x: 150, y: 120), modifiers: .shift)
        #expect(a.selection == [c1, c2])
        a.mouseDragged(to: CGPoint(x: 150 + 32, y: 120))
        a.mouseUp(at: .zero)
        #expect(try model.audio(c1).start == 960 && model.audio(c2).start == 4800)
        #expect(model.store.undoLabel == "Move Clips")
        model.store.undo()
        #expect(try model.audio(c1).start == 0 && model.audio(c2).start == 3840)

        // A click without a drag on one clip of the selection selects just it; shift-click toggles.
        a.mouseDown(at: CGPoint(x: 64, y: 62))
        a.mouseUp(at: CGPoint(x: 64, y: 62))
        #expect(a.selection == [c1])
        a.mouseDown(at: CGPoint(x: 64, y: 62), modifiers: .shift)
        a.mouseUp(at: CGPoint(x: 64, y: 62), modifiers: .shift)
        #expect(a.selection.isEmpty)
    }

    @Test("UI-013: trim start shifts the source offset and stops at the file's start; trim end stops at the file's end")
    func trims() throws {
        let (model, _, asset) = try makeArrange()
        let clip = try model.addAudioClip(track: 0, start: 0, asset: asset)
        let a = model.arrange
        #expect(a.hitTest(CGPoint(x: 1, y: 62))?.zone == .trimStart)
        a.mouseDown(at: CGPoint(x: 1, y: 62))
        a.mouseDragged(to: CGPoint(x: 33, y: 62))
        var c = try model.audio(clip)
        #expect(c.start == 960 && c.length == 2880 && c.sourceOffsetSamples == 24_000, "half a second at 120 bpm, 48 kHz")
        a.mouseDragged(to: CGPoint(x: -40, y: 62))
        a.mouseUp(at: .zero)
        c = try model.audio(clip)
        #expect(c.start == 0 && c.length == 3840 && c.sourceOffsetSamples == 0, "can't start before the audio")
        #expect(model.store.undoLabel == "Trim Clip Start")

        #expect(a.hitTest(CGPoint(x: 127, y: 62))?.zone == .trimEnd)
        a.mouseDown(at: CGPoint(x: 127, y: 62))
        a.mouseDragged(to: CGPoint(x: 127 + 300, y: 62))
        a.mouseUp(at: .zero)
        #expect(try model.audio(clip).length == 7680, "4 s of audio = 8 beats")
        a.mouseDown(at: CGPoint(x: 255, y: 62))
        a.mouseDragged(to: CGPoint(x: 0, y: 62))
        a.mouseUp(at: .zero)
        #expect(try model.audio(clip).length == 1, "at least one tick long")
        #expect(model.store.undoLabel == "Trim Clip End")
    }

    @Test("UI-013: fade handles set fade-in/out and the gain handle sets clip gain in dB, one undo entry each")
    func fadesAndGain() throws {
        let (model, _, asset) = try makeArrange()
        let clip = try model.addAudioClip(track: 0, start: 0, asset: asset)
        let a = model.arrange
        #expect(a.hitTest(CGPoint(x: 0, y: 26))?.zone == .fadeIn)
        #expect(a.hitTest(CGPoint(x: 127.5, y: 26))?.zone == .fadeOut)
        #expect(a.hitTest(CGPoint(x: 64, y: 26))?.zone == .gain)

        a.mouseDown(at: CGPoint(x: 0, y: 26))
        a.mouseDragged(to: CGPoint(x: 20, y: 26))
        a.mouseDragged(to: CGPoint(x: 32, y: 26))
        a.mouseUp(at: .zero)
        #expect(try model.audio(clip).fadeIn == 960)
        #expect(model.store.undoLabel == "Fade In")
        #expect(a.hitTest(CGPoint(x: 32, y: 26))?.zone == .fadeIn, "the handle sits at the fade's end")

        a.mouseDown(at: CGPoint(x: 127.5, y: 26))
        a.mouseDragged(to: CGPoint(x: 96, y: 26))
        a.mouseUp(at: .zero)
        #expect(try model.audio(clip).fadeOut == 960 && model.audio(clip).fadeIn == 960)
        #expect(model.store.undoLabel == "Fade Out")

        a.mouseDown(at: CGPoint(x: 64, y: 26))
        a.mouseDragged(to: CGPoint(x: 64, y: 16))
        a.mouseDragged(to: CGPoint(x: 64, y: -4))
        a.mouseUp(at: .zero)
        #expect(abs(try model.audio(clip).gain - 1.9953) < 1e-3, "30 pt up = +6 dB")
        #expect(model.store.undoLabel == "Clip Gain")
        a.mouseDown(at: CGPoint(x: 64, y: 26))
        a.mouseDragged(to: CGPoint(x: 64, y: 2000))
        a.mouseUp(at: .zero)
        #expect(try model.audio(clip).gain == 0, "the bottom of the range is silence")
        model.store.undo()
        model.store.undo()
        #expect(try model.audio(clip).gain == 1)
        #expect(ArrangeModel.gain(fromDB: 100) == AudioClip.maxGain)
    }

    @Test("UI-013: a marquee selects the clips it touches; shift adds to the selection")
    func marquee() throws {
        let (model, _, asset) = try makeArrange()
        let c1 = try model.addAudioClip(track: 0, start: 0, asset: asset)
        let c2 = try model.addAudioClip(track: 1, start: 3840, length: 1920, asset: asset)
        let c3 = try model.addAudioClip(track: 1, start: 30_000, asset: asset)
        let a = model.arrange
        a.mouseDown(at: CGPoint(x: 300, y: 30))
        #expect(a.selection.isEmpty)
        a.mouseDragged(to: CGPoint(x: 100, y: 120))
        #expect(a.marquee == CGRect(x: 100, y: 30, width: 200, height: 90) && a.selection == [c1, c2])
        a.mouseDragged(to: CGPoint(x: 140, y: 40))
        #expect(a.selection.isEmpty, "the marquee shrank off both clips")
        a.mouseUp(at: .zero)
        #expect(a.marquee == nil)

        a.selection = [c3]
        a.mouseDown(at: CGPoint(x: 300, y: 30), modifiers: .shift)
        a.mouseDragged(to: CGPoint(x: 100, y: 60), modifiers: .shift)
        a.mouseUp(at: .zero)
        #expect(a.selection == [c1, c3])
        #expect(!model.store.canRedo && model.store.undoLabel == "Add Clip", "selecting is not an edit")
    }

    @Test("UI-013: ⌘D duplicates the selection right after itself (MIDI notes too), one undo entry; copies become the selection")
    func duplicate() throws {
        let (model, _, asset) = try makeArrange()
        let c1 = try model.addAudioClip(track: 0, start: 0, asset: asset)
        try model.store.perform(SetClipFades(clipID: c1, fadeIn: 100, fadeOut: 200))
        let c2 = try model.addAudioClip(track: 1, start: 3840, length: 1920, asset: asset)
        let m = model.project.tracks[2].id
        try model.store.perform(AddClip(trackID: m, start: 960, length: 1920))
        let midi = try #require(model.project.tracks[2].clips.first?.id)
        try model.store.perform(AddNotes(clipID: midi, notes: [.init(start: 0, length: 240, pitch: 60), .init(start: 480, length: 240, pitch: 64)]))
        let a = model.arrange
        a.selection = [c1, c2, midi]
        try model.control("edit.duplicate").action()
        #expect(model.store.undoLabel == "Duplicate")
        let tracks = model.project.tracks
        #expect(tracks[0].clips.map(\.start.raw) == [0, 5760] && tracks[1].clips.map(\.start.raw) == [3840, 9600])
        #expect(tracks[2].clips.map(\.start.raw) == [960, 6720])
        guard case .audio(let copy) = tracks[0].clips[1], case .midi(let midiCopy) = tracks[2].clips[1] else {
            Issue.record("copies of the wrong kind")
            return
        }
        #expect(copy.assetID == asset && copy.fadeIn == 100 && copy.fadeOut == 200 && copy.length == 3840)
        #expect(midiCopy.notes.map(\.pitch) == [60, 64] && midiCopy.notes.map(\.start.raw) == [0, 480])
        #expect(a.selection == [copy.id, tracks[1].clips[1].id, midiCopy.id])
        model.store.undo()
        #expect(model.project.tracks.map(\.clips.count) == [1, 1, 1])
    }

    @Test("UI-013: split at a tick (the selection, or a clicked clip) and delete, one undo entry each")
    func splitAndDelete() throws {
        let (model, engine, asset) = try makeArrange()
        let c1 = try model.addAudioClip(track: 0, start: 0, asset: asset)
        let c2 = try model.addAudioClip(track: 1, start: 0, asset: asset)
        let a = model.arrange
        a.selection = [c1, c2]
        engine.locate(1920)
        #expect(a.playheadTick() == 1920, "UI-014: the playhead comes from the engine's transport")
        try model.control("edit.split").action()
        #expect(model.project.tracks[0].clips.map(\.length.raw) == [1920, 1920])
        #expect(model.project.tracks[1].clips.count == 2 && a.selection.count == 4)
        #expect(try model.audio(model.project.tracks[0].clips[1].id).sourceOffsetSamples == 48_000)
        #expect(model.store.undoLabel == "Split")
        model.store.undo()
        #expect(model.project.tracks.map(\.clips.count) == [1, 1, 0])

        a.selection = []
        a.split(c2, at: 960)
        #expect(model.project.tracks.map(\.clips.count) == [1, 2, 0], "a clicked clip outside the selection splits alone")
        a.selection = [c1]
        try model.control("edit.delete").action()
        #expect(model.project.tracks[0].clips.isEmpty && a.selection.isEmpty)
        #expect(model.store.undoLabel == "Delete Clip")
        #expect(try !model.control("edit.delete").isEnabled)
        model.store.undo()
        #expect(model.project.tracks[0].clips.count == 1)
    }

    @Test("UI-013, UI-052: snap, nudge, select-all and per-clip select controls (what ui.perform runs)")
    func controls() throws {
        let (model, _, asset) = try makeArrange()
        let clip = try model.addAudioClip(track: 0, start: 0, asset: asset)
        let far = try model.addAudioClip(track: 0, start: 400_000, asset: asset)
        try model.control("snap.bar").action()
        #expect(try model.arrange.snap == .bar && model.control("snap.bar").isOn == true && model.control("snap.beat").isOn == false)
        try model.control("clip.\(clip).select").action()
        #expect(model.selectedClips == [clip])
        #expect(!model.controls.contains { $0.id == "clip.\(far).select" }, "only visible clips get a select control")
        try model.control("clip.nudge.right").action()
        #expect(try model.audio(clip).start == 3840 && model.store.undoLabel == "Move Clip")
        try model.control("clip.nudge.down").action()
        #expect(model.trackOf(clip) == model.project.tracks[1].id)
        try model.control("clip.nudge.down").action()
        #expect(model.trackOf(clip) == model.project.tracks[1].id, "not onto the MIDI track")
        try model.control("clip.nudge.left").action()
        try model.control("clip.nudge.left").action()
        #expect(try model.audio(clip).start == 0)
        try model.control("edit.selectAll").action()
        #expect(model.selectedClips == [clip, far])
        try model.control("edit.deselectAll").action()
        #expect(model.selectedClips.isEmpty)
    }

    @Test("UI-010: zoom keeps the time under the pointer in place; scrolling is clamped to the content")
    func zoomAndScroll() throws {
        let (model, _, _) = try makeArrange()
        let a = model.arrange
        a.viewSize = CGSize(width: 1000, height: 22 + 100)
        #expect(a.geometry.tick(atX: 320) == 9600)
        a.zoom(by: 2, anchorX: 320)
        #expect(model.pixelsPerBeat == 64 && a.geometry.tick(atX: 320) == 9600 && model.scrollX == 320)
        a.zoom(by: 0.25, anchorX: 0)
        #expect(model.pixelsPerBeat == 16 && model.scrollX == 80)
        a.scroll(dx: -500, dy: 1000)
        #expect(model.scrollX == 0 && model.scrollY == 3 * 64 - 100)
        #expect(model.visibleTracks == model.project.tracks.suffix(2).map(\.id))
    }

    @Test("UI-011: waveforms come from the engine's peaks, at the level the zoom calls for, inside the clip")
    func waveforms() throws {
        #expect(WaveformMesh.level(samplesPerPixel: 10) == 0)
        #expect(WaveformMesh.level(samplesPerPixel: 1023) == 0)
        #expect(WaveformMesh.level(samplesPerPixel: 1024) == 1)
        #expect(WaveformMesh.level(samplesPerPixel: 5000) == 2)
        #expect(WaveformMesh.level(samplesPerPixel: 1e7) == 3)

        let (model, engine, asset) = try makeArrange()
        let clip = try model.addAudioClip(track: 0, start: 0, asset: asset)
        let a = model.arrange
        // 32 px/beat at 120 bpm, 48 kHz: 750 samples per pixel.
        #expect(abs(WaveformMesh.samplesPerPixel(at: 0, geometry: a.geometry, tempoMap: model.project.tempoMap) - 750) < 1)
        #expect(a.waveformLevel(try model.audio(clip)) == 0)
        let bars = a.waveformBars()
        #expect(bars.count == 64 * 2, "one bar per pixel column and channel")
        let xs = bars.flatMap { [$0.x0, $0.x1] }, ys = bars.flatMap { [$0.top, $0.bottom] }
        // FakeEngine's peaks are 1 s long: 2 beats = 64 px of the 128 px clip.
        #expect(xs.min()! >= 0 && xs.max()! <= 64)
        #expect(ys.min()! >= 23 + Float(WaveformMesh.headerHeight) && ys.max()! <= 85)
        model.zoom(by: 1.0 / 8)
        #expect(a.waveformLevel(try model.audio(clip)) == 2, "6000 samples per pixel")

        // An asset that loads later: missing (cached as a miss) until its assetLoaded event.
        let late = model.project.ids.next
        try model.store.perform(ImportAsset(asset: AssetRef(id: late, path: "/tmp/late.wav", channels: 1, originalSampleRate: 48_000,
                                                            frames: 48_000)))
        let lateClip = try model.addAudioClip(track: 1, start: 0, asset: late)
        #expect(a.waveformLevel(try model.audio(lateClip)) == nil)
        _ = engine.loadAsset(late, path: "/tmp/late.wav")
        #expect(a.waveformLevel(try model.audio(lateClip)) == nil, "the miss is cached")
        let version = a.peaksVersion
        model.engineEventsArrived(engine.pollEvents())
        #expect(try a.peaksVersion == version + 1 && a.waveformLevel(model.audio(lateClip)) == 2)
    }
}

@MainActor
@Suite("Arrange canvas performance smoke (UI-010)", .serialized)
struct ArrangePerfTests {
    /// UI-010's acceptance (1,000 clips at 60 fps on an M1) needs Instruments on the running app. This
    /// is the part a unit test can measure: the per-frame model work of a scroll/zoom (interval
    /// query, waveform mesh, per-clip controls) over 1,000 clips stays well under a 16.7 ms frame.
    @Test("UI-010: 1,000 clips: index build and per-frame visible-clip query + waveform mesh stay far under a frame")
    func thousandClips() throws {
        let (model, _, asset) = try makeArrange()
        var project = model.project
        for _ in 0..<17 { project.tracks.append(project.tracks[0]) }
        var nextID: ModelID = 1_000_000
        for t in project.tracks.indices {
            project.tracks[t].id = NodeIDValue(500_000 + t)
            project.tracks[t].kind = .audio
            project.tracks[t].clips = (0..<50).map { i in
                nextID += 1
                return .audio(AudioClip(id: nextID, assetID: asset, start: Tick(Int64(i) * 4800), length: 3840))
            }
        }
        #expect(project.tracks.flatMap(\.clips).count == 1_000)
        let engine = FakeEngine()
        _ = engine.loadAsset(asset, path: "/tmp/loop.wav")
        let store = ProjectStore(project: project)
        store.autosavePolicy = nil
        try store.attachEngine(engine, debounce: .zero)
        let window = ProjectWindowModel(id: 1, store: store)
        let a = window.arrange
        a.viewSize = CGSize(width: 1600, height: 900)

        let clock = ContinuousClock()
        let build = clock.measure { _ = a.index }
        var visible = 0, bars = 0
        let frames = 600
        let scroll = clock.measure {
            for frame in 0..<frames {
                // Scroll right and down, and zoom in and out, every frame.
                window.scrollX = Double(frame) * 7
                window.scrollY = Double(frame % 120)
                window.pixelsPerBeat = 16 + Double(frame % 60)
                visible += a.visibleClips.count
                bars += a.waveformBars().count
            }
        }
        let perFrame = scroll / frames
        print("UI-010 perf smoke: index build \(build), per frame \(perFrame) (avg \(visible / frames) visible clips, \(bars / frames) waveform bars)")
        #expect(visible / frames > 10, "the viewport shows clips")
        #expect(build < .milliseconds(50))
        #expect(perFrame < .milliseconds(16), "debug build; release is several times faster")
    }
}
