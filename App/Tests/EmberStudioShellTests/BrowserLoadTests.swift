import CoreGraphics
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-063 (T-124): loading audio files from the browser (or Finder) into the arrange view. Each
// drop is one undo entry: [AddTrack?] + [ImportAsset (unless a Current Project asset), AddClip]…

@MainActor
@Suite("Browser loading (UI-063)", .serialized)
struct BrowserLoadTests {
    let temp: TempDir
    let files: URL

    init() throws {
        temp = try TempDir()
        files = temp.url.appending(path: "Samples", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for name in ["kick.wav", "snare.aif", "hat.flac", "groove.mid", "notes.txt"] {
            FileManager.default.createFile(atPath: files.appending(path: name).path, contents: Data("x".utf8))
        }
        try FileManager.default.createDirectory(at: files.appending(path: "Folder"), withIntermediateDirectories: true)
    }

    private func file(_ name: String) -> URL { BrowserItem.canonical(files.appending(path: name)) }

    private func browser(tracks: [String] = ["Gtr"]) throws -> (BrowserModel, ProjectWindowModel, FakeEngine) {
        let (window, engine) = try makeWindow(tracks: tracks)
        let browser = BrowserModel(window: window, library: BrowserLibrary(settingsURL: nil, watchesFileSystem: false))
        return (browser, window, engine)
    }

    /// The FakeEngine's files are 1 s at the session rate (48 kHz): 2 beats at 120 BPM.
    private let fileTicks: Int64 = 1920

    @Test("UI-063: an audio file onto an audio track: ImportAsset (reserved ID, engine loads first) + AddClip at the tick, one undo entry")
    func audioOntoAudioTrack() async throws {
        let (browser, window, engine) = try browser()
        let track = window.project.tracks[0].id
        let before = window.project
        let result = try await browser.load([file("kick.wav")], onto: .track(track), at: Tick(3840))
        #expect(result.track == track && !result.newTrack && result.clips.count == 1 && result.imported == result.assets)
        let asset = try #require(window.project.asset(result.assets[0]))
        #expect(asset.path == file("kick.wav").path && asset.channels == 2 && asset.frames == 48000)
        #expect(engine.calls.contains(.loadAsset(asset.id, path: file("kick.wav").path)), "loaded under its ID before the command")
        let clip = try #require(window.project.clip(result.clips[0]))
        #expect(clip.start == Tick(3840) && clip.length == Tick(fileTicks))
        #expect(window.project.tracks[0].clips.map(\.id) == result.clips)
        #expect(window.store.undoLabel == "Load kick.wav")
        #expect(window.selectedClips.isEmpty && window.selectedTracks == [track], "arrows in the browser mustn't nudge the new clip")
        window.store.undo()
        #expect(window.project == before, "one undo entry removes the clip and the asset")
        window.store.redo()
        #expect(window.project.clip(result.clips[0]) != nil && window.project.asset(asset.id) != nil, "redo keeps the IDs")
    }

    @Test("UI-063: several files go one after another on the track, as one undo entry")
    func severalFiles() async throws {
        let (browser, window, _) = try browser()
        let track = window.project.tracks[0].id
        let result = try await browser.load([file("kick.wav"), file("snare.aif"), file("kick.wav")], onto: .track(track), at: Tick(960))
        let clips = try result.clips.map { try #require(window.project.clip($0)) }
        #expect(clips.map(\.start.raw) == [960, 960 + fileTicks, 960 + 2 * fileTicks])
        #expect(result.imported.count == 2 && window.project.assets.count == 2, "the same file is imported once")
        #expect(result.assets[0] == result.assets[2])
        #expect(window.store.undoLabel == "Load 3 Files")
        window.store.undo()
        #expect(window.project.assets.isEmpty && window.project.tracks[0].clips.isEmpty)
    }

    @Test("UI-063: into the empty area: a new audio track named after the file, then the clip; one undo entry")
    func emptyAreaMakesTrack() async throws {
        let (browser, window, _) = try browser()
        let result = try await browser.load([file("hat.flac")], onto: .newTrack, at: Tick(0))
        #expect(result.newTrack)
        let track = try #require(window.project.track(result.track))
        #expect(track.kind == .audio && track.name == "hat" && window.project.tracks.count == 2)
        #expect(track.clips.map(\.id) == result.clips)
        window.store.undo()
        #expect(window.project.tracks.count == 1 && window.project.assets.isEmpty)
    }

    @Test("UI-063: a Current Project asset is reused, not imported (or loaded) again")
    func reusesProjectAsset() async throws {
        let (browser, window, engine) = try browser()
        let first = try await browser.load([file("kick.wav")], onto: .newTrack, at: Tick(0))
        engine.clearCalls()
        // From the Current Project list, and as the same file from a place.
        let item = try #require(browser.currentProjectItems.first)
        #expect(item.url == file("kick.wav"))
        let second = try await browser.load([item.url], onto: .track(window.project.tracks[0].id), at: Tick(960))
        #expect(second.imported.isEmpty && second.assets == first.assets)
        #expect(window.project.assets.count == 1)
        #expect(!engine.calls.contains { if case .loadAsset = $0 { true } else { false } })
        #expect(window.store.undoLabel == "Load kick.wav")
    }

    @Test("UI-063: refusals change nothing and toast: a MIDI file (T-125), audio onto a MIDI track, a folder, another file, a gone track")
    func refusals() async throws {
        let (browser, window, _) = try browser()
        window.perform(AddTrack(name: "Keys", kind: .midi))
        let keys = window.project.tracks[1].id
        let audio = window.project.tracks[0].id
        let before = window.project
        let label = window.store.undoLabel
        let cases: [([URL], BrowserDropTarget, String)] = [
            ([file("groove.mid")], .track(audio), "MIDI files"),
            ([file("kick.wav")], .track(keys), "MIDI track"),
            ([file("Folder")], .newTrack, "folder"),
            ([file("notes.txt")], .newTrack, "isn't an audio or MIDI file"),
            ([file("kick.wav"), file("notes.txt")], .track(audio), "notes.txt"),
            ([file("kick.wav")], .track(9999), "isn't in the project"),
        ]
        for (urls, target, message) in cases {
            let lastToast = window.toasts.toasts.last?.id
            await #expect(throws: BrowserError.self) { try await browser.load(urls, onto: target, at: Tick(0)) }
            #expect(window.toasts.toasts.last?.id != lastToast, "a new toast")
            #expect(window.toasts.toasts.last?.severity == .error)
            #expect(window.toasts.toasts.last?.message.contains(message) == true, "\(window.toasts.toasts.last?.message ?? "")")
        }
        #expect(window.project == before && window.store.undoLabel == label)
    }

    @Test("UI-063: a file the engine can't load leaves the project as it was (its reserved ID is a gap)")
    func failedLoad() async throws {
        let (browser, window, engine) = try browser()
        engine.failLoads(of: file("snare.aif").path)
        let before = window.project
        let next = window.project.ids.next
        await #expect(throws: BrowserError.self) {
            try await browser.load([file("kick.wav"), file("snare.aif")], onto: .newTrack, at: Tick(0))
        }
        #expect(window.project.tracks == before.tracks && window.project.assets.isEmpty)
        #expect(window.toasts.toasts.last?.title == "Couldn't load the files")
        #expect(window.store.reserveID() > next + 1, "the reserved IDs aren't handed out again")
    }

    @Test("UI-063: the drop point: the track under it (lane rows count as their track), the empty area below, nothing over the ruler; snapped unless ⌘")
    func dropTarget() throws {
        let (_, window, _) = try browser(tracks: ["A", "B"])
        let arrange = window.arrange
        arrange.snap = .beat
        let y = { (row: Double) in TimelineGeometry.rulerHeight + row * ProjectWindowModel.trackHeight + 10 }
        let ppt = arrange.geometry.pixelsPerTick
        let x = 1000 * ppt  // tick 1000: snaps to beat 1 (960)
        let ids = window.project.tracks.map(\.id)
        #expect(BrowserModel.dropTarget(at: CGPoint(x: x, y: y(0)), in: arrange, snapping: true)! == (.track(ids[0]), Tick(960)))
        #expect(BrowserModel.dropTarget(at: CGPoint(x: x, y: y(1)), in: arrange, snapping: true)! == (.track(ids[1]), Tick(960)))
        #expect(BrowserModel.dropTarget(at: CGPoint(x: x, y: y(4)), in: arrange, snapping: true)! == (.newTrack, Tick(960)))
        #expect(BrowserModel.dropTarget(at: CGPoint(x: x, y: y(1)), in: arrange, snapping: false)!.tick == Tick(1000), "⌘: not snapped")
        #expect(BrowserModel.dropTarget(at: CGPoint(x: x, y: 5), in: arrange, snapping: true) == nil, "the ruler")
        #expect(BrowserModel.dropTarget(at: CGPoint(x: -50, y: y(0)), in: arrange, snapping: true)!.tick == Tick(0), "never negative")
        arrange.snap = .off
        #expect(BrowserModel.snappedDropTick(Tick(1000), in: arrange) == Tick(1000))
        arrange.snap = .bar
        #expect(BrowserModel.snappedDropTick(Tick(3000), in: arrange) == Tick(3840))
    }

    @Test("UI-063: double-click / Return loads onto the selected track at the playhead; with no track selected, onto a new track")
    func doubleClickLoads() async throws {
        let (browser, window, engine) = try browser(tracks: ["A", "B"])
        try browser.library.addPlace(files)
        browser.selectSidebar(.place(try #require(browser.library.places.first).id))
        await browser.settle()
        let kick = try #require(browser.rows.first { $0.item.name == "kick.wav" })
        engine.locate(Tick(1234))
        window.pollTransport()
        window.selectedTracks = [window.project.tracks[1].id]
        browser.activate(kick.id)  // the double-click
        try await waitUntil { window.project.tracks[1].clips.count == 1 }
        #expect(window.project.tracks[1].clips[0].start == Tick(1234), "at the playhead, not snapped")
        window.selectedTracks = []
        let result = try await browser.loadAtPlayhead(kick.item)
        #expect(result.newTrack && window.project.tracks.count == 3)
        #expect(result.imported.isEmpty, "the asset loaded the first time is reused")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !condition() && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
