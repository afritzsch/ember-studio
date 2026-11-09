import AppKit
import DAWModel
import QuartzCore

/// UI-031: one channel's meter: a layer-backed view updated per display frame by `MeterBank` (never
/// through SwiftUI). Peak bar, a narrower RMS bar inside it, the peak-hold line and a clip cap at the
/// top. A click clears the clip indicator.
final class ChannelMeterView: NSView {
    private(set) var channel: NodeIDValue
    private weak var bank: MeterBank?

    private let trackLayer = CALayer()
    private let peakLayer = CALayer()
    private let hotLayer = CALayer()
    private let rmsLayer = CALayer()
    private let holdLayer = CALayer()
    private let clipLayer = CALayer()
    private var shown: MeterBallistics?
    private static let clipHeight: CGFloat = 5
    /// Peak bar red above this, on the meter's scale.
    private static let hotDB = 0.0

    init(channel: NodeIDValue, bank: MeterBank) {
        self.channel = channel
        self.bank = bank
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 100))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let root = layer!
        let colors: [(CALayer, NSColor)] = [
            (trackLayer, .separatorColor), (peakLayer, .systemGreen), (hotLayer, .systemRed),
            (rmsLayer, NSColor.systemGreen.blended(withFraction: 0.45, of: .black) ?? .systemGreen),
            (holdLayer, .labelColor), (clipLayer, .tertiaryLabelColor),
        ]
        for (sublayer, color) in colors {
            sublayer.backgroundColor = color.cgColor
            sublayer.anchorPoint = .zero
            root.addSublayer(sublayer)
        }
        // Frames are set per display frame: no implicit animations.
        let none: [String: any CAAction] = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
        root.actions = none
        for sublayer in root.sublayers ?? [] { sublayer.actions = none }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// UI-031: only a meter someone can see reads the engine and draws.
    /// (`visibleRect` isn't cut to the view's own bounds when `clipsToBounds` is off, as it is by default.)
    var isOnScreen: Bool { window != nil && !isHiddenOrHasHiddenAncestor && !visibleRect.intersection(bounds).isEmpty }

    func update(channel: NodeIDValue) {
        guard channel != self.channel else { return }
        self.channel = channel
        shown = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { bank?.register(self) } else { bank?.unregister(self) }
    }

    override func layout() {
        super.layout()
        trackLayer.frame = bounds
        shown = nil
        present(bank?.state(of: channel) ?? MeterBallistics())
    }

    override func mouseDown(with event: NSEvent) {
        bank?.clearClip(of: channel)
    }

    /// Draws one frame. Unchanged readings touch no layer, so a silent mixer does no work.
    func present(_ state: MeterBallistics) {
        guard state != shown else { return }
        shown = state
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let h = bounds.height - Self.clipHeight - 1
        guard h > 0 else { return }
        let w = bounds.width
        let y = { (db: Double) in Self.clipHeight + 1 + h * CGFloat(1 - MeterBallistics.position(db: db)) }
        let top = y(max(state.peakDB, MeterBallistics.floorDB))
        let hot = y(Self.hotDB)
        let bottom = Self.clipHeight + 1 + h
        // The bar: green up to 0 dB, red above it. A bar at the floor draws nothing.
        peakLayer.frame = CGRect(x: 0, y: max(top, hot), width: w, height: max(bottom - max(top, hot), 0))
        hotLayer.frame = CGRect(x: 0, y: top, width: w, height: max(hot - top, 0))
        let rmsTop = y(state.rmsDB)
        rmsLayer.frame = CGRect(x: w * 0.3, y: rmsTop, width: w * 0.4, height: max(bottom - rmsTop, 0))
        let hold = y(state.holdDB)
        holdLayer.isHidden = state.holdDB <= MeterBallistics.floorDB
        holdLayer.frame = CGRect(x: 0, y: hold, width: w, height: 1)
        clipLayer.frame = CGRect(x: 0, y: 0, width: w, height: Self.clipHeight)
        clipLayer.backgroundColor = (state.clipped ? NSColor.systemRed : .tertiaryLabelColor).cgColor
    }
}
