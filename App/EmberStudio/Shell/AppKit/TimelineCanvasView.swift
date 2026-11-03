import AppKit
import DAWModel
import Observation
import QuartzCore

/// UI-051 / DW-154: a view whose layers `cacheDisplay` can't capture (Metal); `WindowSnapshotter`
/// draws its `snapshotImage` over the cached window instead.
@MainActor
protocol SnapshotCompositing: NSView {
    func snapshotImage(scale: CGFloat) -> CGImage?
}

/// UI-010: the arrange canvas. A layer-backed `NSView` (`wantsUpdateLayer`) over `ArrangeModel`:
///   - content is drawn in viewport-sized tiles (CALayers in content coordinates under a container
///     whose sublayer transform is the scroll offset), so scrolling moves layers and draws only tiles
///     that come into view; each tile draws only its clips, found through the interval index;
///   - waveforms are a `CAMetalLayer` (UI-011, `WaveformRenderer`);
///   - the playhead is its own layer, moved per display frame from the engine's transport (UI-014),
///     so playback never redraws the canvas;
///   - the ruler and the marquee overlay are layers of their own.
/// Mouse, scroll and key events go to the model; the view keeps no edit state.
final class TimelineCanvasView: NSView, SnapshotCompositing {
    let model: ArrangeModel

    private struct TileKey: Hashable {
        var column: Int
        var row: Int
    }

    /// What tiles show: when it changes, the visible tiles redraw. Scrolling isn't part of it.
    private struct ContentKey: Equatable {
        var tracks: [Track]
        var assets: [AssetRef]
        var tempoMap: TempoMap
        var selection: Set<ModelID>
        var pixelsPerBeat: Double
        var snap: SnapMode
        var tileSize: CGSize
    }

    private let tileContainer = CALayer()
    private let waveformLayer = CAMetalLayer()
    private let rulerLayer = RulerLayer()
    private let overlayLayer = CAShapeLayer()
    private let playheadLayer = CALayer()
    private var tiles: [TileKey: TileLayer] = [:]
    private var tileSize = CGSize(width: 512, height: 512)
    private var contentKey: ContentKey?
    private var rulerKey: [Double] = []
    private var displayLink: CADisplayLink?
    private var tracking: NSTrackingArea?

    /// Tiles drawn since the view was made (diagnostics: `ui.state` reports it, tests check that
    /// scrolling within drawn tiles draws none).
    private(set) var tilesDrawn = 0

