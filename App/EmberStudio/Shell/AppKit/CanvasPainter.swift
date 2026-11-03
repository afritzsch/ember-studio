import AppKit
import DAWModel

/// UI-010/012/013: Core Graphics drawing for the arrange canvas's tiles (row backgrounds, grid, clip
/// bodies with fades, gain and selection) and its ruler. Waveforms are the Metal layer's (UI-011)
/// and the playhead its own layer (UI-014). Every function draws in a y-down context.
@MainActor
enum CanvasPainter {
    static let rowColor = NSColor(calibratedWhite: 0.17, alpha: 1)
    static let rowAltColor = NSColor(calibratedWhite: 0.19, alpha: 1)
    static let emptyColor = NSColor(calibratedWhite: 0.13, alpha: 1)
    static let barLine = NSColor(calibratedWhite: 1, alpha: 0.28)
    static let beatLine = NSColor(calibratedWhite: 1, alpha: 0.12)
    static let subLine = NSColor(calibratedWhite: 1, alpha: 0.05)
    static let selection = NSColor.controlAccentColor
    /// Grid lines closer than this (points) are left out.
    static let minLineSpacing = 8.0

    /// Draws the part of the arrange content in `rect` (content coordinates: x = tick × pixels per
    /// tick, y = row × track height, no ruler) with its top-left at the context's origin.
    static func drawTile(_ ctx: CGContext, contentRect rect: CGRect, model: ArrangeModel) {
        var g = model.geometry
        g.scrollX = rect.minX
        g.scrollY = rect.minY
        g.size = CGSize(width: rect.width, height: rect.height + TimelineGeometry.rulerHeight)
        // Geometry y includes the ruler; tiles don't.
        ctx.translateBy(x: 0, y: -TimelineGeometry.rulerHeight)
        let rows = model.tracks.count
        let firstRow = Int((rect.minY / g.trackHeight).rounded(.down))
        let lastRow = Int((rect.maxY / g.trackHeight).rounded(.up))

        // Row backgrounds (and the empty area below the last track).
        for row in firstRow..<max(lastRow, firstRow) {
            let color = row >= rows || row < 0 ? emptyColor : row % 2 == 0 ? rowColor : rowAltColor
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: g.rowY(row), width: rect.width, height: g.trackHeight))
        }

        // Grid (UI-012).
        let from = g.tick(atX: 0), to = Tick(g.tick(atX: rect.width).raw + 1)
        let lines = model.grid.lines(from: from, to: to, minSpacing: minLineSpacing / g.pixelsPerTick, snap: model.snap)
        let bottom = g.rowY(max(lastRow, rows))
        for line in lines {
            let x = (g.x(line.tick)).rounded() + 0.5
            let color: NSColor = switch line.kind {
            case .bar: barLine
            case .beat: beatLine
            case .subdivision: subLine
            }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: TimelineGeometry.rulerHeight), CGPoint(x: x, y: bottom)])
        }

        // Clips, through the interval index (UI-010).
        let selection = model.selection
        let tracks = model.tracks
        model.index.forEachClip(rows: max(firstRow, 0)..<min(lastRow, rows), from: from.raw, to: to.raw) { entry in
            drawClip(ctx, entry.clip, track: tracks[entry.row], rect: g.rect(start: entry.clip.start, length: entry.clip.length, row: entry.row),
                     selected: selection.contains(entry.id), geometry: g, project: model.project)
        }
    }

    static func drawClip(_ ctx: CGContext, _ clip: Clip, track: Track, rect r: CGRect, selected: Bool, geometry g: TimelineGeometry,
                         project: Project) {
        let base = NSColor(srgbRed: track.color.red, green: track.color.green, blue: track.color.blue, alpha: 1)
        let fill = (track.color == .gray ? NSColor(srgbRed: 0.33, green: 0.55, blue: 0.78, alpha: 1) : base)
        let path = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(fill.withAlphaComponent(selected ? 0.95 : 0.75).cgColor)
        ctx.fillPath()

        ctx.addPath(path)
        ctx.clip()
        // Title band.
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.18).cgColor)
        ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: WaveformMesh.headerHeight))
        var title: String
        switch clip {
        case .audio(let audio):
            title = project.asset(audio.assetID).map { ($0.path as NSString).lastPathComponent } ?? "Audio"
            if audio.gain != 1 { title += String(format: "  %+.1f dB", ArrangeModel.gainDB(audio.gain)) }
            drawFades(ctx, audio, rect: r, geometry: g)
        case .midi(let midi):
            title = "MIDI"
            drawNotes(ctx, midi, rect: r, geometry: g)
        }
        if r.width > 24 {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.9),
            ]
            withAppKitContext(ctx) {
                (title as NSString).draw(at: CGPoint(x: max(r.minX, 0) + 9, y: r.minY + 1), withAttributes: attributes)
            }
        }
        ctx.restoreGState()

        if case .audio(let audio) = clip, r.width > 24 { drawHandles(ctx, audio, rect: r, geometry: g) }
        ctx.addPath(path)
        ctx.setStrokeColor((selected ? selection : NSColor(calibratedWhite: 0, alpha: 0.5)).cgColor)
        ctx.setLineWidth(selected ? 2 : 1)
        ctx.strokePath()
    }

    /// UI-013: the fade ramps as shaded corners with a line from silence to full level.
    private static func drawFades(_ ctx: CGContext, _ clip: AudioClip, rect r: CGRect, geometry g: TimelineGeometry) {
        let top = r.minY + WaveformMesh.headerHeight
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.3).cgColor)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.7).cgColor)
        ctx.setLineWidth(1)
        if clip.fadeIn.raw > 0 {
            let x = r.minX + Double(clip.fadeIn.raw) * g.pixelsPerTick
            ctx.move(to: CGPoint(x: r.minX, y: top)); ctx.addLine(to: CGPoint(x: x, y: top)); ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            ctx.closePath(); ctx.fillPath()
            ctx.strokeLineSegments(between: [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: x, y: top)])
        }
        if clip.fadeOut.raw > 0 {
            let x = r.maxX - Double(clip.fadeOut.raw) * g.pixelsPerTick
            ctx.move(to: CGPoint(x: r.maxX, y: top)); ctx.addLine(to: CGPoint(x: x, y: top)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            ctx.closePath(); ctx.fillPath()
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: top), CGPoint(x: r.maxX, y: r.maxY)])
        }
    }

    /// UI-013: fade handles at the fades' ends and the gain handle at the top center.
    private static func drawHandles(_ ctx: CGContext, _ clip: AudioClip, rect r: CGRect, geometry g: TimelineGeometry) {
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.85).cgColor)
        let y = r.minY + 2
        let fadeInX = r.minX + Double(clip.fadeIn.raw) * g.pixelsPerTick
        let fadeOutX = r.maxX - Double(clip.fadeOut.raw) * g.pixelsPerTick
        ctx.fill(CGRect(x: min(max(fadeInX - 3, r.minX + 1), r.maxX - 7), y: y, width: 6, height: 6))
        ctx.fill(CGRect(x: max(min(fadeOutX - 3, r.maxX - 7), r.minX + 1), y: y, width: 6, height: 6))
        let gain = CGPath(roundedRect: CGRect(x: r.midX - 7, y: y, width: 14, height: 6), cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(gain)
        ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.8, blue: 0.3, alpha: 0.9).cgColor)
        ctx.fillPath()
    }

    private static func drawNotes(_ ctx: CGContext, _ clip: MidiClip, rect r: CGRect, geometry g: TimelineGeometry) {
        let inside = clip.notes.filter { $0.start.raw < clip.length.raw && $0.start.raw + $0.length.raw > 0 }
        guard let lo = inside.map(\.pitch).min(), let hi = inside.map(\.pitch).max() else { return }
        let top = r.minY + WaveformMesh.headerHeight + 2, height = r.maxY - 3 - top
        let span = Double(max(Int(hi) - Int(lo), 11) + 1)
        ctx.setFillColor(NSColor(calibratedWhite: 0.05, alpha: 0.75).cgColor)
        for note in inside {
            let x0 = r.minX + Double(max(note.start.raw, 0)) * g.pixelsPerTick
            let x1 = r.minX + Double(min(note.start.raw + note.length.raw, clip.length.raw)) * g.pixelsPerTick
            let y = top + (1 - (Double(Int(note.pitch) - Int(lo)) + 1) / span) * height
            ctx.fill(CGRect(x: x0, y: y, width: max(x1 - x0, 1), height: max(height / span, 2)))
        }
    }

    /// The ruler (UI-012): bar numbers and bar/beat ticks over the view's width.
    static func drawRuler(_ ctx: CGContext, size: CGSize, model: ArrangeModel) {
        let g = model.geometry
        ctx.setFillColor(NSColor(calibratedWhite: 0.22, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let from = g.tick(atX: 0), to = Tick(g.tick(atX: size.width).raw + 1)
        let lines = model.grid.lines(from: from, to: to, minSpacing: 40 / g.pixelsPerTick, snap: .off)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1),
        ]
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.7, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        for line in lines {
            let x = g.x(line.tick).rounded() + 0.5
            switch line.kind {
            case .bar(let number):
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: size.height * 0.35), CGPoint(x: x, y: size.height)])
                withAppKitContext(ctx) { ("\(number)" as NSString).draw(at: CGPoint(x: x + 3, y: 2), withAttributes: attributes) }
            default:
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: size.height * 0.7), CGPoint(x: x, y: size.height)])
            }
        }
        ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.6).cgColor)
        ctx.strokeLineSegments(between: [CGPoint(x: 0, y: size.height - 0.5), CGPoint(x: size.width, y: size.height - 0.5)])
    }

    /// AppKit text drawing into a y-down Core Graphics context.
    static func withAppKitContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}
