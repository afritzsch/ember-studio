/// MODEL-005 (T-093, DW-216, REC-011): picks the MIDI input a MIDI track hears: a source (by
/// CoreMIDI unique ID, `MidiInputInfo.uniqueID`) or all of them, and a channel 1…16 or omni (0).
/// Docs: docs/autobuild/DECISIONS.md "T-093 model shape".
///
/// Unlike arming, the input is a document setting, so this is a normal undoable command ("Set MIDI
/// Input"); the inverse sets the old input. It isn't structural (MODEL-021): engine sync hands it
/// to the engine as the track's filter (`EngineProtocol.setMidiInput`), whether the track is armed
/// or not. A source that isn't connected is accepted and kept: it delivers nothing until it is.
///
/// JSON: `{"type": "SetTrackMidiInput", "trackID": 3, "source": "all" | "<unique ID>", "channel": 0…16}`.
public struct SetTrackMidiInput: Command {
    public static let type = "SetTrackMidiInput"

    public var trackID: NodeIDValue
    public var source: Track.MidiInput.Source
    public var channel: UInt8

    public init(trackID: NodeIDValue, source: Track.MidiInput.Source, channel: UInt8) {
        self.trackID = trackID
        self.source = source
        self.channel = channel
    }

    public init(trackID: NodeIDValue, _ input: Track.MidiInput) {
        self.init(trackID: trackID, source: input.source, channel: input.channel)
    }

    public var label: String { "Set MIDI Input" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard channel <= Track.MidiInput.maxChannel else {
            throw .invalidArgument("MIDI channel \(channel) is outside 0 (omni)…\(Track.MidiInput.maxChannel)")
        }
        let old = try project.updateTrack(trackID) { track throws(DAWError) in
            guard track.kind == .midi else { throw .invalidArgument("track \(trackID) is not a MIDI track") }
            defer { track.midiInput = Track.MidiInput(source: source, channel: channel) }
            return track.midiInput
        }
        return SetTrackMidiInput(trackID: trackID, old)
    }
}
