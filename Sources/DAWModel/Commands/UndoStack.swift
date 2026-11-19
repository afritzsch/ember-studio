/// MODEL-002/003: undo and redo history, and gesture coalescing. A value that works on a project
/// passed in, so `ProjectStore` owns both and tests can use it directly.
///
/// Each entry holds the command that reverses it: an undo entry holds the inverse, a redo entry
/// holds what applying that inverse returned. Every apply is atomic (see `Command`), so a command
/// that throws leaves the project and the history as they were.
public struct UndoStack: Sendable {
    /// MODEL-002: "unlimited" depth, capped. The oldest entries are dropped beyond it.
    public static let defaultLimit = 1000

    public struct Entry: Sendable {
        public let label: String
        let command: any Command
        /// Identifies the edit across undo/redo, so the store can tell when it is back at the
        /// saved state.
        let serial: UInt64
    }

    private struct Gesture: Sendable {
        var owner: GestureOwner
        var label: String
        var depth: Int
        /// Inverses of the commands applied so far, in apply order.
        var inverses: [any Command] = []
    }

    public let limit: Int
    public private(set) var undoEntries: [Entry] = []
    public private(set) var redoEntries: [Entry] = []
    /// DW-336: the open gestures, at most one per owner, in the order they began.
    private var gestures: [Gesture] = []
    private var nextSerial: UInt64 = 1
    /// DW-337: the marker of the state at the bottom of the undo stack (with every entry undone).
    /// 0 for a new or opened project; once the cap drops entries, the serial of the newest one
    /// dropped, so undoing everything left isn't taken for the original state.
    private var baseSerial: UInt64 = 0

    public init(limit: Int = defaultLimit) {
        precondition(limit > 0)
        self.limit = limit
    }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoLabel: String? { undoEntries.last?.label }
    public var redoLabel: String? { redoEntries.last?.label }
    /// Whether any owner has a gesture open.
    public var isGestureActive: Bool { !gestures.isEmpty }
    /// Whether any open gesture has applied anything yet.
    public var gestureHasChanges: Bool { gestures.contains { !$0.inverses.isEmpty } }
    /// DW-336: whether `owner` has a gesture open.
    public func hasOpenGesture(owner: GestureOwner) -> Bool { gestures.contains { $0.owner == owner } }
    /// The owners with an open gesture, in the order their gestures began.
    public var openGestureOwners: [GestureOwner] { gestures.map(\.owner) }

    /// Names the state the project is in: the serial of the newest undo entry, or the bottom's
    /// (`baseSerial`) with none. Equal markers mean equal states (as long as no gesture is open).
    public var stateMarker: UInt64 { undoEntries.last?.serial ?? baseSerial }

    /// Applies `command`. Outside a gesture of `owner` it is pushed as one undo entry; inside one it
    /// is recorded for that gesture's entry (MODEL-003). A gesture of another owner is left open and
    /// doesn't take the command (DW-336). Either way the redo stack is cleared.
    /// A `HistoryExemptCommand` is applied (and validated) but leaves the history as it is (T-026);
    /// one that changes the session rate rescales the history to it (DW-334).
    public mutating func perform(
        _ command: any Command, on project: inout Project, as owner: GestureOwner = .ui
    ) throws(DAWError) {
        let rate = project.sessionSampleRate
        let inverse = try Self.apply(command, to: &project)
        if project.sessionSampleRate != rate { rescaleHistory(from: rate, to: project.sessionSampleRate) }
        guard !command.isHistoryExempt else { return }
        redoEntries.removeAll()
        if let i = gestures.firstIndex(where: { $0.owner == owner }) {
            gestures[i].inverses.append(inverse)
        } else {
            push(label: command.label, inverse: inverse)
        }
    }

    /// Undoes the newest entry and returns its label, or nil if there is none. Open gestures (every
    /// owner's) are ended first, so undo during a drag undoes the drag.
    @discardableResult
    public mutating func undo(_ project: inout Project) throws(DAWError) -> String? {
        endAllGestures()
        guard let entry = undoEntries.last else { return nil }
        let redo = try Self.apply(entry.command, to: &project)
        undoEntries.removeLast()
        redoEntries.append(Entry(label: entry.label, command: redo, serial: entry.serial))
        return entry.label
    }

