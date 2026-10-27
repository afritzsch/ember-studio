import Foundation
import Observation
import os

/// MODEL-007: holds the current project, its undo history and dirty flag, and reports every change
/// on `changeStream()`. All edits go through `perform` (D-11). Runs on the main actor in the app
/// and in the headless tools alike (07 Interfaces).
@Observable
@MainActor
public final class ProjectStore {
    public private(set) var project: Project
    /// True when the project differs from the last saved (or opened) state. Undoing back to that
    /// state clears it.
    public private(set) var isDirty = false

    private var history: UndoStack
    /// `history.stateMarker` at the last save.
    private var cleanMarker: UInt64 = 0
    /// The project when the open gesture began, and everything its updates touched so far.
    private var gestureStart: Project?
    private var gestureChange: ProjectChange?

    @ObservationIgnored private var subscribers: [Int: AsyncStream<ProjectChange>.Continuation] = [:]
    @ObservationIgnored private var nextSubscriber = 0

    private static let log = Logger(subsystem: "dev.emberstudio", category: "model")

    public init(project: Project = Project(), undoLimit: Int = UndoStack.defaultLimit) {
        self.project = project
        self.history = UndoStack(limit: undoLimit)
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    /// For "Undo <label>" menu items and the control protocol's `undo` result (CTL-002).
    public var undoLabel: String? { history.undoLabel }
    public var redoLabel: String? { history.redoLabel }
    public var isGestureActive: Bool { history.isGestureActive }

    /// Applies `command` and pushes it onto the undo stack, or, inside a gesture, applies it
    /// without pushing (MODEL-003). Throws without changing anything if the command is invalid.
    public func perform(_ command: any Command) throws(DAWError) {
        let before = project
        var working = project
        try history.perform(command, on: &working)
        project = working
        if gestureStart != nil {
            let change = ProjectChange(cause: .gestureUpdate, label: command.label, from: before, to: working)
            gestureChange?.formUnion(change)
            publish(change)
        } else {
            publish(ProjectChange(cause: .perform, label: command.label, from: before, to: working))
        }
    }

    /// Undoes the newest entry; does nothing if there is none. An open gesture is ended first.
    public func undo() {
        endGestureForHistoryStep()
        step(.undo) { (history: inout UndoStack, project: inout Project) throws(DAWError) in
            try history.undo(&project)
        }
    }

    public func redo() {
        endGestureForHistoryStep()
        step(.redo) { (history: inout UndoStack, project: inout Project) throws(DAWError) in
            try history.redo(&project)
        }
    }

    // MARK: Gestures (MODEL-003)

    /// Starts a continuous edit (fader drag, clip drag). Commands performed until `endGesture`
    /// apply immediately, each publishing a `.gestureUpdate`, and become one undo entry. Engine sync
    /// (MODEL-021) can send param-only updates straight to param slots instead of rebuilding.
    /// Gestures nest; only the outermost counts.
    public func beginGesture(_ label: String) {
        if !history.isGestureActive {
            gestureStart = project
            gestureChange = ProjectChange(cause: .gestureEnd, label: label)
        }
        history.beginGesture(label)
    }

    /// Ends the gesture: pushes its single undo entry and publishes a `.gestureEnd` covering all of
    /// its updates.
    public func endGesture() {
        guard history.isGestureActive else { return }
        history.endGesture()
        guard !history.isGestureActive else { return }
        finishGesture()
    }

    // MARK: Changes

    /// A new stream of every change from now on. Each call makes an independent subscriber.
    public func changeStream() -> AsyncStream<ProjectChange> {
        let (stream, continuation) = AsyncStream<ProjectChange>.makeStream()
        let id = nextSubscriber
        nextSubscriber += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    // MARK: Persistence (MODEL-040..046, T-031)

    /// Not implemented yet: the project folder format is T-031.
    public func save(to url: URL?) async throws(DAWError) {
        throw .notImplemented("ProjectStore.save (MODEL-040/041, T-031)")
    }

    /// Not implemented yet: the project folder format is T-031.
    public static func open(_ url: URL, recover: Bool) async throws(DAWError) -> ProjectStore {
        throw .notImplemented("ProjectStore.open (MODEL-040/045, T-031)")
    }

    /// Records the current state as saved. For save/open (T-031).
    func markClean() {
        cleanMarker = history.stateMarker
        updateDirty()
    }

    // MARK: Private

    private func step(
        _ cause: ProjectChange.Cause,
        _ body: (inout UndoStack, inout Project) throws(DAWError) -> String?
    ) {
        let before = project
        var working = project
        do {
            guard let label = try body(&history, &working) else { return }
            project = working
            publish(ProjectChange(cause: cause, label: label, from: before, to: working))
        } catch {
            // An inverse that doesn't apply means the history no longer matches the project. Keep
            // the project as it is and drop the history rather than leave undo half-working.
            Self.log.fault("\(String(describing: cause)) failed, clearing undo history: \(error)")
            history.removeAll()
            cleanMarker = .max
            updateDirty()
        }
    }

    private func endGestureForHistoryStep() {
        guard history.isGestureActive else { return }
        history.endAllGestures()
        finishGesture()
    }

    private func finishGesture() {
        let change = gestureChange
        gestureStart = nil
        gestureChange = nil
        if let change, !change.isEmpty {
            publish(change)
        }
    }

    private func publish(_ change: ProjectChange) {
        updateDirty()
        for continuation in subscribers.values {
            continuation.yield(change)
        }
    }

    private func updateDirty() {
        let dirty = history.gestureHasChanges || history.stateMarker != cleanMarker
        if dirty != isDirty { isDirty = dirty }
    }
}
