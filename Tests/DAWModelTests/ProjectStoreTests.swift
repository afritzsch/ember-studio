import DAWModel
import Foundation
import Testing

@Suite("ProjectStore")
@MainActor
struct ProjectStoreTests {
    init() { TestCommands.register() }

    /// A store with one track and one clip on it, history cleared.
    private func makeStore() throws -> (ProjectStore, track: NodeIDValue, clip: ModelID) {
        var project = Project.withTestAsset(name: "S")
        _ = try TestAddTrack(name: "A").apply(to: &project)
        let track = project.tracks[0].id
        _ = try TestAddClip(trackID: track, start: 0, length: 960).apply(to: &project)
        return (ProjectStore(project: project), track, project.tracks[0].clips[0].id)
    }

    @Test("MODEL-007: perform/undo/redo update the project, labels and dirty flag")
    func performUndoRedo() throws {
        let (store, track, _) = try makeStore()
        let original = store.project
        #expect(!store.isDirty && !store.canUndo)

        try store.perform(RenameTrack(trackID: track, name: "B"))
        #expect(store.project.tracks[0].name == "B")
        #expect(store.isDirty && store.undoLabel == "Rename Track")

        store.undo()
        #expect(store.project == original)
        #expect(!store.isDirty, "back at the opened state")
        #expect(store.redoLabel == "Rename Track")

        store.redo()
        #expect(store.project.tracks[0].name == "B" && store.isDirty)
    }

    @Test("MODEL-007: a rejected command throws and changes nothing")
    func rejectedCommand() throws {
        let (store, _, _) = try makeStore()
        let before = store.project
        #expect(throws: DAWError.notFound(kind: "track", id: 999)) {
            try store.perform(RenameTrack(trackID: 999, name: "x"))
        }
        #expect(store.project == before && !store.isDirty && !store.canUndo)
    }

    @Test("MODEL-007: changeStream reports cause, label and the changed IDs")
    func changeStream() async throws {
        let (store, track, clip) = try makeStore()
        let stream = store.changeStream()
        let other = store.changeStream()

        try store.perform(TestNudgeClip(trackID: track, clipID: clip, delta: 5))
        try store.perform(RenameTrack(trackID: track, name: "B"))
        store.undo()
        try store.perform(TestAddTrack(name: "C"))

        var changes = stream.makeAsyncIterator()
        let nudge = try #require(await changes.next())
        #expect(nudge == ProjectChange(cause: .perform, label: "Move Clip", changedIDs: [track, clip]))
        let rename = try #require(await changes.next())
        #expect(rename.changedIDs == [track] && rename.changedFields.isEmpty)
        let undo = try #require(await changes.next())
        #expect(undo.cause == .undo && undo.label == "Rename Track" && undo.changedIDs == [track])
        let add = try #require(await changes.next())
        let newTrack = try #require(store.project.tracks.last?.id)
        #expect(add.changedIDs == [newTrack] && add.changedFields == [.trackOrder])

        // Every subscriber gets every change.
        var second = other.makeAsyncIterator()
        #expect(await second.next() == nudge)
    }

    @Test("MODEL-003: a 100-step drag through the store gives 1 undo entry")
    func hundredStepDrag() async throws {
        let (store, track, clip) = try makeStore()
        let start = store.project
        let stream = store.changeStream()

        store.beginGesture("Move Clip")
        for _ in 0..<100 {
            try store.perform(TestNudgeClip(trackID: track, clipID: clip, delta: 10))
        }
        #expect(!store.canUndo, "nothing pushed while dragging")
        #expect(store.isDirty)
        store.endGesture()

        #expect(store.project.tracks[0].clips[0].start == 1000)
        #expect(store.undoLabel == "Move Clip")
        store.undo()
        #expect(store.project == start)
        #expect(!store.canUndo, "exactly one entry")

        // 100 updates, applied immediately without pushing, then one gesture end.
        var changes = stream.makeAsyncIterator()
        for _ in 0..<100 {
            #expect(await changes.next()?.cause == .gestureUpdate)
        }
        let end = try #require(await changes.next())
        #expect(end == ProjectChange(cause: .gestureEnd, label: "Move Clip", changedIDs: [track, clip]))
        #expect(await changes.next()?.cause == .undo)
    }

    @Test("MODEL-003: a gesture that returns to its start still reports gestureEnd")
    func roundTripGestureReportsEnd() async throws {
        let (store, track, clip) = try makeStore()
        let stream = store.changeStream()
        store.beginGesture("Wiggle")
        try store.perform(TestNudgeClip(trackID: track, clipID: clip, delta: 10))
        try store.perform(TestNudgeClip(trackID: track, clipID: clip, delta: -10))
        store.endGesture()
        var changes = stream.makeAsyncIterator()
        _ = await changes.next()
        _ = await changes.next()
        // The engine saw the intermediate position, so sync must hear about the end.
        #expect(await changes.next() == ProjectChange(cause: .gestureEnd, label: "Wiggle", changedIDs: [track, clip]))
    }

    @Test("MODEL-007: an inverse that fails leaves the project and clears the history")
    func brokenInverse() throws {
        let (store, _, _) = try makeStore()
        try store.perform(TestBrokenInverse())
        let after = store.project
        store.undo()
        #expect(store.project == after)
        #expect(!store.canUndo && !store.canRedo)
        #expect(store.isDirty)
    }
}
