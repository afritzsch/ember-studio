import Foundation

/// UI-002: a key press as the window's key table sees it: one key plus the modifiers that matter.
/// AppKit turns an `NSEvent` into one (`KeyMonitor`); tests build them directly, so the bindings are
/// tested through the view model without a window.
struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    enum Key: Hashable, Sendable {
        /// A printable character, lowercased for letters.
        case character(Character)
        case space
        /// ⌫ (backspace) and ⌦ (forward delete) both delete.
        case delete
    }

    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let shift = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let control = Modifiers(rawValue: 8)
    }

    let key: Key
    let modifiers: Modifiers

    init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// `"t"` with `[.command, .shift]` is ⇧⌘T.
    init(_ character: Character, _ modifiers: Modifiers = []) {
        self.init(.character(Character(character.lowercased())), modifiers)
    }

    /// Normalizes what a key event reports (`charactersIgnoringModifiers`, which keeps ⇧'s effect):
    /// letters are lowercased and keep ⇧ as a modifier; for other characters ⇧ is already in the
    /// character (⇧= is "+"), so it is dropped. That makes ⌘+ the same chord on keyboards where +
    /// needs ⇧ and on the keypad, where it doesn't. Nil for keys no binding can use (arrows, F-keys).
    init?(characters: String, modifiers: Modifiers) {
        guard characters.count == 1, let c = characters.first else { return nil }
        let mods = modifiers.intersection([.command, .shift, .option, .control])
        switch c {
        case " ":
            self.init(.space, mods)
        case "\u{7F}", "\u{8}", "\u{F728}":  // ⌫ (DEL / BS), ⌦ (NSDeleteFunctionKey)
            self.init(.delete, mods)
        case _ where c.isLetter:
            self.init(.character(Character(c.lowercased())), mods)
        case _ where c.unicodeScalars.allSatisfy({ (0xF700...0xF8FF).contains($0.value) }):
            return nil  // AppKit function keys (arrows, F1…, Home, …)
        default:
            self.init(.character(c), mods.subtracting(.shift))
        }
    }

    /// What menus and `ui.state` show: "Space", "⌫", "⇧⌘T", "⌘+".
    var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .space: text += "Space"
        case .delete: text += "⌫"
        case .character(let c): text += c.uppercased()
        }
        return text
    }
}

/// UI-002: one shortcut: a chord that runs a window control (UI-052), the same descriptor a click
/// or `ui.perform` runs, so a shortcut does exactly what its button does, enablement included.
struct KeyBinding: Hashable, Sendable {
    let chord: KeyChord
    let controlID: String
    /// Whether a held key repeats it (zoom does; play/stop, record and loop toggle once).
    var repeats = false
}

enum KeyBindings {
    /// UI-002's shortcuts (and UI-013's ⌘D). Zoom has two chords each: ⌘= / ⌘+ in, ⌘- / ⌘− out.
    static let all: [KeyBinding] = [
        KeyBinding(chord: KeyChord(.space), controlID: "transport.playStop"),
        KeyBinding(chord: KeyChord("r"), controlID: "transport.record"),
        KeyBinding(chord: KeyChord("l"), controlID: "transport.loop"),
        KeyBinding(chord: KeyChord("z", .command), controlID: "edit.undo", repeats: true),
        KeyBinding(chord: KeyChord("z", [.command, .shift]), controlID: "edit.redo", repeats: true),
        KeyBinding(chord: KeyChord("t", .command), controlID: "track.add.audio"),
        KeyBinding(chord: KeyChord("t", [.command, .shift]), controlID: "track.add.midi"),
        // DW-165: ⌘E splits the selected clips at the playhead, ⌫ deletes them (ArrangeModel).
        KeyBinding(chord: KeyChord("e", .command), controlID: "edit.split"),
        KeyBinding(chord: KeyChord(.delete), controlID: "edit.delete"),
        KeyBinding(chord: KeyChord("d", .command), controlID: "edit.duplicate"),
        KeyBinding(chord: KeyChord("+", .command), controlID: "zoom.in", repeats: true),
        KeyBinding(chord: KeyChord("=", .command), controlID: "zoom.in", repeats: true),
        KeyBinding(chord: KeyChord("-", .command), controlID: "zoom.out", repeats: true),
        KeyBinding(chord: KeyChord("−", .command), controlID: "zoom.out", repeats: true),
        // UI-020 (T-043): P opens the selected MIDI clip in the piano roll.
        KeyBinding(chord: KeyChord("p"), controlID: "pianoRoll.open"),
        // UI-040 (T-055): ⌘, opens (and closes) the audio settings, macOS's Settings shortcut.
        KeyBinding(chord: KeyChord(",", .command), controlID: "prefs.audio"),
    ]

    /// UI-020 (T-043): while the piano roll has focus these come first (the arrows transpose in
    /// the view itself: KeyChord leaves function keys out).
    static let pianoRoll: [KeyBinding] = [
        KeyBinding(chord: KeyChord(.delete), controlID: "pianoRoll.delete"),
        KeyBinding(chord: KeyChord("a", .command), controlID: "pianoRoll.selectAll"),
        KeyBinding(chord: KeyChord("q"), controlID: "pianoRoll.quantize"),
    ]

    private static let pianoRollByChord = Dictionary(pianoRoll.map { ($0.chord, $0) }, uniquingKeysWith: { first, _ in first })

    static func pianoRollBinding(for chord: KeyChord) -> KeyBinding? { pianoRollByChord[chord] }

    private static let byChord = Dictionary(all.map { ($0.chord, $0) }, uniquingKeysWith: { first, _ in first })

    static func binding(for chord: KeyChord) -> KeyBinding? { byChord[chord] }

    /// The first chord bound to `controlID` (for menus).
    static func chord(for controlID: String) -> KeyChord? { all.first { $0.controlID == controlID }?.chord }
}
