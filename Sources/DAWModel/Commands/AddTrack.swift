/// MODEL-005: adds an empty audio or MIDI track with a new ID, at `index` (default: the end).
public struct AddTrack: Command {
    public static let type = "AddTrack"

    public var name: String
    public var kind: Track.Kind
    /// 0…track count; nil appends.
    public var index: Int?
    /// Default: the master.
    public var output: OutputTarget?
    public var color: TrackColor?

    public init(name: String, kind: Track.Kind, index: Int? = nil, output: OutputTarget? = nil, color: TrackColor? = nil) {
        self.name = name
        self.kind = kind
        self.index = index
        self.output = output
        self.color = color
    }

    public var label: String { "Add Track" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let at = index ?? project.tracks.count
        guard (0...project.tracks.count).contains(at) else { throw .invalidArgument("track index \(at) is outside 0…\(project.tracks.count)") }
        let output = output ?? .master
        // A new track has nothing routed into it, so its output can't close a cycle.
        try project.checkOutputTarget(output)
        let id = project.ids.allocate()
        project.tracks.insert(Track(id: id, name: name, kind: kind, color: color ?? .gray, output: output), at: at)
        return RemoveTrack(trackID: id)
    }
}
