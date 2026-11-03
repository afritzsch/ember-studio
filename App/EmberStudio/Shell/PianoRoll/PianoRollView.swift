import AppKit
import DAWModel
import Observation
import QuartzCore

/// UI-020: the piano roll canvas, a layer-backed `NSView` (`wantsUpdateLayer`) over
/// `PianoRollModel`, built like the arrange canvas (UI-010):
///   - the note grid is drawn in viewport-sized tiles (CALayers in content coordinates under a
///     container whose sublayer transform is the scroll offset), so scrolling moves layers and draws
///     only tiles that come into view, and each tile draws only the notes inside it;
///   - the keyboard (left), ruler (top) and velocity lane (bottom) are layers of their own, redrawn
///     only when what they show changes;
///   - the playhead is its own layer, moved per display frame (UI-014); the marquee an overlay.
/// Mouse, scroll and key events go to the model; the view keeps no edit state.
final class PianoRollView: NSView, SnapshotCompositing {
    let model: PianoRollModel

    private struct TileKey: Hashable {
        var column: Int
        var row: Int
    }

    /// What tiles show: when it changes, the visible tiles redraw. Scrolling isn't part of it.
    private struct ContentKey: Equatable {
        var clip: MidiClip?
        var tempoMap: TempoMap
        var selection: Set<ModelID>
        var pixelsPerBeat: Double
        var keyHeight: Double
        var snap: SnapMode
        var tileSize: CGSize
    }

    private let tileContainer = CALayer()
    private let keyboardLayer = DrawingLayer()
    private let rulerLayer = DrawingLayer()
    private let laneLayer = DrawingLayer()
    private let placeholderLayer = DrawingLayer()
    private let overlayLayer = CAShapeLayer()
    private let playheadLayer = CALayer()
    private var tiles: [TileKey: DrawingLayer] = [:]
    private var tileSize = CGSize(width: 512, height: 512)
    private var contentKey: ContentKey?
    private var sideKeys: [String: AnyHashable] = [:]
    private var displayLink: CADisplayLink?

    /// Tiles drawn since the view was made (`ui.state`, tests: scrolling inside drawn tiles draws none).
    private(set) var tilesDrawn = 0

    init(model: PianoRollModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let root = layer!
        root.backgroundColor = CanvasPainter.emptyColor.cgColor
        for sublayer in [tileContainer, keyboardLayer, rulerLayer, laneLayer, overlayLayer, playheadLayer, placeholderLayer] as [CALayer] {
            sublayer.anchorPoint = .zero
            sublayer.actions = Self.noActions
            root.addSublayer(sublayer)
        }
        tileContainer.masksToBounds = true
        keyboardLayer.paint = { [unowned self] ctx in PianoRollPainter.drawKeyboard(ctx, geometry: viewGeometry, model: model) }
        rulerLayer.paint = { [unowned self] ctx in PianoRollPainter.drawRuler(ctx, geometry: viewGeometry, model: model) }
        laneLayer.paint = { [unowned self] ctx in PianoRollPainter.drawLane(ctx, geometry: viewGeometry, model: model) }
        placeholderLayer.paint = { [unowned self] ctx in PianoRollPainter.drawPlaceholder(ctx, size: placeholderLayer.bounds.size) }
        for drawing in [keyboardLayer, rulerLayer, laneLayer, placeholderLayer] { drawing.needsDisplayOnBoundsChange = true }
        overlayLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        overlayLayer.strokeColor = NSColor.controlAccentColor.cgColor
        overlayLayer.lineWidth = 1
        playheadLayer.backgroundColor = NSColor.systemRed.cgColor
        playheadLayer.zPosition = 10
        observeModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "sublayerTransform": NSNull(), "contents": NSNull(), "path": NSNull(),
        "hidden": NSNull(), "frame": NSNull(),
    ]

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The model's geometry at the view's size (the side layers cover the whole view).
    private var viewGeometry: PianoRollGeometry {
        var g = model.geometry
        g.size = bounds.size
        return g
    }

    // MARK: Observation

