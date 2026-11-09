import AppKit

/// UI-030: a fader or a pan/level slider. AppKit rather than a SwiftUI `Slider`, for three reasons: a
/// drag must be one undo step, a double-click resets it (`clickCount`), and its controls have to be
/// reachable through `ui.perform` (UI-052), which `Slider` isn't. The model owns the value: the
/// view reports `position` (0…1) and shows what it is given.
final class MixerSliderView: NSView {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    /// 0…1, bottom or left to top or right. Where the groove is marked (0 dB, centre); nil for none.
    var mark: Double?
    var position: Double = 0 {
        didSet { if position != oldValue { needsDisplay = true } }
    }

    /// The drag's first movement, each movement, its end; and a double-click. No movement, no gesture.
    var onBegin: (() -> Void)?
    var onChange: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?

    private var dragOrigin: CGPoint?
    private var startPosition = 0.0
    private var dragging = false
    private static let thumbLength: CGFloat = 8

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 18))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func isAccessibilityElement() -> Bool { true }

    // MARK: Drawing

    private var travel: CGFloat {
        max((axis == .vertical ? bounds.height : bounds.width) - Self.thumbLength, 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let groove = NSColor.separatorColor
        let along = CGFloat(position) * travel + Self.thumbLength / 2
        if axis == .vertical {
            groove.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 2, y: 0, width: 4, height: bounds.height), xRadius: 2, yRadius: 2).fill()
            if let mark {
                NSColor.secondaryLabelColor.setFill()
                NSRect(x: bounds.midX - 7, y: bounds.height - (CGFloat(mark) * travel + Self.thumbLength / 2), width: 14, height: 1).fill()
            }
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 9, y: bounds.height - along - Self.thumbLength / 2,
                                             width: 18, height: Self.thumbLength), xRadius: 2, yRadius: 2).fill()
        } else {
            groove.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 3), xRadius: 1, yRadius: 1).fill()
            if let mark {
                NSColor.secondaryLabelColor.setFill()
                NSRect(x: CGFloat(mark) * travel + Self.thumbLength / 2, y: bounds.midY - 4, width: 1, height: 8).fill()
            }
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: along - Self.thumbLength / 2, y: bounds.midY - 5,
                                             width: Self.thumbLength, height: 10), xRadius: 2, yRadius: 2).fill()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            dragOrigin = nil
            onReset?()
            return
        }
        dragOrigin = convert(event.locationInWindow, from: nil)
        startPosition = position
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        if !dragging {
            dragging = true
            onBegin?()
        }
        // Relative to the grab, so a click on the thumb doesn't jump it.
        let at = convert(event.locationInWindow, from: nil)
        let delta = axis == .vertical ? dragOrigin.y - at.y : at.x - dragOrigin.x
        let value = min(max(startPosition + Double(delta / travel), 0), 1)
        onChange?(value)
    }

    override func mouseUp(with event: NSEvent) {
        finishDrag()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { finishDrag() }
    }

    private func finishDrag() {
        dragOrigin = nil
        if dragging {
            dragging = false
            onEnd?()
        }
    }
}
