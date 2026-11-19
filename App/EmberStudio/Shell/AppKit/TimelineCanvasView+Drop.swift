import AppKit
import DAWModel

/// UI-063 (T-124): files dropped on the arrange canvas, from the browser or from Finder (both
/// drag file URLs). The drop lands on the track under the pointer, or on a new track in the
/// empty area under the tracks, at the snapped tick (⌘ held: not snapped); the window's browser
/// loads them as one undo entry (`BrowserModel.load`).
extension TimelineCanvasView {
    // The canvas registers for file drags when it is put in the view tree (the main file's init
    // isn't this task's to edit; T-122 owns it in the same wave).
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil, !registeredDraggedTypes.contains(.fileURL) { registerForDraggedTypes([.fileURL]) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(sender)
        guard !urls.isEmpty, let window = model.window,
              let drop = BrowserModel.dropTarget(at: convert(sender.draggingLocation, from: nil), in: model,
                                                 snapping: !NSEvent.modifierFlags.contains(.command))
        else { return false }
        let browser = window.browser
        Task { @MainActor in _ = try? await browser.load(urls, onto: drop.target, at: drop.tick) }
        return true
    }

    private func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard model.window != nil, !Self.fileURLs(sender).isEmpty,
              BrowserModel.dropTarget(at: convert(sender.draggingLocation, from: nil), in: model, snapping: false) != nil
        else { return [] }
        return .copy
    }

    private static func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }
}