    private func observeModel() {
        withObservationTracking {
            _ = model.clip
            _ = model.project.tempoMap
            _ = model.selection
            _ = model.geometry
            _ = model.snap
            _ = model.marquee
            _ = model.sounding
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
        for layer in [tileContainer, keyboardLayer, rulerLayer, laneLayer, overlayLayer, playheadLayer, placeholderLayer] as [CALayer] {
            layer.contentsScale = scale
        }
        for tile in tiles.values { tile.contentsScale = scale }
        contentKey = nil
        sideKeys = [:]
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else {
            // UI-021: the pane went away; nothing may keep sounding.
            model.finishDrag()
            return
        }
        viewDidChangeBackingProperties()
        let link = displayLink(target: self, selector: #selector(displayFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func updateLayer() { refresh() }

    /// Brings every layer in line with the model. Called from `updateLayer` (and by snapshots).
    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let g = model.geometry
        placeholderLayer.frame = bounds
        placeholderLayer.isHidden = model.isOpen
        if !placeholderLayer.isHidden { placeholderLayer.setNeedsDisplay() }
        tileContainer.frame = g.gridRect
        keyboardLayer.frame = bounds
        rulerLayer.frame = bounds
        laneLayer.frame = bounds
        overlayLayer.frame = bounds
        playheadLayer.frame.size = CGSize(width: 1, height: max(g.gridRect.height + PianoRollGeometry.laneHeight, 0))
        updateTiles(grid: g.gridRect.size)
        redrawIfChanged(keyboardLayer, "keys", [g.scrollY, g.keyHeight, g.size.height, model.sounding] as [AnyHashable])
        redrawIfChanged(rulerLayer, "ruler", [g.scrollX, g.pixelsPerBeat, g.size.width, model.project.tempoMap] as [AnyHashable])
        redrawIfChanged(laneLayer, "lane", [model.clip, model.selection, g.scrollX, g.pixelsPerBeat, g.size.width, g.size.height]
                            as [AnyHashable])
        overlayLayer.path = model.marquee.map { CGPath(rect: $0.insetBy(dx: 0.5, dy: 0.5), transform: nil) }
        movePlayhead()
    }

    private func redrawIfChanged(_ layer: CALayer, _ name: String, _ key: some Hashable) {
        let key = AnyHashable(key)
        if sideKeys[name] != key {
            sideKeys[name] = key
            layer.setNeedsDisplay()
        }
    }

    private func updateTiles(grid: CGSize) {
        let wanted = CGSize(width: max((grid.width / 64).rounded(.up) * 64, 64), height: max((grid.height / 64).rounded(.up) * 64, 64))
        if wanted != tileSize {
            tileSize = wanted
            for tile in tiles.values { tile.removeFromSuperlayer() }
            tiles = [:]
        }
        let key = ContentKey(clip: model.clip, tempoMap: model.project.tempoMap, selection: model.selection,
                             pixelsPerBeat: model.pixelsPerBeat, keyHeight: model.keyHeight, snap: model.snap, tileSize: tileSize)
        let contentChanged = key != contentKey
        contentKey = key
        let g = model.geometry
        tileContainer.sublayerTransform = CATransform3DMakeTranslation(-g.scrollX, -g.scrollY, 0)
        guard grid.width >= 1, grid.height >= 1, model.isOpen else {
            for tile in tiles.values { tile.removeFromSuperlayer() }
            tiles = [:]
            return
        }
        let visible = CGRect(x: g.scrollX, y: g.scrollY, width: grid.width, height: grid.height)
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
                let tile = DrawingLayer()
                tile.anchorPoint = .zero
                tile.contentsScale = window?.backingScaleFactor ?? 2
                tile.isOpaque = true
                tile.actions = Self.noActions
                tile.frame = CGRect(x: Double(column) * tileSize.width, y: Double(row) * tileSize.height,
                                    width: tileSize.width, height: tileSize.height)
                tile.paint = { [unowned self, unowned tile] ctx in drawTile(tile.frame, in: ctx) }
                tileContainer.addSublayer(tile)
                tiles[tileKey] = tile
                tile.setNeedsDisplay()
            }
        }
        for (tileKey, tile) in tiles where !keep.contains(tileKey) {
            tile.removeFromSuperlayer()
            tiles[tileKey] = nil
        }
    }

    /// One tile: the grid content in `contentRect` (content coordinates), its top-left at the origin.
    private func drawTile(_ contentRect: CGRect, in ctx: CGContext) {
        tilesDrawn += 1
        var g = model.geometry
        g.scrollX = contentRect.minX
        g.scrollY = contentRect.minY
        ctx.translateBy(x: -PianoRollGeometry.keyboardWidth, y: -PianoRollGeometry.rulerHeight)
        PianoRollPainter.drawGrid(ctx, geometry: g, clip: CGRect(x: PianoRollGeometry.keyboardWidth, y: PianoRollGeometry.rulerHeight,
                                                                width: contentRect.width, height: contentRect.height), model: model)
    }

    // MARK: Playhead (UI-014)