    /// Redoes the newest undone entry and returns its label, or nil if there is none.
    @discardableResult
    public mutating func redo(_ project: inout Project) throws(DAWError) -> String? {
        endAllGestures()
        guard let entry = redoEntries.last else { return nil }
        let inverse = try Self.apply(entry.command, to: &project)
        redoEntries.removeLast()
        undoEntries.append(Entry(label: entry.label, command: inverse, serial: entry.serial))
        return entry.label
    }

    /// Drops the history. The state the project is in gets a new marker, so it matches no earlier
    /// one (DW-337).
    public mutating func removeAll() {
        undoEntries.removeAll()
        redoEntries.removeAll()
        gestures.removeAll()
        baseSerial = nextSerial
        nextSerial += 1
    }

    // MARK: Gestures (MODEL-003, DW-336)

    /// Starts coalescing for `owner`: the commands it performs until the matching `endGesture`
    /// become one undo entry labelled `label`. An owner's gestures nest; only its outermost one
    /// counts. Other owners' gestures are independent.
    public mutating func beginGesture(_ label: String, owner: GestureOwner = .ui) {
        if let i = gestures.firstIndex(where: { $0.owner == owner }) {
            gestures[i].depth += 1
        } else {
            gestures.append(Gesture(owner: owner, label: label, depth: 1))
        }
    }

    /// Ends `owner`'s innermost gesture. When its outermost one ends, its commands are pushed as
    /// one entry (none if nothing was applied). Returns true when that happened. Another owner's
    /// gesture is never ended here.
    @discardableResult
    public mutating func endGesture(owner: GestureOwner = .ui) -> Bool {
        guard let i = gestures.firstIndex(where: { $0.owner == owner }) else { return false }
        gestures[i].depth -= 1
        guard gestures[i].depth == 0 else { return false }
        return close(gestures.remove(at: i))
    }

    /// Closes every open gesture of every owner, in the order they began.
    mutating func endAllGestures() {
        while !gestures.isEmpty { close(gestures.removeFirst()) }
    }

    // MARK: Session rate (DW-334)

    /// Rescales every undo and redo entry and the open gestures' commands from `from` Hz to `to` Hz
    /// (`Command.rescaled`), so their snapshots of sample values match the rescaled project.
    mutating func rescaleHistory(from: Double, to: Double) {
        func rescale(_ entry: Entry) -> Entry {
            Entry(label: entry.label, command: entry.command.rescaled(from: from, to: to), serial: entry.serial)
        }
        undoEntries = undoEntries.map(rescale)
        redoEntries = redoEntries.map(rescale)
        for g in gestures.indices {
            gestures[g].inverses = gestures[g].inverses.map { $0.rescaled(from: from, to: to) }
        }
    }

    // MARK: Private

    /// MODEL-032, DW-031: in Debug, every command, undo and redo must leave a valid project. A
    /// command that breaks an invariant is a bug in that command; it is rejected like an invalid
    /// one (project and history unchanged), so the error reaches whoever performed it.
    #if DEBUG
    static let validatesAfterEachCommand = true
    #else
    static let validatesAfterEachCommand = false
    #endif

    private static func apply(_ command: any Command, to project: inout Project) throws(DAWError) -> any Command {
        var working = project
        let inverse = try command.apply(to: &working)
        if validatesAfterEachCommand { try working.validate() }
        project = working
        return inverse
    }

    @discardableResult
    private mutating func close(_ gesture: Gesture) -> Bool {
        switch gesture.inverses.count {
        case 0:
            return false
        case 1:
            push(label: gesture.label, inverse: gesture.inverses[0])
        default:
            push(label: gesture.label, inverse: CompositeCommand(gesture.label, gesture.inverses.reversed()))
        }
        return true
    }

    private mutating func push(label: String, inverse: any Command) {
        undoEntries.append(Entry(label: label, command: inverse, serial: nextSerial))
        nextSerial += 1
        if undoEntries.count > limit {
            let dropped = undoEntries.count - limit
            // DW-337: the bottom of the stack is now the state after the newest dropped entry.
            baseSerial = undoEntries[dropped - 1].serial
            undoEntries.removeFirst(dropped)
        }
    }
}
