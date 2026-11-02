import AppKit
import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-010 (tiles, only what is visible drawn), UI-011 (Metal waveforms; their offscreen snapshot path,
// DW-154), UI-014 (playhead layer moves without redrawing) on the real AppKit canvas in a window.

@MainActor
private func canvas(in root: NSView) -> TimelineCanvasView? {
    if let canvas = root as? TimelineCanvasView { return canvas }
    for view in root.subviews {
        if let found = canvas(in: view) { return found }
    }
    return nil
}

/// sRGB components 0…255 of a pixel of `image`, (x, y) from the top-left.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let rep = NSBitmapImageRep(cgImage: image)
    let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}

@MainActor
@Suite("Arrange canvas view (UI-010, UI-011, UI-014, DW-154)", .serialized)
struct CanvasViewTests {
    /// A window with tracks A, B (audio), M (MIDI) and one 1-bar audio clip on A whose peaks the
    /// FakeEngine reports (a 4 Hz sine envelope over its first second).
    private func makeApp() throws -> (TestApp, WindowManager, ProjectWindowModel, TimelineCanvasView, clip: ModelID) {
        let t = TestApp()
        let manager = realWindowManager(for: t.app)
        let window = t.app.newProject()
        window.perform(AddTrack(name: "A", kind: .audio))
        window.perform(AddTrack(name: "B", kind: .audio))
        let engine = try #require(t.engines.last)
        let asset = window.project.ids.next
        _ = engine.loadAsset(asset, path: "/tmp/loop.wav")
        window.perform(ImportAsset(asset: AssetRef(id: asset, path: "/tmp/loop.wav", channels: 2, originalSampleRate: 48_000,
                                                   frames: 4 * 48_000)))
        window.engineEventsArrived(engine.pollEvents())
        window.perform(AddClip(trackID: window.project.tracks[0].id, start: 0, length: 3840, assetID: asset))
        let content = try #require(manager.nsWindow(for: window)?.contentView)
        content.layoutSubtreeIfNeeded()
        let view = try #require(canvas(in: content), "the arrange area hosts the canvas")
        view.displayNow()
        return (t, manager, window, view, window.project.tracks[0].clips[0].id)
    }

    @Test("UI-010, UI-011: the canvas sits in the window and draws grid, clip and Metal waveform; the snapshot path renders them")
    func drawsClipAndWaveform() throws {
        guard WaveformRenderer.shared != nil else { return }  // no Metal device: nothing to check
        let (_, manager, window, view, _) = try makeApp()
        defer { manager.close(window) }
        #expect(view.bounds.width > 300 && view.bounds.height > 100)
        #expect(window.arrange.viewSize == view.bounds.size, "the view reports its size to the model")
        let image = try #require(view.snapshotImage(scale: 1))
        let g = window.arrange.geometry
        let rect = g.rect(start: 0, length: 3840, row: 0)
        let laneTop = rect.minY + WaveformMesh.headerHeight
        let laneHeight = (rect.maxY - 1 - laneTop) / 2
        let center = Int(laneTop + laneHeight / 2)
        // x = 4 is 1/16 s into the clip, where the left channel's envelope peaks: a dark waveform bar.
        let wave = pixel(image, 4, center)
        // x = 8 is 1/8 s, where it is silent: clip colour above the hairline.
        let body = pixel(image, 8, center - 6)
        #expect(wave.r + wave.g + wave.b < body.r + body.g + body.b - 60, "waveform \(wave) over clip \(body)")
        #expect(body.b > body.r, "the default clip colour is blue: \(body)")
        let empty = pixel(image, Int(rect.maxX) + 40, center)
        #expect(empty != body, "outside the clip is the row background")
        let ruler = pixel(image, 50, 18)
        #expect(ruler.r > 60 && ruler.r < 130 && ruler != pixel(image, 50, Int(rect.maxY) + 30), "the ruler strip: \(ruler) vs \(pixel(image, 50, Int(rect.maxY) + 30))")

        // The window snapshot (ui.snapshot) carries the same canvas pixels.
        let png = try manager.snapshot(window)
        let rep = try #require(NSBitmapImageRep(data: png.png))
        let content = try #require(manager.nsWindow(for: window)?.contentView)
        let origin = view.convert(CGPoint.zero, to: content)
        let scale = Double(rep.pixelsWide) / content.bounds.width
        let px = Int((origin.x + 4) * scale), py = Int((origin.y + Double(center)) * scale)
        let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) ?? .white
        let sum = Int(c.redComponent * 255) + Int(c.greenComponent * 255) + Int(c.blueComponent * 255)
        let bodySum = body.r + body.g + body.b
        #expect(sum < bodySum - 60, "the waveform shows in the window snapshot")
        if let dir = ProcessInfo.processInfo.environment["EMBER_SNAPSHOT_DIR"] {
            try png.png.write(to: URL(fileURLWithPath: dir).appending(path: "canvas-window.png"))
        }
    }

    @Test("UI-010: scrolling inside drawn tiles draws none; a content change redraws only the visible tiles")
    func tiles() throws {
        let (_, manager, window, view, _) = try makeApp()
        defer { manager.close(window) }
        window.arrange.scroll(dx: 10, dy: 0)
        view.displayNow()
        let drawn = view.tilesDrawn
        #expect(view.tileCount >= 1 && view.tileCount <= 4, "viewport-sized tiles")
        window.arrange.scroll(dx: 15, dy: 0)
        view.displayNow()
        #expect(view.tilesDrawn == drawn, "the tiles moved, nothing redrew")
        window.arrange.selectAll()
        view.displayNow()
        #expect(view.tilesDrawn == drawn + view.tileCount, "a selection change redraws the visible tiles once")
        window.arrange.scroll(dx: 100_000, dy: 0)
        view.displayNow()
        #expect(view.tileCount <= 4, "tiles that left the view are dropped")
    }

    @Test("UI-014: the playhead layer follows the engine's transport without redrawing tiles")
    func playhead() throws {
        let (t, manager, window, view, _) = try makeApp()
        defer { manager.close(window) }
        let engine = try #require(t.engines.last)
        let drawn = view.tilesDrawn
        engine.locate(3840)
        view.movePlayhead()
        #expect(abs(view.playheadX - window.arrange.geometry.x(3840)) < 1)
        engine.locate(960)
        view.movePlayhead()
        #expect(abs(view.playheadX - 32) < 1)
        view.displayNow()
        #expect(view.tilesDrawn == drawn, "moving the playhead redrew nothing")
    }
}