    @objc private func displayFrame(_ link: CADisplayLink) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        movePlayhead()
        CATransaction.commit()
    }

    func movePlayhead() {
        let g = model.geometry
        let x = g.x(model.playheadTick().raw)
        playheadLayer.isHidden = !model.isOpen || x < g.gridRect.minX || x > g.gridRect.maxX
        playheadLayer.frame.origin = CGPoint(x: x.rounded() - 0.5, y: PianoRollGeometry.rulerHeight)
    }

    /// Brings the layers up to date and draws pending tiles now (snapshots, tests).
    func displayNow() {
        refresh()
        for tile in tiles.values { tile.displayIfNeeded() }
        for layer in [keyboardLayer, rulerLayer, laneLayer, placeholderLayer] { layer.displayIfNeeded() }
    }

    var tileCount: Int { tiles.count }

    // MARK: Snapshot (UI-051)

    /// The piano roll as an image, painted directly (custom-drawn layers don't show in `cacheDisplay`).
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
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        if !model.isOpen {
            PianoRollPainter.drawPlaceholder(ctx, size: size)
            return ctx.makeImage()
        }
        var g = model.geometry
        g.size = size
        ctx.setFillColor(CanvasPainter.emptyColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        PianoRollPainter.drawGrid(ctx, geometry: g, clip: g.gridRect, model: model)
        PianoRollPainter.drawKeyboard(ctx, geometry: g, model: model)
        PianoRollPainter.drawRuler(ctx, geometry: g, model: model)
        PianoRollPainter.drawLane(ctx, geometry: g, model: model)
        if let path = overlayLayer.path {
            ctx.addPath(path)
            ctx.setFillColor(overlayLayer.fillColor ?? .clear)
            ctx.setStrokeColor(overlayLayer.strokeColor ?? .clear)
            ctx.drawPath(using: .fillStroke)
        }
        if !playheadLayer.isHidden {
            ctx.setFillColor(NSColor.systemRed.cgColor)
            ctx.fill(playheadLayer.frame)
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

    override func becomeFirstResponder() -> Bool {
        model.hasKeyFocus = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        model.hasKeyFocus = false
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        model.mouseDown(at: point(event), modifiers: Self.modifiers(event), clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) { model.mouseDragged(to: point(event), modifiers: Self.modifiers(event)) }

    override func mouseUp(with event: NSEvent) { model.mouseUp(at: point(event), modifiers: Self.modifiers(event)) }

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let dx = precise ? event.scrollingDeltaX : event.scrollingDeltaX * 10
        let dy = precise ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        if event.modifierFlags.contains(.command) {
            model.zoom(by: exp(dy * 0.01), anchorX: point(event).x)  // ⌘ + scroll: time zoom
        } else if event.modifierFlags.contains(.option) {
            model.zoomKeys(by: exp(dy * 0.01))  // ⌥ + scroll: key height
        } else {
            model.scroll(dx: -dx, dy: -dy)
        }
    }

    override func magnify(with event: NSEvent) { model.zoom(by: 1 + event.magnification, anchorX: point(event).x) }

    /// ↑/↓ transpose (⇧: an octave). ⌫, ⌘A and Q come through the window's key table (`KeyMonitor`).
    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.specialKey {
        case .upArrow?: if model.handleArrow(up: true, shift: shift) { return }
        case .downArrow?: if model.handleArrow(up: false, shift: shift) { return }
        default: break
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard model.isOpen else { return nil }
        let menu = NSMenu()
        menu.addItem(PianoRollMenuItem("Quantize") { [weak self] in self?.model.quantize() })
        menu.addItem(PianoRollMenuItem("Transpose Up") { [weak self] in self?.model.transpose(by: 1) })
        menu.addItem(PianoRollMenuItem("Transpose Down") { [weak self] in self?.model.transpose(by: -1) })
        menu.addItem(PianoRollMenuItem("Delete") { [weak self] in self?.model.deleteSelection() })
        return menu
    }
}

/// A layer that draws through a closure, in a y-down context, on the main thread.
private final class DrawingLayer: CALayer {
    var paint: (@MainActor (CGContext) -> Void)?

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(in ctx: CGContext) {
        nonisolated(unsafe) let ctx = ctx, layer = self
        MainActor.assumeIsolated {
            if !(ctx.ctm.d < 0) {
                ctx.translateBy(x: 0, y: layer.bounds.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            layer.paint?(ctx)
        }
    }
}

/// An `NSMenuItem` that runs a closure.
@MainActor
private final class PianoRollMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
