/// DW-334 (T-112): the session-rate rescale of one value of the document, shared by
/// `Project.changeSessionSampleRate` (the project) and `Command.rescaled(from:to:)` (the undo and
/// redo history). Both use these, so a snapshot in the history and the entity in the project it
/// was taken from are scaled to exactly the same values (`Project.rescaleSamples`).
extension AudioClip {
    /// `sourceOffsetSamples` at `to` Hz.
    public func rescaled(from: Double, to: Double) -> AudioClip {
        var clip = self
        clip.sourceOffsetSamples = Project.rescaleSamples(sourceOffsetSamples, from: from, to: to)
        return clip
    }
}

extension Clip {
    /// An audio clip's offset at `to` Hz; a MIDI clip (ticks only) as it is.
    public func rescaled(from: Double, to: Double) -> Clip {
        guard case .audio(let clip) = self else { return self }
        return .audio(clip.rescaled(from: from, to: to))
    }
}

extension SamplerZone {
    /// The loop (frames of the asset in RAM, at the session rate) at `to` Hz. A loop keeps at least
    /// one frame and stays below 2^48 (DW-126).
    public func rescaled(from: Double, to: Double) -> SamplerZone {
        guard let start = loopStart, let end = loopEnd else { return self }
        var zone = self
        let newStart = min(Project.rescaleSamples(start, from: from, to: to), AudioClip.maxSourceOffset - 1)
        zone.loopStart = newStart
        zone.loopEnd = max(Project.rescaleSamples(end, from: from, to: to), newStart + 1)
        return zone
    }
}

extension DeviceSlot {
    /// The zones at `to` Hz (only a sampler has some).
    public func rescaled(from: Double, to: Double) -> DeviceSlot {
        guard !zones.isEmpty else { return self }
        var slot = self
        slot.zones = zones.map { $0.rescaled(from: from, to: to) }
        return slot
    }
}

extension TakeFolder {
    /// Every audio take's clip at `to` Hz (DW-259).
    public func rescaled(from: Double, to: Double) -> TakeFolder {
        var folder = self
        for k in folder.takes.indices { folder.takes[k].clip = folder.takes[k].clip.rescaled(from: from, to: to) }
        return folder
    }
}

extension Track {
    /// Clips, take folders, the instrument and the inserts at `to` Hz.
    public func rescaled(from: Double, to: Double) -> Track {
        var track = self
        track.clips = clips.map { $0.rescaled(from: from, to: to) }
        track.takeFolders = takeFolders.map { $0.rescaled(from: from, to: to) }
        track.instrument = instrument?.rescaled(from: from, to: to)
        track.inserts = inserts.map { $0.rescaled(from: from, to: to) }
        return track
    }
}

extension Bus {
    /// The inserts at `to` Hz (a bus holds no clips; inserts have no zones today, so this is a
    /// guard for later kinds).
    public func rescaled(from: Double, to: Double) -> Bus {
        var bus = self
        bus.inserts = inserts.map { $0.rescaled(from: from, to: to) }
        return bus
    }
}
