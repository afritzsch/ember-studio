/// MODEL-005: trims or extends a clip to the window `[start, start + length)` while its content
/// stays where it is on the timeline. Moving the start edge shifts an audio clip's source offset by
/// the samples between the old and new start (through the tempo map), and shifts MIDI note starts
/// the other way. Notes that fall outside the window are kept, so trimming back brings them back;
/// the engine only plays what is inside (GraphDescriptionBuilder). Fades are left as they are; the
/// clip player clamps them to the clip.
public struct ResizeClip: Command {
    public static let type = "ResizeClip"

    public var clipID: ModelID
    public var start: Tick
    public var length: Tick

    public init(clipID: ModelID, start: Tick, length: Tick) {
        self.clipID = clipID
        self.start = start
        self.length = length
    }

    public var label: String { "Resize Clip" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let old = project.clip(clipID) else { throw .notFound(kind: "clip", id: clipID) }
        try checkWindow(start: start, length: length)
        let shift = start.raw - old.start.raw
        let samples = project.samples(from: old.start, to: start)
        try project.updateClip(clipID) { (clip: inout Clip) throws(DAWError) in
            switch clip {
            case .audio(var audio):
                let offset = audio.sourceOffsetSamples + samples
                guard offset >= 0 else {
                    throw .invalidArgument("clip \(clipID) can't start \(-offset) samples before its audio")
                }
                audio.sourceOffsetSamples = offset
                audio.start = start
                audio.length = length
                clip = .audio(audio)
            case .midi(var midi):
                for i in midi.notes.indices {
                    let (moved, overflow) = midi.notes[i].start.raw.subtractingReportingOverflow(shift)
                    guard !overflow else { throw .invalidArgument("note \(midi.notes[i].id) would leave the timeline") }
                    midi.notes[i].start.raw = moved
                }
                midi.start = start
                midi.length = length
                clip = .midi(midi)
            }
            try clip.validate()
        }
        return ResizeClip(clipID: clipID, start: old.start, length: old.length)
    }
}

/// MODEL-031: a clip window lies on the timeline (0…`Tick.timelineEnd`) and isn't empty.
func checkWindow(start: Tick, length: Tick) throws(DAWError) {
    guard start.raw >= 0, length.raw > 0, length <= Tick.timelineEnd, start.raw <= Tick.timelineEnd.raw - length.raw else {
        throw .invalidArgument("clip window [\(start.raw), +\(length.raw)) is empty or off the timeline")
    }
}
