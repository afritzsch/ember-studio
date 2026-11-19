/// MODEL-005, REC-030 (T-080): puts a take folder with new IDs on a track. Each take is a clip of
/// the track's kind: an audio take is a view into an asset (`assetID`, `sourceOffsetSamples`,
/// like `AddClip`), a MIDI take holds notes (starts relative to the take, like `AddNotes`). The
/// folder spans the takes' union and gets the default comp (REC-031: at each position the latest
/// take that covers it). IDs are allocated in order: the folder, then per take its ID, its clip's
/// and its notes'. `RecordingImport` makes one inside the "Record" composite of a loop recording.
/// The inverse is `RemoveTakeFolder`, whose inverse `RestoreTakeFolder` puts the same IDs back.
public struct CreateTakeFolder: Command {
    public static let type = "CreateTakeFolder"

    /// One take: everything but the IDs.
    public struct TakeSpec: Hashable, Sendable, Codable {
        public var start: Tick
        public var length: Tick
        /// Audio takes: required.
        public var assetID: ModelID?
        /// Audio: in samples at the session rate. Default 0.
        public var sourceOffsetSamples: Int64?
        /// Audio: linear, 0…+12 dB. Default 1.
        public var gain: Float?
        /// MIDI takes: the notes (default none), starts relative to the take.
        public var notes: [AddNotes.NoteSpec]?

        public init(start: Tick, length: Tick, assetID: ModelID? = nil, sourceOffsetSamples: Int64? = nil,
                    gain: Float? = nil, notes: [AddNotes.NoteSpec]? = nil) {
            self.start = start
            self.length = length
            self.assetID = assetID
            self.sourceOffsetSamples = sourceOffsetSamples
            self.gain = gain
            self.notes = notes
        }
    }

    public var trackID: NodeIDValue
    public var takes: [TakeSpec]

    public init(trackID: NodeIDValue, takes: [TakeSpec]) {
        self.trackID = trackID
        self.takes = takes
    }

    public var label: String { "Create Take Folder" }

    /// DW-334: audio takes' explicit offsets follow a session-rate change.
    public func rescaled(from: Double, to: Double) -> any Command {
        var command = self
        for k in command.takes.indices {
            command.takes[k].sourceOffsetSamples = takes[k].sourceOffsetSamples.map {
                Project.rescaleSamples($0, from: from, to: to)
            }
        }
        return command
    }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let track = project.track(trackID) else { throw .notFound(kind: "track", id: trackID) }
        guard !takes.isEmpty else { throw .invalidArgument("a take folder needs at least one take") }
        let folderID = project.ids.allocate()
        var made: [Take] = []
        for spec in takes {
            let takeID = project.ids.allocate()
            let clipID = project.ids.allocate()
            let clip: Clip
            switch track.kind {
            case .audio:
                guard spec.notes == nil else { throw .invalidArgument("audio takes have no notes") }
                guard let assetID = spec.assetID else { throw .invalidArgument("an audio take needs an assetID") }
                guard project.asset(assetID) != nil else { throw .notFound(kind: "asset", id: assetID) }
                try checkClipGain(spec.gain ?? 1)
                clip = .audio(AudioClip(id: clipID, assetID: assetID, start: spec.start, length: spec.length,
                                        sourceOffsetSamples: spec.sourceOffsetSamples ?? 0, gain: spec.gain ?? 1))
            case .midi:
                guard spec.assetID == nil, spec.sourceOffsetSamples == nil, spec.gain == nil else {
                    throw .invalidArgument("MIDI takes have no asset, offset or gain")
                }
                var notes: [Note] = []
                for note in spec.notes ?? [] {
                    notes.append(Note(id: project.ids.allocate(), start: note.start, length: note.length,
                                      pitch: note.pitch, velocity: note.velocity ?? 100, channel: note.channel ?? 0))
                }
                notes.sort(by: Note.clipOrder)
                clip = .midi(MidiClip(id: clipID, start: spec.start, length: spec.length, notes: notes))
            }
            do { try clip.validate() } catch { throw .invalidArgument("take: \(error)") }
            made.append(Take(id: takeID, clip: clip))
        }
        let folder = TakeFolder(id: folderID, takes: made)
        try folder.validate(on: track.kind)
        try project.updateTrack(trackID) { $0.takeFolders.append(folder) }
        return RemoveTakeFolder(folderID: folderID)
    }
}
