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
        var label: String
        var depth: Int
        /// Inverses of the commands applied so far, in apply order.
        var inverses: [any Command] = []
    }

    public let limit: Int
    public private(set) var undoEntries: [Entry] = []
    public private(set) var redoEntries: [Entry] = []
    private var gesture: Gesture?
    private var nextSerial: UInt64 = 1

    public init(limit: Int = defaultLimit) {
        precondition(limit > 0)
        self.limit = limit
    }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoLabel: String? { undoEntries.last?.label }
    public var redoLabel: String? { redoEntries.last?.label }
    public var isGestureActive: Bool { gesture != nil }
    /// Whether the open gesture has applied anything yet.
    public var gestureHasChanges: Bool { !(gesture?.inverses.isEmpty ?? true) }

    /// Names the state the project is in: the serial of the newest undo entry, 0 for none. Equal
    /// markers mean equal states (as long as no gesture is open).
    public var stateMarker: UInt64 { undoEntries.last?.serial ?? 0 }

    /// Applies `command`. Outside a gesture it is pushed as one undo entry; inside one it is
    /// recorded for the gesture's entry (MODEL-003). Either way the redo stack is cleared.
    /// A `HistoryExemptCommand` is applied (and validated) but leaves the history as it is (T-026).
    public mutating func perform(_ command: any Command, on project: inout Project) throws(DAWError) {
        let inverse = try Self.apply(command, to: &project)
        guard !command.isHistoryExempt else { return }
        redoEntries.removeAll()
        if gesture != nil {
            gesture!.inverses.append(inverse)
        } else {
            push(label: command.label, inverse: inverse)
        }
    }

    /// Undoes the newest entry and returns its label, or nil if there is none. An open gesture is
    /// ended first, so undo during a drag undoes the drag.
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

    public mutating func removeAll() {
        undoEntries.removeAll()
        redoEntries.removeAll()
        gesture = nil
    }

    // MARK: Gestures (MODEL-003)

    /// Starts coalescing: commands performed until the matching `endGesture` become one undo entry
    /// labelled `label`. Gestures nest; only the outermost one counts.
    public mutating func beginGesture(_ label: String) {
        if gesture != nil {
            gesture!.depth += 1
        } else {
            gesture = Gesture(label: label, depth: 1)
        }
    }

    /// Ends the innermost gesture. When the outermost one ends, its commands are pushed as one
    /// entry (none if nothing was applied). Returns true when that happened.
    @discardableResult
    public mutating func endGesture() -> Bool {
        guard var open = gesture else { return false }
        open.depth -= 1
        guard open.depth == 0 else {
            gesture = open
            return false
        }
        gesture = nil
        switch open.inverses.count {
        case 0:
            return false
        case 1:
            push(label: open.label, inverse: open.inverses[0])
        default:
            push(label: open.label, inverse: CompositeCommand(open.label, open.inverses.reversed()))
        }
        return true
    }

    /// Closes every open gesture level.
    mutating func endAllGestures() {
        while gesture != nil { endGesture() }
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

    private mutating func push(label: String, inverse: any Command) {
        undoEntries.append(Entry(label: label, command: inverse, serial: nextSerial))
        nextSerial += 1
        if undoEntries.count > limit {
            undoEntries.removeFirst(undoEntries.count - limit)
        }
    }
}
