/// MODEL-005 (T-056): makes `sampleRate` (44.1/48/88.2/96 kHz, IO-003) the session rate. The tempo
/// map follows, and every session-rate sample quantity is scaled to it, rounded to the nearest
/// sample (DW-126, `Project.changeSessionSampleRate`). The current rate is a no-op.
///
/// A `HistoryExemptCommand` (decided: autobuild, docs/autobuild/DECISIONS.md "T-056 undo"): it is
/// validated, persisted and marks the project dirty, but it never enters undo history, and a
/// `CompositeCommand` refuses it. A rate change re-converts every asset and may restart the
/// device, so ⌘Z bouncing it back would be costly and surprising.
///
/// The engine: `ProjectStore.perform` asks the attached engine first (`EngineSync`), so a rate the
/// device can't run is refused before the document changes. When the engine changes rate by
/// itself (a device fallback, `device.set`, DW-130), the store performs this command with the
/// engine's rate, so the document follows.
public struct SetSessionSampleRate: HistoryExemptCommand {
    public static let type = "SetSessionSampleRate"

    public var sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    public var label: String { "Set Sample Rate" }

    /// The inverse restores the old rate and the exact old sample values (a rescale back could be
    /// a sample off); only callers that apply it themselves use it (the store never records it).
    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        try Self.check(sampleRate)
        let inverse = RestoreSessionSampleRate(of: project)
        try project.changeSessionSampleRate(to: sampleRate)
        return inverse
    }

    static func check(_ rate: Double) throws(DAWError) {
        guard Project.supportedSampleRates.contains(rate) else {
            throw .invalidArgument("session sample rate \(rate) is not one of 44100, 48000, 88200, 96000")
        }
    }
}

/// T-056: `SetSessionSampleRate`'s inverse. Sets the rate (the tempo map follows), scales the
/// sample quantities like `SetSessionSampleRate`, then puts back the exact values it lists, so a
/// change and its inverse restore the project exactly. History-exempt like the command it undoes.
public struct RestoreSessionSampleRate: HistoryExemptCommand {
    public static let type = "RestoreSessionSampleRate"

    /// An audio clip's `sourceOffsetSamples`.
    public struct ClipOffset: Hashable, Sendable, Codable {
        public var clipID: ModelID
        public var sourceOffsetSamples: Int64

        public init(clipID: ModelID, sourceOffsetSamples: Int64) {
            self.clipID = clipID
            self.sourceOffsetSamples = sourceOffsetSamples
        }
    }

    /// The loop of the sampler zone at index `zone` of slot `slotID`.
    public struct ZoneLoop: Hashable, Sendable, Codable {
        public var slotID: NodeIDValue
        public var zone: Int
        public var loopStart: Int64
        public var loopEnd: Int64

        public init(slotID: NodeIDValue, zone: Int, loopStart: Int64, loopEnd: Int64) {
            self.slotID = slotID
            self.zone = zone
            self.loopStart = loopStart
            self.loopEnd = loopEnd
        }
    }

    public var sampleRate: Double
    public var clipOffsets: [ClipOffset]
    public var zoneLoops: [ZoneLoop]

    public init(sampleRate: Double, clipOffsets: [ClipOffset] = [], zoneLoops: [ZoneLoop] = []) {
        self.sampleRate = sampleRate
        self.clipOffsets = clipOffsets
        self.zoneLoops = zoneLoops
    }

    /// `project`'s rate and every session-rate sample value it holds.
    public init(of project: Project) {
        var offsets: [ClipOffset] = []
        for track in project.tracks {
            for case .audio(let clip) in track.clips {
                offsets.append(ClipOffset(clipID: clip.id, sourceOffsetSamples: clip.sourceOffsetSamples))
            }
        }
        var loops: [ZoneLoop] = []
        for slot in project.allDeviceSlots {
            for (i, zone) in slot.zones.enumerated() {
                guard let start = zone.loopStart, let end = zone.loopEnd else { continue }
                loops.append(ZoneLoop(slotID: slot.id, zone: i, loopStart: start, loopEnd: end))
            }
        }
        self.init(sampleRate: project.sessionSampleRate, clipOffsets: offsets, zoneLoops: loops)
    }

    public var label: String { "Set Sample Rate" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        try SetSessionSampleRate.check(sampleRate)
        let inverse = RestoreSessionSampleRate(of: project)
        try project.changeSessionSampleRate(to: sampleRate)
        for entry in clipOffsets {
            guard entry.sourceOffsetSamples >= 0, entry.sourceOffsetSamples <= AudioClip.maxSourceOffset else {
                throw .invalidArgument("clip \(entry.clipID): source offset \(entry.sourceOffsetSamples) is outside 0…2^48")
            }
            try project.setAudioClipOffset(entry.clipID, entry.sourceOffsetSamples)
        }
        for entry in zoneLoops {
            try project.updateDeviceSlot(entry.slotID) { (slot: inout DeviceSlot) throws(DAWError) in
                guard slot.zones.indices.contains(entry.zone), slot.zones[entry.zone].loopStart != nil else {
                    throw .invalidArgument("device slot \(entry.slotID) has no looped zone \(entry.zone)")
                }
                slot.zones[entry.zone].loopStart = entry.loopStart
                slot.zones[entry.zone].loopEnd = entry.loopEnd
                try slot.validate()
            }
        }
        return inverse
    }
}

extension Project {
    fileprivate mutating func setAudioClipOffset(_ clipID: ModelID, _ offset: Int64) throws(DAWError) {
        for t in tracks.indices {
            for c in tracks[t].clips.indices where tracks[t].clips[c].id == clipID {
                guard case .audio(var clip) = tracks[t].clips[c] else {
                    throw .invalidArgument("clip \(clipID) is not an audio clip")
                }
                clip.sourceOffsetSamples = offset
                tracks[t].clips[c] = .audio(clip)
                return
            }
        }
        throw .notFound(kind: "clip", id: clipID)
    }
}
