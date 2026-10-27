import DAWModel

// Test-only commands for the undo/gesture/composite/registry machinery. The real catalogue
// (MODEL-005) comes with T-022/T-030/T-042; until then these stand in for it.

enum TestCommands {
    static let all: [any Command.Type] = [
        TestAddTrack.self, TestRemoveTrack.self, TestInsertTrack.self, TestSetGain.self,
        TestAddClip.self, TestRemoveClip.self, TestInsertClip.self, TestNudgeClip.self,
        TestFailAfterMutation.self, TestBrokenInverse.self,
    ]

    /// Idempotent, so every suite can call it.
    static func register() {
        for type in all { CommandRegistry.register(type) }
    }
}

struct TestAddTrack: Command {
    static let type = "TestAddTrack"
    var name: String
    var label: String { "Add Track" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        let id = project.ids.allocate()
        project.tracks.append(Track(id: id, name: name, kind: .audio))
        return TestRemoveTrack(trackID: id)
    }
}

struct TestRemoveTrack: Command {
    static let type = "TestRemoveTrack"
    var trackID: NodeIDValue
    var label: String { "Remove Track" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let index = project.trackIndex(trackID) else { throw .notFound(kind: "track", id: trackID) }
        let track = project.tracks.remove(at: index)
        return TestInsertTrack(track: track, index: index)
    }
}

struct TestInsertTrack: Command {
    static let type = "TestInsertTrack"
    var track: Track
    var index: Int
    var label: String { "Insert Track" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard project.trackIndex(track.id) == nil else { throw .invalidArgument("track \(track.id) exists") }
        guard (0...project.tracks.count).contains(index) else { throw .invalidArgument("index \(index)") }
        project.ids.reserve(track.id)
        project.tracks.insert(track, at: index)
        return TestRemoveTrack(trackID: track.id)
    }
}

/// Absolute, like a fader write.
struct TestSetGain: Command {
    static let type = "TestSetGain"
    var trackID: NodeIDValue
    var gain: Float
    var label: String { "Set Gain" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        let old = try project.updateTrack(trackID) { track in
            defer { track.strip.gain = gain }
            return track.strip.gain
        }
        return TestSetGain(trackID: trackID, gain: old)
    }
}

struct TestAddClip: Command {
    static let type = "TestAddClip"
    var trackID: NodeIDValue
    var start: Tick
    var length: Tick
    var label: String { "Add Clip" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        let id = project.ids.allocate()
        try project.updateTrack(trackID) { track in
            track.clips.append(.audio(AudioClip(id: id, assetID: 0, start: start, length: length)))
        }
        return TestRemoveClip(trackID: trackID, clipID: id)
    }
}

struct TestRemoveClip: Command {
    static let type = "TestRemoveClip"
    var trackID: NodeIDValue
    var clipID: ModelID
    var label: String { "Remove Clip" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        try project.updateTrack(trackID) { (track: inout Track) throws(DAWError) -> any Command in
            guard let index = track.clips.firstIndex(where: { $0.id == clipID }) else {
                throw .notFound(kind: "clip", id: clipID)
            }
            return TestInsertClip(trackID: trackID, clip: track.clips.remove(at: index), index: index)
        }
    }
}

struct TestInsertClip: Command {
    static let type = "TestInsertClip"
    var trackID: NodeIDValue
    var clip: Clip
    var index: Int
    var label: String { "Insert Clip" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        project.ids.reserve(clip.id)
        try project.updateTrack(trackID) { (track: inout Track) throws(DAWError) in
            guard (0...track.clips.count).contains(index) else { throw .invalidArgument("index \(index)") }
            track.clips.insert(clip, at: index)
        }
        return TestRemoveClip(trackID: trackID, clipID: clip.id)
    }
}

/// Relative, like one step of a clip drag, so a gesture's undo has to replay every step.
struct TestNudgeClip: Command {
    static let type = "TestNudgeClip"
    var trackID: NodeIDValue
    var clipID: ModelID
    var delta: Int64
    var label: String { "Move Clip" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        try project.updateTrack(trackID) { (track: inout Track) throws(DAWError) in
            guard let index = track.clips.firstIndex(where: { $0.id == clipID }),
                case .audio(var clip) = track.clips[index]
            else { throw .notFound(kind: "clip", id: clipID) }
            clip.start = Tick(clip.start.raw + delta)
            track.clips[index] = .audio(clip)
        }
        return TestNudgeClip(trackID: trackID, clipID: clipID, delta: -delta)
    }
}

/// Changes the project, then throws: callers must not keep the half-applied state.
struct TestFailAfterMutation: Command {
    static let type = "TestFailAfterMutation"
    var label: String { "Fail" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        project.name += " (corrupted)"
        project.tracks.removeAll()
        throw .invalidArgument("always fails")
    }
}

/// Applies fine, but its inverse never applies.
struct TestBrokenInverse: Command {
    static let type = "TestBrokenInverse"
    var label: String { "Broken" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        project.name += "!"
        return TestFailAfterMutation()
    }
}
