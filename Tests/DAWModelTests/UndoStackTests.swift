import DAWModel
import Testing

@Suite("UndoStack")
struct UndoStackTests {
    init() { TestCommands.register() }

    @Test("MODEL-001: apply returns an inverse that restores the project, and its inverse redoes")
    func renameTrackRoundTrip() throws {
        var project = Project(name: "P")
        _ = try TestAddTrack(name: "Drums").apply(to: &project)
        let id = project.tracks[0].id
        let original = project

        let inverse = try RenameTrack(trackID: id, name: "Kit").apply(to: &project)
        #expect(project.tracks[0].name == "Kit")
        let redo = try inverse.apply(to: &project)
        #expect(project == original)
        _ = try redo.apply(to: &project)
        #expect(project.tracks[0].name == "Kit")

        #expect(throws: DAWError.notFound(kind: "track", id: 999)) {
            try RenameTrack(trackID: 999, name: "x").apply(to: &project)
        }
    }

    @Test("MODEL-002: random command sequences — undo-all restores the original, redo-all the final")
    func randomSequencesUndoAll() throws {
        var rng = SplitMix64(seed: 0x0D_E002)
        var performed = 0
        var rejected = 0
        for _ in 0..<200 {
            let original = Project(name: "Random")
            var project = original
            var stack = UndoStack()
            var states = [project]
            for _ in 0..<Int.random(in: 1...40, using: &rng) {
                let command = randomCommand(for: project, using: &rng)
                do {
                    try stack.perform(command, on: &project)
                    states.append(project)
                    performed += 1
                } catch {
                    rejected += 1
                    // MODEL-031: a rejected command leaves the project as it was.
                    #expect(project == states.last!)
                }
            }
            let final = project
            #expect(stack.undoEntries.count == states.count - 1)

            // Step back through every intermediate state.
            for expected in states.dropLast().reversed() {
                try stack.undo(&project)
                #expect(project == expected)
            }
            #expect(project == original)
            let nothing = try stack.undo(&project)
            #expect(nothing == nil)

            while try stack.redo(&project) != nil {}
            #expect(project == final)
        }
        // Both paths are exercised substantially.
        #expect(performed > 2000 && rejected > 200, "performed \(performed), rejected \(rejected)")
    }

    @Test("MODEL-002: a new perform clears the redo stack")
    func performClearsRedo() throws {
        var project = Project()
        var stack = UndoStack()
        try stack.perform(TestAddTrack(name: "A"), on: &project)
        try stack.perform(TestAddTrack(name: "B"), on: &project)
        try stack.undo(&project)
        #expect(stack.canRedo && stack.redoLabel == "Add Track")
        try stack.perform(TestAddTrack(name: "C"), on: &project)
        #expect(!stack.canRedo)
        #expect(project.tracks.map(\.name) == ["A", "C"])
    }

    @Test("MODEL-002: depth is capped at 1000; the oldest entries are dropped")
    func depthCap() throws {
        #expect(UndoStack.defaultLimit == 1000)
        var project = Project()
        var stack = UndoStack()
        try stack.perform(TestAddTrack(name: "T"), on: &project)
        let id = project.tracks[0].id
        for i in 1...1100 {
            // Gains stay in the fader's range (MODEL-032 checks it in Debug).
            try stack.perform(TestSetGain(trackID: id, gain: Float(i) / 1000), on: &project)
        }
        #expect(stack.undoEntries.count == 1000)
        while try stack.undo(&project) != nil {}
        // The add and the first 100 gain changes fell off the bottom.
        #expect(project.tracks.count == 1)
        #expect(project.tracks[0].strip.gain == Float(100) / 1000)
    }

    @Test("MODEL-002: a command that throws after mutating leaves project and history unchanged")
    func failedCommandIsAtomic() throws {
        var project = Project(name: "Keep")
        var stack = UndoStack()
        try stack.perform(TestAddTrack(name: "A"), on: &project)
        let before = project
        #expect(throws: DAWError.invalidArgument("always fails")) {
            try stack.perform(TestFailAfterMutation(), on: &project)
        }
        #expect(project == before)
        #expect(stack.undoEntries.count == 1 && stack.undoLabel == "Add Track")
    }

    @Test("IDs are never reused, even after undo")
    func idsNeverReused() throws {
        var project = Project()
        var stack = UndoStack()
        try stack.perform(TestAddTrack(name: "A"), on: &project)
        let first = project.tracks[0].id
        try stack.undo(&project)
        try stack.perform(TestAddTrack(name: "B"), on: &project)
        #expect(project.tracks[0].id != first)
        #expect(project.master.id != first)
    }

    @Test("Redo of an add recreates the same ID, so later redos still find it")
    func redoKeepsIDs() throws {
        var project = Project()
        var stack = UndoStack()
        try stack.perform(TestAddTrack(name: "A"), on: &project)
        let id = project.tracks[0].id
        try stack.perform(RenameTrack(trackID: id, name: "B"), on: &project)
        let final = project
        try stack.undo(&project)
        try stack.undo(&project)
        try stack.redo(&project)
        try stack.redo(&project)
        #expect(project == final)
    }

    // MARK: Gestures

    @Test("MODEL-003: a 100-step drag is one undo entry, and undo/redo restore start and end")
    func hundredStepDrag() throws {
        var project = Project()
        var stack = UndoStack()
        try stack.perform(TestAddTrack(name: "A"), on: &project)
        let track = project.tracks[0].id
        try stack.perform(TestAddClip(trackID: track, start: 0, length: 960), on: &project)
        let clip = project.tracks[0].clips[0].id
        let start = project

        stack.beginGesture("Move Clip")
        for _ in 0..<100 {
            try stack.perform(TestNudgeClip(trackID: track, clipID: clip, delta: 10), on: &project)
        }
        #expect(stack.undoEntries.count == 2, "nothing is pushed while the gesture is open")
        let pushed = stack.endGesture()
        #expect(pushed)
        let end = project
        #expect(end.tracks[0].clips[0].start == 1000)

        #expect(stack.undoEntries.count == 3)
        #expect(stack.undoLabel == "Move Clip")
        try stack.undo(&project)
        #expect(project == start)
        try stack.redo(&project)
        #expect(project == end)
    }

    @Test("MODEL-003: a gesture with no changes pushes nothing; nested gestures make one entry")
    func emptyAndNestedGestures() throws {
        var project = Project()
        var stack = UndoStack()
        stack.beginGesture("Nothing")
        let pushedEmpty = stack.endGesture()
        #expect(!pushedEmpty)
        #expect(!stack.canUndo)

        try stack.perform(TestAddTrack(name: "A"), on: &project)
        let id = project.tracks[0].id
        stack.beginGesture("Outer")
        try stack.perform(TestSetGain(trackID: id, gain: 0.5), on: &project)
        stack.beginGesture("Inner")
        try stack.perform(TestSetGain(trackID: id, gain: 0.25), on: &project)
        let pushedInner = stack.endGesture()
        #expect(!pushedInner)
        #expect(stack.isGestureActive)
        let pushedOuter = stack.endGesture()
        #expect(pushedOuter)
        #expect(stack.undoEntries.count == 2 && stack.undoLabel == "Outer")
        try stack.undo(&project)
        #expect(project.tracks[0].strip.gain == 1)
    }

    @Test("MODEL-003: undo during a gesture ends it first, then undoes it")
    func undoDuringGesture() throws {
        var project = Project()
        var stack = UndoStack()
        try stack.perform(TestAddTrack(name: "A"), on: &project)
        let id = project.tracks[0].id
        stack.beginGesture("Fader")
        try stack.perform(TestSetGain(trackID: id, gain: 0.5), on: &project)
        let label = try stack.undo(&project)
        #expect(label == "Fader")
        #expect(!stack.isGestureActive)
        #expect(project.tracks[0].strip.gain == 1)
    }

    // MARK: Composite

    @Test("MODEL-004: a composite is one entry; its inverse undoes the steps in reverse order")
    func compositeUndo() throws {
        var project = Project()
        var stack = UndoStack()
        try stack.perform(TestAddTrack(name: "A"), on: &project)
        let id = project.tracks[0].id
        try stack.perform(TestAddClip(trackID: id, start: 0, length: 960), on: &project)
        let before = project
        // "Delete track" = remove what's on it, then the track.
        let delete = CompositeCommand(
            "Delete Track",
            [TestRemoveClip(trackID: id, clipID: project.tracks[0].clips[0].id), TestRemoveTrack(trackID: id)])
        try stack.perform(delete, on: &project)
        #expect(project.tracks.isEmpty)
        #expect(stack.undoLabel == "Delete Track" && stack.undoEntries.count == 3)
        try stack.undo(&project)
        #expect(project == before)
        try stack.redo(&project)
        #expect(project.tracks.isEmpty)
    }

    @Test("MODEL-004: a composite whose later step fails changes nothing")
    func compositeIsAtomic() throws {
        var project = Project()
        _ = try TestAddTrack(name: "A").apply(to: &project)
        let before = project
        let command = CompositeCommand(
            "Bad", [RenameTrack(trackID: project.tracks[0].id, name: "B"), TestRemoveTrack(trackID: 999)])
        #expect(throws: DAWError.notFound(kind: "track", id: 999)) { try command.apply(to: &project) }
        #expect(project == before)
    }
}

