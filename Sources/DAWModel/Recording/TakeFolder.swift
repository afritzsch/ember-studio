/// REC-030..034 (T-080): a track's take folder. A loop recording makes one: each loop pass is a
/// `Take`, a clip of its own (audio: a view into the one continuous file of the recording, by
/// `sourceOffsetSamples`; MIDI: the pass's notes), and the comp says which take plays where.
///
/// - `start`/`end` (the folder range) is the union of the takes' clips: a recorded folder runs from
///   the first pass's start (recording may begin before or inside the loop) to the loop end.
/// - REC-031: `comp` is sorted, covers `[start, end)` without gaps or overlaps, names takes of the
///   folder, and never has two adjacent segments of the same take (they merge). The default comp
///   (`defaultComp`) plays, at each position, the latest take that covers it, so a partial last
///   pass plays where it exists and the pass before it after that.
/// - REC-032: the comp is flattened into ordinary clips for the graph (`flattened`,
///   GraphDescriptionBuilder); the takes themselves aren't heard.
/// - Take clips are not the track's clips: clip commands don't find them (T-081 edits them).
///
/// JSON: `{"id", "start", "end", "takes": [{"id", "clip": Clip}], "comp": [{"start", "end", "take"}]}`.
public struct TakeFolder: Identifiable, Hashable, Sendable, Codable {
    public var id: ModelID
    /// The folder range `[start, end)`.
    public var start: Tick
    public var end: Tick
    /// In recording order: a later take is a later pass.
    public var takes: [Take]
    public var comp: [CompSegment]

    public init(id: ModelID, start: Tick, end: Tick, takes: [Take], comp: [CompSegment]) {
        self.id = id
        self.start = start
        self.end = end
        self.takes = takes
        self.comp = comp
    }

    /// A folder of `takes` over their union, with the default comp.
    public init(id: ModelID, takes: [Take]) {
        let start = takes.map(\.clip.start).min() ?? Tick(0)
        let end = takes.map(\.clip.end).max() ?? Tick(0)
        self.init(id: id, start: start, end: end, takes: takes,
                  comp: Self.defaultComp(takes: takes, start: start, end: end))
    }

    public func take(_ id: ModelID) -> Take? { takes.first { $0.id == id } }

