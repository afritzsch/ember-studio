import AppKit
import DAWModel
import SwiftUI

/// UI-001: one `NSWindow` per project, managed directly (no `DocumentGroup`, no
/// `NSDocumentController`). Hosts `ProjectWindowView` and reports focus and close to `AppModel`.
@MainActor
final class WindowManager: NSObject, WindowPresenting, NSWindowDelegate {
    weak var app: AppModel?
    /// Ask before closing a window with unsaved changes (false when a tool drives the app).
    var confirmsUnsavedChanges = true
    private var windows: [Int: NSWindow] = [:]

    init(app: AppModel) {
        self.app = app
    }

    func nsWindow(for model: ProjectWindowModel) -> NSWindow? { windows[model.id] }

    func show(_ model: ProjectWindowModel) {
        if let window = windows[model.id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProjectWindowView(model: model))
        window.identifier = NSUserInterfaceItemIdentifier("project.\(model.id)")
        window.delegate = self
        if let last = windows.values.first(where: \.isVisible) {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            window.center()
        }
        windows[model.id] = window
        setTitle(model)
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ model: ProjectWindowModel) {
        guard let window = windows.removeValue(forKey: model.id) else { return }
        window.delegate = nil
        window.close()
    }

    func setTitle(_ model: ProjectWindowModel) {
        guard let window = windows[model.id] else { return }
        let title = model.store.project.name
        if window.title != title { window.title = title }
        if window.isDocumentEdited != model.store.isDirty { window.isDocumentEdited = model.store.isDirty }
        if window.representedURL != model.store.folderURL { window.representedURL = model.store.folderURL }
    }

    func snapshot(_ model: ProjectWindowModel) throws -> (png: Data, width: Int, height: Int) {
        guard let window = windows[model.id] else { throw DAWError.notFound(kind: "window", id: UInt64(model.id)) }
        return try WindowSnapshotter.png(of: window)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        guard let id = id(of: notification.object) else { return }
        app?.becameMain(id)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = id(of: sender), let app, let model = app.window(id) else { return true }
        if confirmsUnsavedChanges && model.store.isDirty && !Self.confirmDiscard(model.store.project.name, in: sender) {
            return false
        }
        Task { await app.closeWindow(id) }
        return false
    }

    private func id(of object: Any?) -> Int? {
        guard let window = object as? NSWindow else { return nil }
        return windows.first { $0.value === window }?.key
    }

    /// "Close without saving?"; true to go ahead.
    static func confirmDiscard(_ name: String, in window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close \"\(name)\" without saving?"
        alert.informativeText = "Your changes since the last save will be lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
