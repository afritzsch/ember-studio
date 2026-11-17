import AppKit
import DAWModel

/// PLUG-017 (T-063): the floating `NSPanel`s plugin editors live in, one per device slot. The panel's
/// content view is the engine's container view itself, so:
///   - a plugin asking for a new size (VST3 `IPlugFrame::resizeView`, an AU view controller arriving)
///     changes the container's frame, which the panel follows (`NSView.frameDidChangeNotification`);
///   - a user resizing a resizable editor's panel resizes the container, which the engine passes on
///     to the plugin (VST3 `checkSizeConstraint`/`onSize`).
/// Closing a panel (its close button) tells the model through `onUserClose`.
@MainActor
final class PluginEditorPanels: NSObject, NSWindowDelegate {
    var onUserClose: (@MainActor (NodeIDValue) -> Void)?

    private final class Entry {
        let panel: NSPanel
        let view: NSView
        var observer: NSObjectProtocol?
        init(panel: NSPanel, view: NSView) {
            self.panel = panel
            self.view = view
        }
    }

    private var entries: [NodeIDValue: Entry] = [:]
    private var closingProgrammatically = false

    /// The panel showing `slot`'s editor (snapshots, tests).
    func panel(for slot: NodeIDValue) -> NSPanel? { entries[slot]?.panel }

    func show(_ view: NSView, slot: NodeIDValue, title: String, resizable: Bool) {
        hide(slot)
        var style: NSWindow.StyleMask = [.titled, .closable, .utilityWindow]
        if resizable { style.insert(.resizable) }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: style,
                            backing: .buffered, defer: false)
        panel.title = title
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("pluginEditor.\(slot)")
        view.postsFrameChangedNotifications = true
        panel.contentView = view
        panel.setContentSize(view.frame.size)
        let entry = Entry(panel: panel, view: view)
        entry.observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak panel, weak view] _ in
            MainActor.assumeIsolated {
                guard let panel, let view, panel.contentLayoutRect.size != view.frame.size else { return }
                panel.setContentSize(view.frame.size)
            }
        }
        entries[slot] = entry
        if NSApp?.isRunning == true {
            panel.center()
            panel.orderFront(nil)
        }
    }

    func hide(_ slot: NodeIDValue) {
        guard let entry = entries.removeValue(forKey: slot) else { return }
        if let observer = entry.observer { NotificationCenter.default.removeObserver(observer) }
        closingProgrammatically = true
        entry.panel.delegate = nil
        entry.panel.close()
        // The engine owns the view; the panel lets go of it before the engine releases it.
        entry.panel.contentView = NSView()
        closingProgrammatically = false
    }

    func bringForward(_ slot: NodeIDValue) {
        guard let panel = entries[slot]?.panel, NSApp?.isRunning == true else { return }
        panel.orderFront(nil)
    }

    func setResizable(_ resizable: Bool, slot: NodeIDValue) {
        guard let panel = entries[slot]?.panel else { return }
        if resizable { panel.styleMask.insert(.resizable) } else { panel.styleMask.remove(.resizable) }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !closingProgrammatically, let panel = notification.object as? NSPanel,
              let slot = entries.first(where: { $0.value.panel === panel })?.key,
              let entry = entries.removeValue(forKey: slot)
        else { return }
        // Already closing: only let go of the engine's view, then tell the model.
        if let observer = entry.observer { NotificationCenter.default.removeObserver(observer) }
        panel.delegate = nil
        panel.contentView = NSView()
        onUserClose?(slot)
    }
}