    /// REC-031: at each position of `[start, end)`, the latest take whose clip covers it. Where no
    /// take covers it (not the case for a recorded folder), the latest take that started before
    /// it, else the first take.
    public static func defaultComp(takes: [Take], start: Tick, end: Tick) -> [CompSegment] {
        guard start < end, let first = takes.first else { return [] }
        var cuts = Set([start.raw, end.raw])
        for take in takes {
            for t in [take.clip.start.raw, take.clip.end.raw] where t > start.raw && t < end.raw { cuts.insert(t) }
        }
        let sorted = cuts.sorted()
        var comp: [CompSegment] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let covering = takes.last { $0.clip.start.raw <= a && $0.clip.end.raw >= b }
            let take = covering ?? takes.last { $0.clip.start.raw <= a } ?? first
            comp.append(CompSegment(start: Tick(a), end: Tick(b), take: take.id))
        }
        return merged(comp)
    }

    /// REC-033: the comp with `[from, to)` played by `take`: segments are cut at `from` and `to`,
    /// the range is replaced, and neighbours of the same take merge. The range must lie inside the
    /// folder (callers check).
    public func comp(selecting take: ModelID, from: Tick, to: Tick) -> [CompSegment] {
        var out: [CompSegment] = []
        for segment in comp where segment.start < from {
            out.append(CompSegment(start: segment.start, end: min(segment.end, from), take: segment.take))
        }
        out.append(CompSegment(start: from, end: to, take: take))
        for segment in comp where segment.end > to {
            out.append(CompSegment(start: max(segment.start, to), end: segment.end, take: segment.take))
        }
        return Self.merged(out)
    }

    /// Adjacent segments of the same take become one.
    static func merged(_ comp: [CompSegment]) -> [CompSegment] {
        var out: [CompSegment] = []
        for segment in comp where segment.end > segment.start {
            if let last = out.last, last.take == segment.take, last.end == segment.start {
                out[out.count - 1].end = segment.end
            } else {
                out.append(segment)
            }
        }
        return out
    }

    /// REC-032: what the comp plays, segment by segment: the take's clip, cut to the segment. An
    /// audio clip keeps its audio in place (its offset moves with its start, through `tempo`); a
    /// MIDI clip keeps its notes (starts relative to the cut clip). A segment whose take doesn't
    /// cover all of it plays only the part the take covers.
    ///
    /// Crossfades (audio, `crossfadeSamples` > 0). DSP-002 crossfades only where a later clip starts
    /// over an earlier one, so at each boundary b the two audio clips overlap by up to
    /// `crossfadeSamples`: the earlier segment's clip runs on past b if its take has audio there
    /// (the file runs on; never past the next segment's end); otherwise the next segment's clip
    /// starts that much before b if its take has audio there (never at or before the earlier
    /// segment's start). The later clip wins, so the boundary fades over the overlap with DSP-002's
    /// equal-power curve. Where neither take has audio across b the cut is hard.
    public func flattened(tempo: TempoMap, crossfadeSamples: Int64 = 0) -> [Clip] {
        var ranges = comp.map { (start: $0.start.raw, end: $0.end.raw) }
        if crossfadeSamples > 0 {
            for k in comp.indices.dropLast() {
                guard let earlier = take(comp[k].take)?.clip, let later = take(comp[k + 1].take)?.clip,
                      case .audio = earlier, case .audio = later else { continue }
                let b = comp[k].end.raw
                let bSample = tempo.tickToSample(comp[k].end)
                let after = tempo.sampleToTick(bSample + crossfadeSamples - 1).raw + 1  // ≥ crossfade past b
                let forward = min(after, comp[k + 1].end.raw, earlier.end.raw)
                if forward > b {
                    ranges[k].end = forward
                    continue
                }
                let before = tempo.sampleToTick(bSample - crossfadeSamples).raw  // ≥ crossfade before b
                let back = max(before, comp[k].start.raw + 1, later.start.raw)
                if back < b { ranges[k + 1].start = back }
            }
        }
        var out: [Clip] = []
        for (segment, range) in zip(comp, ranges) {
            guard let take = take(segment.take) else { continue }
            let from = Tick(max(range.start, take.clip.start.raw))
            let until = Tick(min(range.end, take.clip.end.raw))
            guard until > from else { continue }
            switch take.clip {
            case .audio(var clip):
                clip.sourceOffsetSamples += tempo.tickToSample(from) - tempo.tickToSample(clip.start)
                clip.start = from
                clip.length = Tick(until.raw - from.raw)
                // Fades belong to the whole take; a cut keeps only the ones at its own ends.
                if from > take.clip.start { clip.fadeIn = 0 }
                if until < take.clip.end { clip.fadeOut = 0 }
                clip.fadeIn = Tick(min(clip.fadeIn.raw, clip.length.raw))
                clip.fadeOut = Tick(min(clip.fadeOut.raw, clip.length.raw))
                out.append(.audio(clip))
            case .midi(var clip):
                // MIDI comps don't overlap: notes of the segment's take only.
                let from = max(segment.start, take.clip.start), until = min(segment.end, take.clip.end)
                guard until > from else { continue }
                let shift = from.raw - clip.start.raw
                clip.notes = clip.notes.map { note in
                    var note = note
                    note.start = Tick(note.start.raw - shift)
                    return note
                }
                clip.start = from
                clip.length = Tick(until.raw - from.raw)
                out.append(.midi(clip))
            }
        }
        return out
    }
}

/// REC-030: one pass of a loop recording.
public struct Take: Identifiable, Hashable, Sendable, Codable {
    public var id: ModelID
    /// Where the pass lies on the timeline and what it holds. Its ID is its own (not a track clip).
    public var clip: Clip

    public init(id: ModelID, clip: Clip) {
        self.id = id
        self.clip = clip
    }
}

/// REC-031: `[start, end)` of the folder plays `take`.
public struct CompSegment: Hashable, Sendable, Codable {
    public var start: Tick
    public var end: Tick
    public var take: ModelID

    public init(start: Tick, end: Tick, take: ModelID) {
        self.start = start
        self.end = end
        self.take = take
    }
}

