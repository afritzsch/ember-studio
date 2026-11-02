import AppKit
import DAWModel

/// UI-051: a window as PNG through `cacheDisplay(in:to:)`: the view draws itself into a bitmap, so
/// no screen-recording permission is needed and a window behind others (or an app in the
/// background) snapshots the same. SwiftUI's `NSHostingView` renders correctly this way. Views
/// `cacheDisplay` can't capture (the arrange canvas's Metal waveform layer, UI-011) conform to
/// `SnapshotCompositing` and are drawn over the cached image from their own offscreen render
/// (DW-154).
@MainActor
enum WindowSnapshotter {
    /// The window's content (without the title bar) at its backing scale.
    static func png(of window: NSWindow) throws(DAWError) -> (png: Data, width: Int, height: Int) {
        guard let view = window.contentView else { throw .invalidArgument("the window has no content") }
        return try png(of: view)
    }

    static func png(of view: NSView) throws(DAWError) -> (png: Data, width: Int, height: Int) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw .invalidArgument("the window has no size to snapshot")
        }
        view.cacheDisplay(in: bounds, to: rep)
        composite(over: rep, of: view)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw .engine(code: .internal, detail: "PNG encoding failed")
        }
        return (png, rep.pixelsWide, rep.pixelsHigh)
    }

    /// DW-154: draws every visible `SnapshotCompositing` view under `root` at its place in `rep`.
    private static func composite(over rep: NSBitmapImageRep, of root: NSView) {
        let views = descendants(of: root).compactMap { $0 as? any SnapshotCompositing }
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width >= 1 && $0.bounds.height >= 1 }
        guard !views.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let scale = CGFloat(rep.pixelsWide) / max(root.bounds.width, 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        for view in views {
            guard let image = view.snapshotImage(scale: scale) else { continue }
            // The rep's coordinates are the root's bounds, y up.
            var rect = view.convert(view.bounds, to: root)
            if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
            let visible = rect.intersection(root.bounds)
            guard !visible.isNull else { continue }
            context.cgContext.saveGState()
            context.cgContext.clip(to: visible)
            context.cgContext.draw(image, in: rect)
            context.cgContext.restoreGState()
        }
        context.flushGraphics()
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
