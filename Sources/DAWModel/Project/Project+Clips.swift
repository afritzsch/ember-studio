/// Lookup and placement helpers for clips and assets (T-030).
///
/// DW-110: a track's clips are kept sorted by `(start, id)`. With the ID as tie-break the order is
/// a function of the clips alone, so a clip that moves away and back lands at the index it left
/// and undo restores the project exactly (MODEL-002). `validate()` checks it (MODEL-032).
extension Project {
    public func assetIndex(_ id: ModelID) -> Int? {
        assets.firstIndex { $0.id == id }
    }

    public func asset(_ id: ModelID) -> AssetRef? {
        assetIndex(id).map { assets[$0] }
    }

    /// The track holding the clip, and the clip's index in it.
    public func clipLocation(_ id: ModelID) -> (track: NodeIDValue, index: Int)? {
        for track in tracks {
            if let index = track.clips.firstIndex(where: { $0.id == id }) { return (track.id, index) }
        }
        return nil
    }

    public func clip(_ id: ModelID) -> Clip? {
        clipLocation(id).flatMap { track($0.track)?.clips[$0.index] }
    }

    /// Runs `body` on the clip in place, or throws `notFound` (MODEL-031), then puts the clip back
    /// in order in case its start changed.
    public mutating func updateClip<R>(
        _ id: ModelID, _ body: (inout Clip) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        guard let (track, index) = clipLocation(id) else { throw .notFound(kind: "clip", id: id) }
        return try updateTrack(track) { (track: inout Track) throws(DAWError) -> R in
            let result = try body(&track.clips[index])
            track.sortClips()
            return result
        }
    }

    /// Runs `body` on an audio clip in place; a MIDI clip throws `invalidArgument`.
    public mutating func updateAudioClip<R>(
        _ id: ModelID, _ body: (inout AudioClip) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        try updateClip(id) { (clip: inout Clip) throws(DAWError) -> R in
            guard case .audio(var audio) = clip else { throw .invalidArgument("clip \(id) is not an audio clip") }
            defer { clip = .audio(audio) }
            return try body(&audio)
        }
    }

    /// MODEL-031: puts a clip on a track, in order. Checks the clip like any input: its IDs (notes
    /// included) must be unused, its kind must match the track's, its asset must exist.
    mutating func insertClip(_ clip: Clip, into trackID: NodeIDValue) throws(DAWError) {
        guard let track = track(trackID) else { throw .notFound(kind: "track", id: trackID) }
        try checkClipFits(clip, on: track)
        try claimIDs(clip.forEachID)
        try updateTrack(trackID) { track in
            track.clips.append(clip)
            track.sortClips()
        }
    }

    /// The checks a clip must pass on `track`, apart from its IDs.
    func checkClipFits(_ clip: Clip, on track: Track) throws(DAWError) {
        try clip.validate()
        switch clip {
        case .audio(let audio):
            guard track.kind == .audio else {
                throw .invalidArgument("audio clip \(audio.id) can't go on MIDI track \(track.id)")
            }
            guard assetIndex(audio.assetID) != nil else { throw .notFound(kind: "asset", id: audio.assetID) }
        case .midi(let midi):
            guard track.kind == .midi else {
                throw .invalidArgument("MIDI clip \(midi.id) can't go on audio track \(track.id)")
            }
        }
    }

    /// Samples at the session rate between two timeline positions, through the tempo map. An audio
    /// clip whose start moves by this much keeps its audio in place when its source offset moves
    /// by the same amount (AudioClipPlayer: source frame = offset + (sample − tickToSample(start))).
    func samples(from: Tick, to: Tick) -> Int64 {
        tempoMap.tickToSample(to) - tempoMap.tickToSample(from)
    }
}

extension Track {
    /// DW-110: by start, then ID.
    mutating func sortClips() {
        clips.sort(by: Clip.timelineOrder)
    }
}

extension Clip {
    /// DW-110: the order of a track's clips.
    static func timelineOrder(_ a: Clip, _ b: Clip) -> Bool {
        (a.start, a.id) < (b.start, b.id)
    }

    /// The clip's ID and its notes' IDs.
    func forEachID(_ body: (ModelID, String) -> Void) {
        body(id, "clip")
        if case .midi(let midi) = self { for note in midi.notes { body(note.id, "note") } }
    }

    /// Everything about the clip that doesn't depend on its track or the project (MODEL-032).
    func validate() throws(DAWError) {
        guard start.raw >= 0, length.raw > 0 else {
            throw .invariant("clip \(id) has start \(start.raw), length \(length.raw)")
        }
        guard length <= Tick.timelineEnd, start.raw <= Tick.timelineEnd.raw - length.raw else {
            throw .invariant("clip \(id) ends past the end of the timeline")
        }
        switch self {
        case .audio(let audio):
            guard audio.sourceOffsetSamples >= 0, audio.fadeIn.raw >= 0, audio.fadeOut.raw >= 0 else {
                throw .invariant("audio clip \(audio.id) has a negative offset or fade")
            }
            guard audio.sourceOffsetSamples <= AudioClip.maxSourceOffset else {
                throw .invariant("audio clip \(audio.id) has source offset \(audio.sourceOffsetSamples)")
            }
            guard audio.gain.isFinite, (0...AudioClip.maxGain).contains(audio.gain) else {
                throw .invariant("audio clip \(audio.id) gain \(audio.gain) is outside 0…\(AudioClip.maxGain)")
            }
        case .midi(let midi):
            try midi.validateNotes()
        }
    }
}

extension AudioClip {
    /// +12 dB, like a fader (MIX-005).
    public static let maxGain = ChannelStripState.maxGain
    /// 2^48 samples, about 186 years at 48 kHz: far past any file, and small enough that moving
    /// the offset across the whole timeline can't overflow.
    public static let maxSourceOffset: Int64 = 1 << 48
}

extension AssetRef {
    /// MODEL-031/032: what `ImportAsset` accepts and `validate()` checks.
    func validate() throws(DAWError) {
        guard !path.isEmpty else { throw .invariant("asset \(id) has no path") }
        guard channels >= 1 else { throw .invariant("asset \(id) has \(channels) channels") }
        guard originalSampleRate.isFinite, originalSampleRate > 0 else {
            throw .invariant("asset \(id) has sample rate \(originalSampleRate)")
        }
        guard frames >= 0 else { throw .invariant("asset \(id) has \(frames) frames") }
    }
}