extension Clip {
    /// The first tick after the clip.
    public var end: Tick { Tick(start.raw + length.raw) }
}

// MARK: Validation (MODEL-032)

extension TakeFolder {
    /// The folder's, its takes' and their clips' (and notes') IDs.
    func forEachID(_ body: (ModelID, String) -> Void) {
        body(id, "take folder")
        for take in takes {
            body(take.id, "take")
            take.clip.forEachID(body)
        }
    }

    /// Everything about the folder that doesn't depend on the rest of the project: the range, the
    /// takes' clips (of the track's kind) and the comp (REC-031).
    func validate(on kind: Track.Kind) throws(DAWError) {
        guard start.raw >= 0, end > start, end <= Tick.timelineEnd else {
            throw .invariant("take folder \(id) has range [\(start.raw), \(end.raw))")
        }
        guard !takes.isEmpty else { throw .invariant("take folder \(id) has no takes") }
        var takeIDs = Set<ModelID>()
        for take in takes {
            guard takeIDs.insert(take.id).inserted else { throw .invariant("take \(take.id) is in folder \(id) twice") }
            try take.clip.validate()
            switch (take.clip, kind) {
            case (.audio, .audio), (.midi, .midi): break
            default: throw .invariant("take \(take.id) of folder \(id) doesn't match its track's kind")
            }
        }
        guard let first = comp.first, let last = comp.last, first.start == start, last.end == end else {
            throw .invariant("the comp of take folder \(id) doesn't cover [\(start.raw), \(end.raw))")
        }
        for (i, segment) in comp.enumerated() {
            guard segment.end > segment.start else { throw .invariant("take folder \(id) has an empty comp segment") }
            guard takeIDs.contains(segment.take) else {
                throw .invariant("a comp segment of folder \(id) names take \(segment.take), which isn't in it")
            }
            if i > 0 {
                guard comp[i - 1].end == segment.start else {
                    throw .invariant("the comp of take folder \(id) has a gap or overlap at \(segment.start.raw)")
                }
                guard comp[i - 1].take != segment.take else {
                    throw .invariant("the comp of take folder \(id) has two adjacent segments of take \(segment.take)")
                }
            }
        }
    }
}

extension Project {
    /// T-080: every folder fits its track and its audio takes' assets exist (like clips, T-030).
    func validateTakeFolders() throws(DAWError) {
        let assetIDs = Set(assets.map(\.id))
        for track in tracks {
            for folder in track.takeFolders {
                try folder.validate(on: track.kind)
                for take in folder.takes {
                    if case .audio(let clip) = take.clip, !assetIDs.contains(clip.assetID) {
                        throw .invariant("take \(take.id) uses missing asset \(clip.assetID)")
                    }
                }
            }
        }
    }

    /// The track holding the folder, and the folder's index in it.
    public func takeFolderLocation(_ id: ModelID) -> (track: NodeIDValue, index: Int)? {
        for track in tracks {
            if let index = track.takeFolders.firstIndex(where: { $0.id == id }) { return (track.id, index) }
        }
        return nil
    }

    public func takeFolder(_ id: ModelID) -> TakeFolder? {
        takeFolderLocation(id).flatMap { track($0.track)?.takeFolders[$0.index] }
    }

    /// Runs `body` on the folder in place, or throws `notFound` (MODEL-031).
    mutating func updateTakeFolder<R>(
        _ id: ModelID, _ body: (inout TakeFolder) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        guard let (track, index) = takeFolderLocation(id) else { throw .notFound(kind: "take folder", id: id) }
        return try updateTrack(track) { (track: inout Track) throws(DAWError) -> R in
            try body(&track.takeFolders[index])
        }
    }

    /// Whether any take of any folder uses the asset.
    public func takesUse(asset: ModelID) -> Bool {
        tracks.contains { $0.takeFoldersUse(asset: asset) }
    }
}

extension Track {
    /// Whether a take of one of the track's folders uses the asset (T-080).
    public func takeFoldersUse(asset: ModelID) -> Bool {
        takeFolders.contains { folder in
            folder.takes.contains { if case .audio(let clip) = $0.clip { clip.assetID == asset } else { false } }
        }
    }
}
