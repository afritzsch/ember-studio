import AppKit
import AVFoundation
import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-042 (T-082): the export dialog. View-model tests over a FakeEngine (settings, ranges, the spec
// it renders with, DW-177's click, toasts), and one export through the app path on a real offline
// engine, driven by `ui.perform` like attach mode, whose file is checked (format, bit depth,
// normalized peak).

@MainActor
@Suite("Export dialog (UI-042)", .serialized)
struct ExportDialogTests {
    /// A window with a MIDI track and two clips (ticks 960…2880 and 7680…8640).
    private func makeExportWindow() throws -> (ProjectWindowModel, FakeEngine, TempDir) {
        let (window, engine) = try makeWindow()
        window.perform(AddTrack(name: "Keys", kind: .midi))
        let track = window.project.tracks[0].id
        window.perform(AddClip(trackID: track, start: Tick(960), length: Tick(1920)))
        window.perform(AddClip(trackID: track, start: Tick(7680), length: Tick(960)))
        let dir = try TempDir()
        window.exportDialog.unsavedDirectory = dir.url
        return (window, engine, dir)
    }

    private func perform(_ window: ProjectWindowModel, _ id: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let control = try window.control(id, sourceLocation: sourceLocation)
        #expect(control.isEnabled, "\(id) is enabled", sourceLocation: sourceLocation)
        control.action()
    }

    private func waitForExport(_ export: ExportModel) async {
        for _ in 0..<1000 where export.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("UI-042, UI-052: export is always listed; open, the panel has its controls and the defaults (whole project, 24-bit WAV, dither on, normalize, metronome off)")
    func controlsAndDefaults() throws {
        let (window, _, dir) = try makeExportWindow()
        let ids = window.controls.map(\.id)
        #expect(ids.contains("export.dialog") && !ids.contains("export.start"), "closed: only the toggle")
        try perform(window, "export.dialog")
        let export = window.exportDialog
        #expect(export.isOpen)
        let open = Set(window.controls.map(\.id))
        let expected: Set<String> = [
            "export.dialog", "export.close", "export.start", "export.choose", "export.range.loop", "export.range.project",
            "export.range.selection", "export.format.wav", "export.format.aiff", "export.format.caf",
            "export.sampleFormat.int16", "export.sampleFormat.int24", "export.sampleFormat.float32", "export.dither",
            "export.normalize", "export.tail", "export.tailMax.2", "export.tailMax.5", "export.tailMax.10", "export.tailMax.30",
            "export.metronome",
        ]
        #expect(expected.isSubset(of: open))
        #expect(window.controls.filter { $0.id.hasPrefix("export") }.count == expected.count, "each id once")
        #expect(export.range == .project && export.fileType == .wav && export.sampleFormat == .int24)
        #expect(export.dither && !export.normalize && export.tail && export.tailMaxSeconds == 10 && !export.includeMetronome)
        #expect(try window.control("export.range.project").isOn == true)
        #expect(try window.control("export.normalize").isOn == false)
        #expect(try window.control("export.metronome").isOn == false)
        #expect(export.destination == dir.file("Test.wav"), "named after the project, in the unsaved folder")
        // Whole project: to the end of the last clip.
        #expect(export.span(.project)?.from == Tick(0) && export.span(.project)?.to == Tick(8640))
        try perform(window, "export.close")
        #expect(!export.isOpen && !window.controls.map(\.id).contains("export.start"))
    }

    @Test("UI-042: loop and selection ranges are disabled until there is a loop region or a selected clip; selection = the selected clips' span")
    func ranges() throws {
        let (window, _, _) = try makeExportWindow()
        let export = window.exportDialog
        export.isOpen = true
        #expect(try window.control("export.range.loop").isEnabled == false)
        #expect(try window.control("export.range.selection").isEnabled == false)
        #expect(export.span(.selection) == nil)

        window.selectedClips = Set(window.project.tracks[0].clips.map(\.id))
        try perform(window, "export.range.selection")
        #expect(export.range == .selection)
        #expect(export.span(.selection)?.from == Tick(960) && export.span(.selection)?.to == Tick(8640))
        window.selectedClips = [window.project.tracks[0].clips[1].id]
        #expect(export.span(.selection)?.from == Tick(7680) && export.span(.selection)?.to == Tick(8640))

        window.selectedClips = []
        #expect(try window.control("export.start").isEnabled == false, "nothing selected: nothing to export")
        export.isOpen = false
        export.isOpen = true
        #expect(export.range == .project, "reopening falls back to a range that exists")

        window.perform(SetLoop(start: Tick(1920), end: Tick(5760)))
        try perform(window, "export.range.loop")
        #expect(export.span(.loop)?.from == Tick(1920) && export.span(.loop)?.to == Tick(5760))
        #expect(abs(export.seconds(export.span(.loop)!) - 2) < 1e-9, "2 bars of 4/4 at 120 bpm")
    }

    @Test("UI-042, IO-035: dither follows the sample format (on for int16/int24, off and disabled for float32); the file type sets the extension")
    func formats() throws {
        let (window, _, dir) = try makeExportWindow()
        let export = window.exportDialog
        export.isOpen = true
        try perform(window, "export.sampleFormat.float32")
        #expect(export.sampleFormat == .float32 && !export.spec.dither)
        #expect(try window.control("export.dither").isEnabled == false && window.control("export.dither").isOn == false)
        try perform(window, "export.sampleFormat.int16")
        #expect(export.spec.dither && export.spec.sampleFormat == .int16)
        try perform(window, "export.dither")
        #expect(!export.spec.dither, "dither can be turned off for integers")
        try perform(window, "export.format.aiff")
        #expect(export.fileType == .aiff && export.destination == dir.file("Test.aif"))
        try perform(window, "export.format.caf")
        #expect(export.destination?.pathExtension == "caf")
        try perform(window, "export.tail")
        #expect(try !export.spec.tailEnabled && window.control("export.tailMax.30").isEnabled == false)
        try perform(window, "export.tail")
        try perform(window, "export.tailMax.30")
        #expect(export.spec.tailEnabled && export.spec.tailMaxSeconds == 30)
    }

    @Test("UI-042: Export renders the chosen range with the dialog's spec on the window's engine, then toasts and closes")
    func rendersSpec() async throws {
        let (window, engine, dir) = try makeExportWindow()
        let export = window.exportDialog
        window.perform(SetLoop(start: Tick(1920), end: Tick(5760)))
        try perform(window, "export.dialog")
        try perform(window, "export.range.loop")
        try perform(window, "export.format.aiff")
        try perform(window, "export.sampleFormat.int16")
        try perform(window, "export.normalize")
        try perform(window, "export.tailMax.5")
        try perform(window, "export.start")
        #expect(export.isRunning)
        #expect(try window.control("export.normalize").isEnabled == false, "settings are locked while it renders")
        await waitForExport(export)
        #expect(!export.isRunning && export.lastError == nil)
        let render = engine.calls.compactMap { call -> (Tick, Tick, String)? in
            if case .renderOffline(let from, let to, let path) = call { (from, to, path) } else { nil }
        }
        #expect(render.count == 1 && render[0].0 == Tick(1920) && render[0].1 == Tick(5760))
        let spec = try #require(engine.exportSpecs.last)
        #expect(spec.path == dir.file("Test.aif").path)
        #expect(spec.fileType == .aiff && spec.sampleFormat == .int16 && spec.dither && spec.normalize)
        #expect(spec.tailEnabled && spec.tailMaxSeconds == 5 && !spec.followLoop)
        #expect(export.lastResult?.path == dir.file("Test.aif").path && export.progress == 1)
        #expect(!export.isOpen, "a finished export closes the panel")
        let toast = try #require(window.toasts.toasts.last)
        #expect(toast.severity == .info && toast.title == "Exported Test.aif")
        #expect(toast.message.contains("16-bit AIFF") && toast.message.contains("normalized"))
    }

    @Test("DW-177: the export leaves the project's click out (on slot held at 0 for the render) unless Include Metronome is on")
    func metronomeLeftOut() async throws {
        let (window, engine, _) = try makeExportWindow()
        window.perform(SetMetronome(enabled: true))
        window.store.engineSync?.flush()
        let export = window.exportDialog

        func renderCalls() async throws -> [FakeEngine.Call] {
            engine.clearCalls()
            export.isOpen = true
            try perform(window, "export.start")
            await waitForExport(export)
            return engine.calls
        }
        func zeroWrites(_ calls: [FakeEngine.Call]) -> [ParamID] {
            calls.compactMap { if case .setParam(let id, let v) = $0, v == 0 { id } else { nil } }
        }

        let calls = try await renderCalls()
        let renderIndex = try #require(calls.firstIndex { if case .renderOffline = $0 { true } else { false } })
        let before = zeroWrites(Array(calls[..<renderIndex]))
        #expect(before.count == 1, "the metronome's on slot goes to 0 before the render")
        let slot = try #require(before.first)
        let after = calls[(renderIndex + 1)...].contains { if case .setParam(let id, let v) = $0 { id == slot && v == 1 } else { false } }
        #expect(after, "and follows the project (on) again afterwards")
        #expect(window.store.engineSync?.isMetronomeSuppressed == false)

        export.isOpen = true
        try perform(window, "export.metronome")
        let included = try await renderCalls()
        #expect(!zeroWrites(included).contains(slot), "Include Metronome: the click stays on")
    }

    @Test("UI-042, UI-004: a failed export posts an error toast, keeps the panel open and reports the error")
    func failure() async throws {
        let (window, engine, _) = try makeExportWindow()
        engine.failNextRender(.engine(code: .io, detail: "disk full"))
        let export = window.exportDialog
        export.isOpen = true
        try perform(window, "export.start")
        await waitForExport(export)
        #expect(export.isOpen && export.lastError?.contains("disk full") == true)
        let toast = try #require(window.toasts.toasts.last)
        #expect(toast.severity == .error && toast.title == "Export failed" && toast.message.contains("disk full"))
        #expect(window.store.engineSync?.isMetronomeSuppressed == false)
    }

    @Test("UI-042: the default destination doesn't overwrite (\"Test 2.wav\"), lives in Bounces/ of a saved project, and Choose… replaces it")
    func destinations() async throws {
        let (window, _, dir) = try makeExportWindow()
        let export = window.exportDialog
        try Data().write(to: dir.file("Test.wav"))
        export.isOpen = true
        #expect(export.destination == dir.file("Test 2.wav"))
        export.isOpen = false

        try await window.store.save(to: dir.file("Song.dawproject"))
        export.isOpen = true
        #expect(export.destination?.path == dir.file("Song.dawproject/Bounces/\(window.project.name).wav").path)

        var offered: (URL, ExportSpec.FileType)?
        export.chooseDestination = { start, type, done in
            offered = (start, type)
            done(dir.file("elsewhere/mix.aif"))
        }
        let suggested = export.destination
        try perform(window, "export.choose")
        #expect(offered?.0 == suggested && offered?.1 == .wav, "the panel starts at the current destination")
        #expect(export.destination == dir.file("elsewhere/mix.aif") && export.fileType == .aiff && export.destinationChosen)
        export.isOpen = false
        export.isOpen = true
        #expect(export.destination == dir.file("elsewhere/mix.aif"), "a chosen destination is kept")
        export.chooseDestination = { _, _, done in done(nil) }
        try perform(window, "export.choose")
        #expect(export.destination == dir.file("elsewhere/mix.aif"), "cancel keeps it")
    }

    @Test("UI-042, UI-050/052: a real export through the app path (ui.perform on a real offline engine): 16-bit WAV, normalized to −0.1 dBFS; ui.state export")
    func realExport() async throws {
        let dir = try TempDir()
        let source = dir.file("tone.wav")
        try writeTone(source, amplitude: 0.25, seconds: 1)
        let app = AppModel(engine: .offline, makeEngine: { rate throws(DAWError) in try EngineClient(.offline(sampleRate: rate)) },
                           workingDirectory: dir.url)
        let window = app.newProject()
        window.store.autosavePolicy = nil
        window.exportDialog.unsavedDirectory = dir.url
        let d = app.dispatcher
        _ = try await d.call(.commandApply, ["command": ["type": "AddTrack", "name": "Tone", "kind": "audio"]])
        let imported = try await d.call(.assetImport, ["path": .string(source.path)])
        let asset = try #require(imported["assetID"])
        let track = window.project.tracks[0].id
        _ = try await d.call(.commandApply, ["command": ["type": "AddClip", "trackID": .int(Int64(track)), "start": 0,
                                                         "length": 1920, "assetID": asset]])

        for id in ["export.dialog", "export.sampleFormat.int16", "export.normalize", "export.tail"] {
            _ = try await d.call(.uiPerform, ["accessibilityId": .string(id), "action": "click"])
        }
        let state = try await d.call(.uiState)
        let before = try #require(state["windows"]?[0]?["export"])
        #expect(before["open"] == true && before["range"] == "project" && before["sampleFormat"] == "int16")
        #expect(before["dither"] == true && before["normalize"] == true && before["tail"] == false && before["includeMetronome"] == false)
        #expect(before["ranges"]?[1] == ["id": "project", "available": true, "from": 0, "to": 3840, "seconds": 2.0])
        #expect(before["ranges"]?[2]?["available"] == false)
        let path = try #require(before["path"]?.stringValue)
        #expect(path == dir.file("Untitled.wav").path)

        _ = try await d.call(.uiPerform, ["accessibilityId": "export.start", "action": "click"])
        await waitForExport(window.exportDialog)
        #expect(window.exportDialog.lastError == nil)
        let after = try #require(try await d.call(.uiState)["windows"]?[0]?["export"])
        #expect(after["open"] == false && after["running"] == false && after["error"] == .null)
        let result = try #require(after["lastResult"])
        #expect(result["frames"] == 96_000 && result["rtViolations"] == 0 && result["clippedSamples"] == 0)
        // The clip plays the tone through the track and master strips (centre pan: −3 dB each).
        let peak = try #require(result["peak"]?.doubleValue)
        #expect(abs(peak - 0.125) < 0.002)
        #expect(abs((result["normalizeGain"]?.doubleValue ?? 0) - pow(10, -0.1 / 20) / peak) < 1e-9)

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let settings = file.fileFormat.settings
        #expect(settings[AVLinearPCMBitDepthKey] as? Int == 16 && settings[AVLinearPCMIsFloatKey] as? Bool == false)
        #expect(file.fileFormat.sampleRate == 48_000 && file.length == 96_000)
        let filePeak = try peakOf(file)
        let target = pow(10, -0.1 / 20)
        #expect(abs(filePeak - target) <= 2.5 / 32768, "normalized peak \(filePeak) vs \(target)")
        #expect(window.toasts.toasts.last?.title == "Exported Untitled.wav")
        await app.quit()
    }

    @Test("UI-042, UI-051: the export panel shows in a real window (in the layout, under the toolbar) and in ui.snapshot")
    func snapshot() async throws {
        let dir = try TempDir()
        let t = TestApp(workingDirectory: dir.url)
        let manager = realWindowManager(for: t.app)
        let window = t.app.newProject()
        defer { manager.close(window) }
        window.exportDialog.unsavedDirectory = dir.url
        let content = try #require(manager.nsWindow(for: window)?.contentView)
        content.layoutSubtreeIfNeeded()
        let closed = try await t.app.dispatcher.call(.uiSnapshot, ["path": .string(dir.file("closed.png").path)])
        _ = try await t.app.dispatcher.call(.uiPerform, ["accessibilityId": "export.dialog", "action": "on"])
        content.layoutSubtreeIfNeeded()
        let open = try await t.app.dispatcher.call(.uiSnapshot, ["path": .string(dir.file("export.png").path)])
        let a = try Data(contentsOf: URL(fileURLWithPath: try #require(closed["pngPath"]?.stringValue)))
        let b = try Data(contentsOf: URL(fileURLWithPath: try #require(open["pngPath"]?.stringValue)))
        #expect(try #require(NSBitmapImageRep(data: b)).pixelsWide >= 760)
        #expect(a != b, "the panel changes what the window shows")
    }

    private func writeTone(_ url: URL, amplitude: Float, seconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for c in 0..<2 {
            let data = buffer.floatChannelData![c]
            for i in 0..<Int(frames) { data[i] = amplitude * sinf(2 * .pi * 440 * Float(i) / 48_000) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func peakOf(_ file: AVAudioFile) throws -> Double {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        var peak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            let data = buffer.floatChannelData![c]
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        }
        return Double(peak)
    }
}
