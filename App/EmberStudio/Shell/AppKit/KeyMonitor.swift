import AppKit

/// UI-002: routes key presses in a project window to its view model's key table
/// (`ProjectWindowModel.handleKey`), before menus and views see them. That is the one place
/// shortcuts are dispatched, so Space, R, L and ⌫ work wherever focus is in the window (they have
/// no menu key equivalents). Typing into a text field is left alone.
@MainActor
final class KeyMonitor {
    private var token: Any?

    /// `model(for:)` finds the project window model an event's window shows (nil: not a project window).
    init(model: @escaping @MainActor (NSWindow) -> ProjectWindowModel?) {
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let window = event.window, let target = model(window), !Self.isEditingText(in: window),
                      let chord = KeyChord(event: event)
                else { return false }
                return target.handleKey(chord, isRepeat: event.isARepeat)
            }
            return handled ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    /// A text field (its field editor) or text view has focus.
    static func isEditingText(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSTextView else { return false }
        return responder.isEditable
    }
}

extension KeyChord {
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        guard let characters = event.charactersIgnoringModifiers else { return nil }
        self.init(characters: characters, modifiers: modifiers)
    }

    /// The menu item key equivalent for a ⌘ chord (nil for plain keys: those go through `KeyMonitor`
    /// only, so a focused text field still gets them).
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard modifiers.contains(.command), case .character(let c) = key else { return nil }
        var flags: NSEvent.ModifierFlags = [.command]
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return (String(c), flags)
    }
}
