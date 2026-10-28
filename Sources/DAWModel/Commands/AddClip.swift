/// MODEL-005: adds a clip with a new ID to a track, in timeline order (DW-110). An audio track
/// gets an audio clip of `assetID`; a MIDI track gets an empty MIDI clip (notes are T-042's
/// commands). Audio-only fields on a MIDI track are rejected.
public struct AddClip: Command {
    public static let type = "AddClip"

    public var trackID: NodeIDValue
    public var start: Tick
    /// Audio default: the rest of the asset after `sourceOffsetSamples`, at the tempo map as it
    /// is now (D-06: a later tempo edit moves the clip but doesn't stretch it). Required for MIDI.
    public var length: Tick?
    /// Audio tracks: required.
    public var assetID: ModelID?
    /// In samples at the session rate. Default 0.
    public var sourceOffsetSamples: Int64?
    /// Linear, 0…+12 dB. Default 1.
    public var gain: Float?
    public var fadeIn: Tick?
    public var fadeOut: Tick?

    public init(
        trackID: NodeIDValue, start: Tick, length: Tick? = nil, assetID: ModelID? = nil,
        sourceOffsetSamples: Int64? = nil, gain: Float? = nil, fadeIn: Tick? = nil, fadeOut: Tick? = nil
    ) {
        self.trackID = trackID
        self.start = start
        self.length = length
        self.assetID = assetID
        self.sourceOffsetSamples = sourceOffsetSamples
        self.gain = gain
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    public var label: String { "Add Clip" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let track = project.track(trackID) else { throw .notFound(kind: "track", id: trackID) }
        guard start.raw >= 0 else { throw .invalidArgument("clip start \(start.raw) is negative") }
        let clip: Clip
        switch track.kind {
        case .audio:
            guard let assetID else { throw .invalidArgument("an audio clip needs an assetID") }
            guard let asset = project.asset(assetID) else { throw .notFound(kind: "asset", id: assetID) }
            let offset = sourceOffsetSamples ?? 0
            let length: Tick
            if let given = self.length {
                length = given
            } else {
                length = try project.lengthOfRest(of: asset, from: offset, at: start)
            }
            let fadeIn = fadeIn ?? 0, fadeOut = fadeOut ?? 0
            try checkFades(fadeIn: fadeIn, fadeOut: fadeOut, length: length)
            try checkClipGain(gain ?? 1)
            clip = .audio(AudioClip(id: project.ids.next, assetID: assetID, start: start, length: length,
                                    sourceOffsetSamples: offset, gain: gain ?? 1, fadeIn: fadeIn, fadeOut: fadeOut))
        case .midi:
            guard assetID == nil, sourceOffsetSamples == nil, gain == nil, fadeIn == nil, fadeOut == nil else {
                throw .invalidArgument("MIDI clips have no asset, offset, gain or fades")
            }
            guard let length else { throw .invalidArgument("a MIDI clip needs a length") }
            clip = .midi(MidiClip(id: project.ids.next, start: start, length: length))
        }
        try project.insertClip(clip, into: trackID)
        return RemoveClip(clipID: clip.id)
    }
}

extension Project {
    /// The ticks from `start` that cover the asset's frames after `offset` (session-rate samples).
    func lengthOfRest(of asset: AssetRef, from offset: Int64, at start: Tick) throws(DAWError) -> Tick {
        let frames = Int64((Double(asset.frames) * sessionSampleRate / asset.originalSampleRate).rounded())
        guard offset >= 0, offset < frames else {
            throw .invalidArgument("source offset \(offset) is outside the asset's \(frames) frames")
        }
        let startSample = tempoMap.tickToSample(start)
        var end = tempoMap.sampleToTick(startSample + frames - offset)
        if tempoMap.tickToSample(end) < startSample + frames - offset { end.raw += 1 }
        return Tick(max(end.raw - start.raw, 1))
    }
}

/// MODEL-031: fades are non-negative and each fits in the clip. They may overlap; the clip player
/// applies both there (AudioClipPlayer).
func checkFades(fadeIn: Tick, fadeOut: Tick, length: Tick) throws(DAWError) {
    guard (0...length.raw).contains(fadeIn.raw), (0...length.raw).contains(fadeOut.raw) else {
        throw .invalidArgument("fades \(fadeIn.raw)/\(fadeOut.raw) don't fit in a clip of length \(length.raw)")
    }
}

/// MODEL-031: clip gain is linear, 0…+12 dB.
func checkClipGain(_ gain: Float) throws(DAWError) {
    guard gain.isFinite, (0...AudioClip.maxGain).contains(gain) else {
        throw .invalidArgument("clip gain \(gain) is outside 0…\(AudioClip.maxGain)")
    }
}