/// A command that is usually valid for `project`, sometimes not (exercises rejection), and
/// sometimes a composite of several.
func randomCommand(for project: Project, depth: Int = 0, using rng: inout SplitMix64) -> any Command {
    let trackIDs = project.tracks.map(\.id)
    let anyTrack = trackIDs.randomElement(using: &rng) ?? 999
    func clipOf(_ track: NodeIDValue) -> ModelID? {
        project.track(track)?.clips.randomElement(using: &rng)?.id
    }
    switch Int.random(in: 0..<10, using: &rng) {
    case 0, 1:
        return TestAddTrack(name: "T\(Int.random(in: 0..<100, using: &rng))")
    case 2:
        return TestRemoveTrack(trackID: anyTrack)
    case 3:
        return RenameTrack(trackID: anyTrack, name: "N\(Int.random(in: 0..<100, using: &rng))")
    case 4:
        return TestSetGain(trackID: anyTrack, gain: Float(Int.random(in: 0...16, using: &rng)) / 8)
    case 5, 6:
        return TestAddClip(
            trackID: anyTrack, start: Tick(Int64.random(in: 0...100_000, using: &rng)),
            length: Tick(Int64.random(in: 1...10_000, using: &rng)))
    case 7:
        return TestRemoveClip(trackID: anyTrack, clipID: clipOf(anyTrack) ?? 999)
    case 8:
        return TestNudgeClip(
            trackID: anyTrack, clipID: clipOf(anyTrack) ?? 999,
            delta: Int64.random(in: -500...500, using: &rng))
    default:
        guard depth < 2 else { return TestFailAfterMutation() }
        // The steps are generated against the starting project, so later ones may be invalid.
        let steps = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
            randomCommand(for: project, depth: depth + 1, using: &rng)
        }
        return CompositeCommand("Composite", steps)
    }
}
