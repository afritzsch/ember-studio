import AppKit
import DAWModel

/// UI-051: a window as PNG through `cacheDisplay(in:to:)`: the view draws itself into a bitmap, so
/// no screen-recording permission is needed and a window behind others (or an app in the
/// background) snapshots the same. SwiftUI's `NSHostingView` renders correctly this way. The arrange
/// canvas's Metal layer (UI-011, T-033) will need its offscreen path here.
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
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw .engine(code: .internal, detail: "PNG encoding failed")
        }
        return (png, rep.pixelsWide, rep.pixelsHigh)
    }
}
