import AppKit
import DAWModel

/// UI-015 (T-075): draws an automation lane row of the arrange canvas (y-down context, geometry in
/// view coordinates like the rest of `CanvasPainter.drawTile`): a centre line, the curve as the
/// model evaluates it (`AutomationLane.value(at:)`, the engine's curves), and its points. An `off`
/// lane is drawn dimmed; a lane without points shows only its row.
@MainActor
enum AutomationLanePainter {
    static let laneColor = NSColor(calibratedWhite: 0.14, alpha: 1)
    static let curveColor = NSColor.systemOrange
    static let pointFill = NSColor.white
    /// The curve is sampled every this many points between breakpoints.
    static let step = 3.0

    static func draw(_ ctx: CGContext, _ row: LaneRow, width: Double, geometry g: TimelineGeometry, lanes: AutomationLanesModel) {
        let r = lanes.valueRect(row: row.row, geometry: g)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.06).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeLineSegments(between: [CGPoint(x: 0, y: r.midY.rounded() + 0.5), CGPoint(x: width, y: r.midY.rounded() + 0.5)])
        let lane = row.lane
        guard !lane.points.isEmpty else { return }
        let alpha: CGFloat = lane.isEnabled ? 1 : 0.35
        // The curve across the visible width; each breakpoint inside the span is hit exactly.
        let from = g.tick(atX: 0).raw, to = g.tick(atX: width).raw + 1
        var ticks: [Int64] = stride(from: 0.0, through: width, by: step).map { g.tick(atX: $0).raw }
        for point in lane.points where point.tick.raw >= from && point.tick.raw <= to {
            ticks.append(point.tick.raw)
            ticks.append(point.tick.raw - 1)  // a hold's step reads as a step
        }
        ticks.sort()
        let path = CGMutablePath()
        for (i, tick) in ticks.enumerated() {
            let value = lane.value(at: Tick(tick)) ?? 0
            let p = CGPoint(x: g.x(Tick(tick)), y: lanes.y(of: value, row: row.row, geometry: g))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.addPath(path)
        ctx.setStrokeColor(curveColor.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        let radius = AutomationLanesModel.pointRadius
        for point in lane.points where point.tick.raw >= from - 1000 && point.tick.raw <= to + 1000 {
            let c = CGPoint(x: g.x(point.tick), y: lanes.y(of: point.value, row: row.row, geometry: g))
            let box = CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius)
            ctx.setFillColor(pointFill.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: box)
            ctx.setStrokeColor(curveColor.withAlphaComponent(alpha).cgColor)
            ctx.strokeEllipse(in: box)
        }
    }
}
