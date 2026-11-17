import AppKit
import DAWModel

/// UI-016 (T-081): draws take folders on the arrange canvas (y-down context, geometry in view
/// coordinates like the rest of `CanvasPainter.drawTile`). Waveforms are the Metal layer's
/// (`ArrangeModel.waveformBars` adds the comp and take pieces).
///   - On the track's row: the comp, each segment as its take's clip cut to it, under a folder
///     band (disclosure triangle, "Takes", the take count) with ticks at the segment boundaries
///     and each segment's take number.
///   - On a take row (expanded): the take's clip, its comp parts outlined and the rest dimmed; a
///     swipe in progress shows as a highlight over its range.
@MainActor
enum TakeFolderPainter {
    static let takeRowColor = NSColor(calibratedWhite: 0.155, alpha: 1)
    static let folderColor = NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.25, alpha: 1)
    static let bandColor = NSColor(calibratedRed: 0.28, green: 0.22, blue: 0.12, alpha: 1)
    static let dimColor = NSColor(calibratedWhite: 0.05, alpha: 0.55)

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.92),
    ]
    private static let smallAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.85),
    ]

    /// A take row's background band.
    static func drawRowBackground(_ ctx: CGContext, y: Double, width: Double, height: Double) {
        ctx.setFillColor(takeRowColor.cgColor)
        ctx.fill(CGRect(x: 0, y: y, width: width, height: height))
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)
        ctx.fill(CGRect(x: 0, y: y + height - 1, width: width, height: 1))
    }

    /// A folder, collapsed or not, on its track's row: the comp and the folder band.
    static func drawFolder(_ ctx: CGContext, _ p: FolderPlacement, track: Track, project: Project, expanded: Bool,
                           geometry g: TimelineGeometry, takes: TakeFoldersModel) {
        let r = takes.folderRect(p, geometry: g)
        for clip in p.folder.flattened(tempo: project.tempoMap) {
            CanvasPainter.drawClip(ctx, clip, track: track, rect: g.rect(start: clip.start, length: clip.length, row: p.trackIndex),
                                   selected: false, geometry: g, project: project)
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let band = CGRect(x: r.minX, y: r.minY, width: r.width, height: WaveformMesh.headerHeight)
        ctx.clip(to: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height))
        ctx.setFillColor(bandColor.cgColor)
        ctx.fill(band)
        // The folder's label, then each segment's boundary (below the band) and take number; a
        // number that would run into the label or past its segment is left out.
        drawDisclosure(ctx, takes.disclosureRect(p, geometry: g), expanded: expanded)
        let label = "Takes \(p.folder.takes.count)" as NSString
        var labelEnd = r.minX + Self.labelInset
        if r.width > Self.labelInset + 40 {
            CanvasPainter.withAppKitContext(ctx) { label.draw(at: CGPoint(x: r.minX + Self.labelInset, y: r.minY), withAttributes: labelAttributes) }
            labelEnd += label.size(withAttributes: labelAttributes).width
        }
        let numbers = Dictionary(uniqueKeysWithValues: p.folder.takes.enumerated().map { ($1.id, $0 + 1) })
        for (i, segment) in p.folder.comp.enumerated() {
            let x = g.x(segment.start)
            if i > 0 {
                ctx.setStrokeColor(folderColor.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(1)
                ctx.strokeLineSegments(between: [CGPoint(x: x.rounded() + 0.5, y: band.maxY), CGPoint(x: x.rounded() + 0.5, y: r.maxY)])
            }
            let labelX = max(x + 3, labelEnd + 6)
            if g.x(segment.end) - labelX > 18, let n = numbers[segment.take] {
                CanvasPainter.withAppKitContext(ctx) {
                    ("T\(n)" as NSString).draw(at: CGPoint(x: labelX, y: r.minY + 1), withAttributes: smallAttributes)
                }
            }
        }
        ctx.resetClip()
        ctx.setStrokeColor(folderColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.strokePath()
    }

    /// Where a folder band's label starts (after the triangle).
    static let labelInset = TakeFoldersModel.disclosureSize + 4

    private static func drawDisclosure(_ ctx: CGContext, _ box: CGRect, expanded: Bool) {
        let c = CGPoint(x: box.midX, y: box.midY)
        let s = 4.0
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.95).cgColor)
        if expanded {
            ctx.move(to: CGPoint(x: c.x - s, y: c.y - s * 0.6))
            ctx.addLine(to: CGPoint(x: c.x + s, y: c.y - s * 0.6))
            ctx.addLine(to: CGPoint(x: c.x, y: c.y + s * 0.8))
        } else {
            ctx.move(to: CGPoint(x: c.x - s * 0.6, y: c.y - s))
            ctx.addLine(to: CGPoint(x: c.x + s * 0.8, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x - s * 0.6, y: c.y + s))
        }
        ctx.closePath()
        ctx.fillPath()
    }

    /// A take row: the take's clip, its comp parts outlined, the rest dimmed, and the swipe.
    static func drawTake(_ ctx: CGContext, _ row: TakeRow, folder: TakeFolder, track: Track, project: Project,
                         geometry g: TimelineGeometry, takes: TakeFoldersModel) {
        let r = takes.takeRect(row, geometry: g)
        CanvasPainter.drawClip(ctx, row.take.clip, track: track, rect: r, selected: false, geometry: g, project: project)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // The title band names the take.
        ctx.clip(to: r)
        ctx.setFillColor(bandColor.cgColor)
        ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: WaveformMesh.headerHeight))
        if r.width > 30 {
            CanvasPainter.withAppKitContext(ctx) {
                ("Take \(row.number)" as NSString).draw(at: CGPoint(x: max(r.minX, 0) + 6, y: r.minY), withAttributes: labelAttributes)
            }
        }
        ctx.resetClip()
        for piece in TakeFoldersModel.pieces(of: row.take, in: folder) {
            let x0 = g.x(piece.start), x1 = g.x(piece.end)
            let body = CGRect(x: x0, y: r.minY + WaveformMesh.headerHeight, width: max(x1 - x0, 1), height: r.height - WaveformMesh.headerHeight)
            if piece.inComp {
                ctx.setStrokeColor(folderColor.cgColor)
                ctx.setLineWidth(2)
                ctx.stroke(CGRect(x: x0, y: r.minY, width: max(x1 - x0, 1), height: r.height).insetBy(dx: 1, dy: 1))
            } else {
                ctx.setFillColor(dimColor.cgColor)
                ctx.fill(body)
            }
        }
        if let swipe = takes.swipe, swipe.started, swipe.folderID == row.folderID, swipe.takeID == row.take.id {
            let range = swipe.range
            let x0 = g.x(range.start), x1 = g.x(range.end)
            let rect = CGRect(x: x0, y: r.minY, width: max(x1 - x0, 1), height: r.height)
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}