    init(model: ArrangeModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let root = layer!
        root.backgroundColor = CanvasPainter.emptyColor.cgColor
        for sublayer in [tileContainer, waveformLayer, rulerLayer, overlayLayer, playheadLayer] as [CALayer] {
            sublayer.anchorPoint = .zero
            root.addSublayer(sublayer)
        }
        tileContainer.masksToBounds = true
        waveformLayer.pixelFormat = WaveformRenderer.pixelFormat
        waveformLayer.isOpaque = false
        waveformLayer.framebufferOnly = true
        waveformLayer.device = WaveformRenderer.shared?.device
        waveformLayer.presentsWithTransaction = false
        rulerLayer.canvas = self
        rulerLayer.needsDisplayOnBoundsChange = true
        overlayLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        overlayLayer.strokeColor = NSColor.controlAccentColor.cgColor
        overlayLayer.lineWidth = 1
        playheadLayer.backgroundColor = NSColor.systemRed.cgColor
        playheadLayer.zPosition = 10
        disableAnimations(root)
        observeModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func disableAnimations(_ layer: CALayer) {
        let none: [String: any CAAction] = ["position": NSNull(), "bounds": NSNull(), "sublayerTransform": NSNull(),
                                            "contents": NSNull(), "path": NSNull(), "hidden": NSNull(), "frame": NSNull()]
        layer.actions = none
        for sublayer in layer.sublayers ?? [] { sublayer.actions = none }
    }

    // MARK: Observation

    /// Redraws when anything the canvas shows changes (project, selection, zoom, scroll, snap,
    /// marquee, newly loaded peaks). `withObservationTracking` fires once, so it re-arms itself.
    private func observeModel() {
        withObservationTracking {
            _ = model.tracks
            _ = model.project.assets
            _ = model.project.tempoMap
            _ = model.selection
            _ = model.geometry
            _ = model.snap
            _ = model.marquee
            _ = model.peaksVersion
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.needsDisplay = true
                    self.observeModel()
                }
            }
        }
    }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        if model.viewSize != bounds.size { model.viewSize = bounds.size }
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [tileContainer, waveformLayer, rulerLayer, overlayLayer, playheadLayer] as [CALayer] { layer.contentsScale = scale }
        for tile in tiles.values { tile.contentsScale = scale }
        contentKey = nil
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        viewDidChangeBackingProperties()
        // UI-014: the playhead follows the display, not the model.
        let link = displayLink(target: self, selector: #selector(displayFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func updateLayer() {
        refresh()
    }

    /// Brings every layer in line with the model. Called from `updateLayer` (and by snapshots).
    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let size = bounds.size
        let ruler = TimelineGeometry.rulerHeight
        let body = CGRect(x: 0, y: ruler, width: size.width, height: max(size.height - ruler, 0))
        tileContainer.frame = body
        waveformLayer.frame = body
        rulerLayer.frame = CGRect(x: 0, y: 0, width: size.width, height: ruler)
        overlayLayer.frame = bounds
        playheadLayer.frame.size = CGSize(width: 1, height: size.height)
        updateTiles(body: body.size)
        updateRuler()
        overlayLayer.path = model.marquee.map { CGPath(rect: $0.insetBy(dx: 0.5, dy: 0.5), transform: nil) }
        updateWaveforms(body: body.size)
        movePlayhead()
    }

    private func updateTiles(body: CGSize) {
        // Viewport-sized tiles (rounded up to 64 points so small resizes keep them).
        let wanted = CGSize(width: max((body.width / 64).rounded(.up) * 64, 64), height: max((body.height / 64).rounded(.up) * 64, 64))
        if wanted != tileSize {
            tileSize = wanted
            for tile in tiles.values { tile.removeFromSuperlayer() }
            tiles = [:]
        }
        let key = ContentKey(tracks: model.tracks, assets: model.project.assets, tempoMap: model.project.tempoMap,
                             selection: model.selection, pixelsPerBeat: model.geometry.pixelsPerBeat, snap: model.snap,
                             tileSize: tileSize)
        let contentChanged = key != contentKey
        contentKey = key

        let g = model.geometry
        tileContainer.sublayerTransform = CATransform3DMakeTranslation(-g.scrollX, -g.scrollY, 0)
        let visible = CGRect(x: g.scrollX, y: g.scrollY, width: body.width, height: body.height)
        let columns = Int((visible.minX / tileSize.width).rounded(.down))...Int((max(visible.maxX - 1, visible.minX) / tileSize.width).rounded(.down))
        let rows = Int((visible.minY / tileSize.height).rounded(.down))...Int((max(visible.maxY - 1, visible.minY) / tileSize.height).rounded(.down))
        var keep: Set<TileKey> = []
        for column in columns {
            for row in rows {
                let tileKey = TileKey(column: column, row: row)
                keep.insert(tileKey)
                if let tile = tiles[tileKey] {
                    if contentChanged { tile.setNeedsDisplay() }
                    continue
                }
                let tile = TileLayer()
                tile.canvas = self
                tile.anchorPoint = .zero
                tile.contentsScale = window?.backingScaleFactor ?? 2
                tile.isOpaque = true
                tile.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
                tile.frame = CGRect(x: Double(column) * tileSize.width, y: Double(row) * tileSize.height,
                                    width: tileSize.width, height: tileSize.height)
                tileContainer.addSublayer(tile)
                tiles[tileKey] = tile
                tile.setNeedsDisplay()
            }
        }
        // Tiles that left the viewport are dropped, so memory stays at a few viewports' worth.
        for (tileKey, tile) in tiles where !keep.contains(tileKey) {
            tile.removeFromSuperlayer()
            tiles[tileKey] = nil
        }
    }

    fileprivate func drawTile(_ tile: TileLayer, in ctx: CGContext) {
        tilesDrawn += 1
        CanvasPainter.drawTile(ctx, contentRect: tile.frame, model: model)
    }

    private func updateRuler() {
        let g = model.geometry
        let key = [g.scrollX, g.pixelsPerBeat, g.size.width, Double(model.project.tempoMap.hashValue)]
        if key != rulerKey {
            rulerKey = key
            rulerLayer.setNeedsDisplay()
        }
    }

    fileprivate func drawRuler(in ctx: CGContext) {
        CanvasPainter.drawRuler(ctx, size: rulerLayer.bounds.size, model: model)
    }

    private func updateWaveforms(body: CGSize) {
        guard let renderer = WaveformRenderer.shared, body.width >= 1, body.height >= 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        waveformLayer.drawableSize = CGSize(width: body.width * scale, height: body.height * scale)
        renderer.draw(model.waveformBars(), in: waveformLayer, size: body, originY: TimelineGeometry.rulerHeight)
    }

    // MARK: Playhead (UI-014)

    @objc private func displayFrame(_ link: CADisplayLink) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        movePlayhead()
        CATransaction.commit()
    }

    /// Moves the playhead layer only: no tile, ruler or waveform redraw.
    func movePlayhead() {
        let x = model.geometry.x(model.playheadTick())
        playheadLayer.isHidden = x < -1 || x > bounds.width + 1
        playheadLayer.frame.origin = CGPoint(x: x.rounded() - 0.5, y: 0)
    }

    /// Brings the layers up to date and draws pending tiles and the ruler now (snapshots, tests).
    func displayNow() {
        refresh()
        for tile in tiles.values { tile.displayIfNeeded() }
        rulerLayer.displayIfNeeded()
    }

    var playheadX: Double { playheadLayer.frame.minX + 0.5 }
    var tileCount: Int { tiles.count }

    // MARK: Snapshot (UI-051, DW-154)

    /// The canvas as an image: the layers rendered in order, with the Metal waveform layer replaced
    /// by the same bars rendered offscreen (`cacheDisplay` and `render(in:)` leave it blank).
    func snapshotImage(scale: CGFloat) -> CGImage? {
        displayNow()
        let size = bounds.size
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // y down, like the view.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CanvasPainter.emptyColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        for sublayer in layer?.sublayers ?? [] where !sublayer.isHidden {
            ctx.saveGState()
            ctx.translateBy(x: sublayer.frame.minX, y: sublayer.frame.minY)
            if sublayer === waveformLayer {
                if let renderer = WaveformRenderer.shared,
                   let image = try? renderer.image(model.waveformBars(), size: sublayer.bounds.size,
                                                   originY: TimelineGeometry.rulerHeight, scale: scale) {
                    // The image's first row is its top: undo the y-down flip for the draw.
                    ctx.translateBy(x: 0, y: sublayer.bounds.height)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(image, in: CGRect(origin: .zero, size: sublayer.bounds.size))
                }
            } else if sublayer === tileContainer {
                ctx.clip(to: CGRect(origin: .zero, size: sublayer.bounds.size))
                let g = model.geometry
                ctx.translateBy(x: -g.scrollX, y: -g.scrollY)
                for tile in tiles.values {
                    ctx.saveGState()
                    ctx.translateBy(x: tile.frame.minX, y: tile.frame.minY)
                    CanvasPainter.drawTile(ctx, contentRect: tile.frame, model: model)
                    ctx.restoreGState()
                }
            } else if sublayer === rulerLayer {
                CanvasPainter.drawRuler(ctx, size: sublayer.bounds.size, model: model)
            } else if sublayer === overlayLayer {
                if let path = overlayLayer.path {
                    ctx.addPath(path)
                    ctx.setFillColor(overlayLayer.fillColor ?? .clear)
                    ctx.setStrokeColor(overlayLayer.strokeColor ?? .clear)
                    ctx.drawPath(using: .fillStroke)
                }
            } else {
                ctx.setFillColor(sublayer.backgroundColor ?? .clear)
                ctx.fill(CGRect(origin: .zero, size: sublayer.bounds.size))
            }
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    // MARK: Events

    private static func modifiers(_ event: NSEvent) -> CanvasModifiers {
        var modifiers: CanvasModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2, model.doubleClick(at: point(event)) { return }  // UI-020: open in the piano roll
        model.mouseDown(at: point(event), modifiers: Self.modifiers(event))
    }

    override func mouseDragged(with event: NSEvent) {
        model.mouseDragged(to: point(event), modifiers: Self.modifiers(event))
    }

    override func mouseUp(with event: NSEvent) {
        model.mouseUp(at: point(event), modifiers: Self.modifiers(event))
        updateCursor(at: point(event))
    }

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let dx = precise ? event.scrollingDeltaX : event.scrollingDeltaX * 10
        let dy = precise ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            // ⌘/⌥ + scroll zooms around the pointer.
            model.zoom(by: exp(dy * 0.01), anchorX: point(event).x)
        } else {
            model.scroll(dx: -dx, dy: -dy)
        }
    }

    override func magnify(with event: NSEvent) {
        model.zoom(by: 1 + event.magnification, anchorX: point(event).x)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = point(event)
        guard let hit = model.hitTest(p) else { return nil }
        if !model.selection.contains(hit.clipID) { model.selection = [hit.clipID] }
        let tick = model.isSnapping(Self.modifiers(event)) ? model.grid.snap(model.geometry.tick(atX: p.x), model.snap)
            : model.geometry.tick(atX: p.x)
        let menu = NSMenu()
        if case .midi = model.project.clip(hit.clipID) {
            menu.addItem(ClosureMenuItem("Open in Piano Roll") { [weak self] in self?.model.window?.pianoRoll.open(hit.clipID) })
        }
        menu.addItem(ClosureMenuItem("Split at Pointer") { [weak self] in self?.model.split(hit.clipID, at: tick) })
        menu.addItem(ClosureMenuItem("Duplicate", key: "d") { [weak self] in self?.model.duplicateSelection() })
        menu.addItem(ClosureMenuItem("Delete") { [weak self] in self?.model.deleteSelection() })
        return menu
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: point(event)) }

    private func updateCursor(at p: CGPoint) {
        switch model.hitTest(p)?.zone {
        case .trimStart, .trimEnd: NSCursor.resizeLeftRight.set()
        case .gain: NSCursor.resizeUpDown.set()
        case .fadeIn, .fadeOut: NSCursor.crosshair.set()
        default: NSCursor.arrow.set()
        }
    }
}

/// A tile of the canvas content; draws through its canvas.
private final class TileLayer: CALayer {
    weak var canvas: TimelineCanvasView?

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(in ctx: CGContext) {
        // Layers draw on the main thread here (no drawsAsynchronously).
        nonisolated(unsafe) let ctx = ctx, tile = self
        MainActor.assumeIsolated {
            flipIfNeeded(ctx, height: tile.bounds.height)
            tile.canvas?.drawTile(tile, in: ctx)
        }
    }
}

/// The ruler strip; draws through its canvas.
private final class RulerLayer: CALayer {
    weak var canvas: TimelineCanvasView?

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(in ctx: CGContext) {
        nonisolated(unsafe) let ctx = ctx, ruler = self
        MainActor.assumeIsolated {
            flipIfNeeded(ctx, height: ruler.bounds.height)
            ruler.canvas?.drawRuler(in: ctx)
        }
    }
}

/// Layer drawing contexts are y-up unless the layer's contents are flipped (a flipped view's
/// layer tree); the painter draws y-down, so flip when they aren't.
@MainActor
private func flipIfNeeded(_ ctx: CGContext, height: CGFloat) {
    if !(ctx.ctm.d < 0) {
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
    }
}

/// An `NSMenuItem` that runs a closure.
@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
