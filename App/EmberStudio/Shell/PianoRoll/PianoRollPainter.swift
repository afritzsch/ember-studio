import AppKit
import DAWModel

/// UI-020: Core Graphics drawing for the piano roll: the note grid (key rows, bar/beat/snap lines,
/// the clip window, notes), the keyboard, the ruler and the velocity lane. Every function draws in
/// a y-down context, in the view coordinates of the geometry it is given (a tile passes a geometry
/// scrolled to its own origin).
@MainActor
enum PianoRollPainter {
    static let whiteRow = NSColor(calibratedWhite: 0.19, alpha: 1)
    static let blackRow = NSColor(calibratedWhite: 0.155, alpha: 1)
    static let outsideClip = NSColor(calibratedWhite: 0, alpha: 0.35)
    static let octaveLine = NSColor(calibratedWhite: 1, alpha: 0.16)
    static let rowLine = NSColor(calibratedWhite: 0, alpha: 0.25)
    static let noteColor = NSColor(srgbRed: 0.36, green: 0.68, blue: 0.95, alpha: 1)
    static let selectedNote = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.3, alpha: 1)
    static let laneColor = NSColor(calibratedWhite: 0.14, alpha: 1)
    static let minLineSpacing = 8.0

    /// The grid's content inside `clip` (view coordinates of `g`).
    static func drawGrid(_ ctx: CGContext, geometry g: PianoRollGeometry, clip rect: CGRect, model: PianoRollModel) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: rect)
        // Key rows, black keys darker, a line under every C.
        let top = min(max(g.pitch(atY: rect.minY), 0), 127)
        let bottom = min(max(g.pitch(atY: rect.maxY - 0.001), 0), 127)
        if bottom <= top {
            for pitch in bottom...top {
                let y = g.rowY(pitch)
                ctx.setFillColor((PianoRollModel.isBlackKey(pitch) ? blackRow : whiteRow).cgColor)
                ctx.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: g.keyHeight))
                ctx.setFillColor((pitch % 12 == 0 ? octaveLine : rowLine).cgColor)
                ctx.fill(CGRect(x: rect.minX, y: y + g.keyHeight - 1, width: rect.width, height: 1))
            }
        }
        // Below pitch 0 (and above 127): empty.
        let contentBottom = g.rowY(-1)
        if contentBottom < rect.maxY {
            ctx.setFillColor(CanvasPainter.emptyColor.cgColor)
            ctx.fill(CGRect(x: rect.minX, y: contentBottom, width: rect.width, height: rect.maxY - contentBottom))
        }

        // Bar, beat and snap lines (UI-012 grid of the tempo map).
        let from = g.tick(atX: rect.minX) - 1, to = g.tick(atX: rect.maxX) + 1
        let lines = model.grid.lines(from: Tick(max(from, 0)), to: Tick(max(to, 1)), minSpacing: minLineSpacing / g.pixelsPerTick,
                                     snap: model.snap)
        for line in lines {
            let x = g.x(line.tick.raw).rounded() + 0.5
            let color: NSColor = switch line.kind {
            case .bar: CanvasPainter.barLine
            case .beat: CanvasPainter.beatLine
            case .subdivision: CanvasPainter.subLine
            }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY)])
        }

        guard let clip = model.clip else { return }
        // Outside the clip window: shaded (notes there don't play, DW-127).
        let clipX0 = g.x(clip.start.raw), clipX1 = g.x(clip.start.raw + clip.length.raw)
        ctx.setFillColor(outsideClip.cgColor)
        if clipX0 > rect.minX { ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: clipX0 - rect.minX, height: rect.height)) }
        if clipX1 < rect.maxX { ctx.fill(CGRect(x: clipX1, y: rect.minY, width: rect.maxX - clipX1, height: rect.height)) }

        // Notes: those overlapping `rect` only.
        let selection = model.selection
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(min(g.keyHeight - 3, 10), 6), weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0, alpha: 0.75),
        ]
        for note in clip.notes {
            let r = g.rect(note)
            guard r.intersects(rect) else { continue }
            let selected = selection.contains(note.id)
            let base = selected ? selectedNote : noteColor
            // Velocity shows as saturation: soft notes are paler.
            let fill = base.blended(withFraction: 0.55 * (1 - Double(note.velocity) / 127), of: NSColor(calibratedWhite: 0.6, alpha: 1)) ?? base
            let path = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor((selected ? NSColor.white : NSColor(calibratedWhite: 0, alpha: 0.6)).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            if r.width > 28 && g.keyHeight >= 9 {
                CanvasPainter.withAppKitContext(ctx) {
                    (PianoRollModel.noteName(Int(note.pitch)) as NSString).draw(at: CGPoint(x: r.minX + 3, y: r.minY), withAttributes: attributes)
                }
            }
        }
    }

    /// The keyboard column: white and black keys, C labels, sounding keys lit (UI-021).
    static func drawKeyboard(_ ctx: CGContext, geometry g: PianoRollGeometry, model: PianoRollModel) {
        let rect = g.keyboardRect
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: rect)
        ctx.setFillColor(CanvasPainter.emptyColor.cgColor)
        ctx.fill(rect)
        guard let pitches = g.visiblePitches else { return }
        let sounding = Set(model.sounding.map(Int.init))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(min(g.keyHeight - 3, 9), 6)), .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1),
        ]
        for pitch in pitches {
            let y = g.rowY(pitch)
            let black = PianoRollModel.isBlackKey(pitch)
            let key = CGRect(x: rect.minX, y: y, width: black ? rect.width * 0.62 : rect.width, height: g.keyHeight)
            let color: NSColor = sounding.contains(pitch) ? .controlAccentColor
                : black ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
            if black {
                ctx.setFillColor(NSColor(calibratedWhite: 0.93, alpha: 1).cgColor)
                ctx.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: g.keyHeight))
            }
            ctx.setFillColor(color.cgColor)
            ctx.fill(key)
            ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.3).cgColor)
            ctx.fill(CGRect(x: rect.minX, y: y + g.keyHeight - 0.5, width: rect.width, height: 0.5))
            if pitch % 12 == 0 && g.keyHeight >= 8 {
                CanvasPainter.withAppKitContext(ctx) {
                    (PianoRollModel.noteName(pitch) as NSString).draw(at: CGPoint(x: rect.maxX - 22, y: y), withAttributes: attributes)
                }
            }
        }
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.6).cgColor)
        ctx.fill(CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height))
    }

    /// The ruler over the grid: bar numbers and beat ticks.
    static func drawRuler(_ ctx: CGContext, geometry g: PianoRollGeometry, model: PianoRollModel) {
        let rect = CGRect(x: 0, y: 0, width: g.size.width, height: PianoRollGeometry.rulerHeight)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(NSColor(calibratedWhite: 0.22, alpha: 1).cgColor)
        ctx.fill(rect)
        ctx.clip(to: g.rulerRect)
        let from = max(g.tick(atX: g.rulerRect.minX), 0), to = g.tick(atX: g.rulerRect.maxX) + 1
        let lines = model.grid.lines(from: Tick(from), to: Tick(max(to, from + 1)), minSpacing: 40 / g.pixelsPerTick, snap: .off)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1),
        ]
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.7, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        for line in lines {
            let x = g.x(line.tick.raw).rounded() + 0.5
            if case .bar(let number) = line.kind {
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: rect.height * 0.35), CGPoint(x: x, y: rect.height)])
                CanvasPainter.withAppKitContext(ctx) { ("\(number)" as NSString).draw(at: CGPoint(x: x + 3, y: 2), withAttributes: attributes) }
            } else {
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: rect.height * 0.7), CGPoint(x: x, y: rect.height)])
            }
        }
    }

    /// The velocity lane: a stem per visible note, its height the velocity; selected stems lit.
    static func drawLane(_ ctx: CGContext, geometry g: PianoRollGeometry, model: PianoRollModel) {
        let lane = g.laneRect
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(laneColor.cgColor)
        ctx.fill(CGRect(x: 0, y: lane.minY, width: g.size.width, height: lane.height))
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.6).cgColor)
        ctx.fill(CGRect(x: 0, y: lane.minY, width: g.size.width, height: 1))
        CanvasPainter.withAppKitContext(ctx) {
            ("Velocity" as NSString).draw(at: CGPoint(x: 4, y: lane.minY + 4), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1),
            ])
        }
        ctx.clip(to: lane)
        guard let clip = model.clip else { return }
        let selection = model.selection
        let from = g.tick(atX: lane.minX) - 1, to = g.tick(atX: lane.maxX) + 1
        for note in clip.notes {
            let start = g.clipStart + note.start.raw
            guard start >= from && start <= to else { continue }
            let x = g.x(start).rounded() + 0.5
            let y = g.velocityY(note.velocity)
            let color = (selection.contains(note.id) ? selectedNote : noteColor).cgColor
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2)
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: lane.maxY - 2), CGPoint(x: x, y: y)])
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
        }
    }

    /// The hint over an empty pane.
    static func drawPlaceholder(_ ctx: CGContext, size: CGSize) {
        ctx.setFillColor(CanvasPainter.emptyColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let text = "Double-click a MIDI clip (or select one and press P) to edit its notes" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let textSize = text.size(withAttributes: attributes)
        CanvasPainter.withAppKitContext(ctx) {
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
    }
}
