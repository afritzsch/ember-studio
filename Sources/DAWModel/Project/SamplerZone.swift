/// DSP-020, DW-140: one key-mapped zone of a built-in sampler. The fields and their JSON names are
/// the sampler's `configJSON` format (06 "Sampler semantics"), so GraphDescriptionBuilder encodes
/// a slot's zones as `{"zones": [...]}` unchanged.
///
/// Only `assetID` is required in JSON; the other fields default to the engine's defaults. Loop
/// points are source frames of the asset, `[loopStart, loopEnd)`, both or neither. The ranges are
/// checked by `validate()` (MODEL-032), the same ones the engine accepts, so a valid project never
/// gives the sampler a config it rejects.
public struct SamplerZone: Hashable, Sendable, Codable {
    public var assetID: ModelID
    public var rootKey: UInt8
    public var lowKey: UInt8
    public var highKey: UInt8
    public var lowVel: UInt8
    public var highVel: UInt8
    /// Semitones, added to the pitch (DSP-021).
    public var tune: Float
    /// Linear, 0…+12 dB.
    public var gain: Float
    public var loopStart: Int64?
    public var loopEnd: Int64?

    public init(
        assetID: ModelID, rootKey: UInt8 = 60, lowKey: UInt8 = 0, highKey: UInt8 = 127, lowVel: UInt8 = 1,
        highVel: UInt8 = 127, tune: Float = 0, gain: Float = 1, loopStart: Int64? = nil, loopEnd: Int64? = nil
    ) {
        self.assetID = assetID
        self.rootKey = rootKey
        self.lowKey = lowKey
        self.highKey = highKey
        self.lowVel = lowVel
        self.highVel = highVel
        self.tune = tune
        self.gain = gain
        self.loopStart = loopStart
        self.loopEnd = loopEnd
    }

    /// ±10 octaves: far past any useful transposition, and keeps the playback rate finite.
    public static let maxTune: Float = 120
    /// +12 dB, like clip gain.
    public static let maxGain = AudioClip.maxGain

    private enum CodingKeys: String, CodingKey {
        case assetID, rootKey, lowKey, highKey, lowVel, highVel, tune, gain, loopStart, loopEnd
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SamplerZone(assetID: 0)
        assetID = try c.decode(ModelID.self, forKey: .assetID)
        rootKey = try c.decodeIfPresent(UInt8.self, forKey: .rootKey) ?? d.rootKey
        lowKey = try c.decodeIfPresent(UInt8.self, forKey: .lowKey) ?? d.lowKey
        highKey = try c.decodeIfPresent(UInt8.self, forKey: .highKey) ?? d.highKey
        lowVel = try c.decodeIfPresent(UInt8.self, forKey: .lowVel) ?? d.lowVel
        highVel = try c.decodeIfPresent(UInt8.self, forKey: .highVel) ?? d.highVel
        tune = try c.decodeIfPresent(Float.self, forKey: .tune) ?? d.tune
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? d.gain
        loopStart = try c.decodeIfPresent(Int64.self, forKey: .loopStart)
        loopEnd = try c.decodeIfPresent(Int64.self, forKey: .loopEnd)
    }

    /// MODEL-031/032: the ranges the sampler accepts (06 "Sampler semantics"), plus a bound on
    /// tune and gain. The asset reference is the project's check (`validateAssets`).
    func validate(slot: NodeIDValue) throws(DAWError) {
        let name = "sampler \(slot) zone of asset \(assetID)"
        guard rootKey <= 127, lowKey <= highKey, highKey <= 127, lowVel >= 1, lowVel <= highVel, highVel <= 127 else {
            throw .invariant("\(name) has keys \(lowKey)…\(highKey) root \(rootKey), velocities \(lowVel)…\(highVel)")
        }
        guard tune.isFinite, abs(tune) <= Self.maxTune else {
            throw .invariant("\(name) tune \(tune) is outside ±\(Self.maxTune)")
        }
        guard gain.isFinite, (0...Self.maxGain).contains(gain) else {
            throw .invariant("\(name) gain \(gain) is outside 0…\(Self.maxGain)")
        }
        switch (loopStart, loopEnd) {
        case (nil, nil):
            break
        case (let start?, let end?) where start >= 0 && start < end && end <= AudioClip.maxSourceOffset:
            break
        default:
            throw .invariant("\(name) loop must be both or neither of 0 ≤ loopStart < loopEnd ≤ 2^48")
        }
    }
}
