/// TIME-010 (project part, T-026): the project's metronome. GraphDescriptionBuilder always emits
/// one metronome node wired straight into the master node (past the master's inserts and strip,
/// so no track solo or mute and no master fader touches it); these settings only reach its param
/// slots (`ParamLayout.Metronome`), so changing them never rebuilds the graph (MODEL-021).
///
/// Changed with `SetMetronome`, which is persisted and marks the project dirty but doesn't enter
/// undo history (07, docs/autobuild/DECISIONS.md T-026 Q2). An offline export leaves the click
/// out unless it asks for it (`EngineSync.isMetronomeSuppressed`, render.offline
/// `includeMetronome`; T-026 Q1).
public struct MetronomeSettings: Hashable, Sendable {
    /// `Metronome::kMaxLevel` (06, nodes/Metronome.h): +12 dB, the same bound as strip gain.
    public static let maxLevel = ChannelStripState.maxGain
    /// `Metronome::kParamInfo` defaults: a beat click peaks at 0.25 (−12 dBFS)…
    public static let defaultLevel: Float = 0.25
    /// …and a downbeat at twice that (+6 dB).
    public static let defaultAccent: Float = 2

    /// Clicks while playing (the node's `on` switch).
    public var enabled: Bool
    /// Linear amplitude of a beat click, 0…`maxLevel`.
    public var level: Float
    /// Linear gain of the downbeat click over `level`, 0…`maxLevel`.
    public var accent: Float

    /// Off, at the engine's default levels. A project without a `metronome` key decodes to this.
    public init(enabled: Bool = false, level: Float = Self.defaultLevel, accent: Float = Self.defaultAccent) {
        self.enabled = enabled
        self.level = level
        self.accent = accent
    }

    /// The first of `level` and `accent` that isn't finite and in 0…`maxLevel`, as a message.
    static func rangeProblem(level: Float, accent: Float) -> String? {
        for (name, value) in [("level", level), ("accent", accent)] {
            guard value.isFinite, (0...maxLevel).contains(value) else {
                return "metronome \(name) \(value) is outside 0…\(maxLevel)"
            }
        }
        return nil
    }

    /// MODEL-032.
    func validate() throws(DAWError) {
        if let problem = Self.rangeProblem(level: level, accent: accent) { throw .invariant(problem) }
    }
}

extension MetronomeSettings: Codable {
    private enum CodingKeys: String, CodingKey { case enabled, level, accent }

    /// Every field is optional in the file, so a hand-written `{"enabled": true}` keeps the default
    /// levels.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            level: try c.decodeIfPresent(Float.self, forKey: .level) ?? Self.defaultLevel,
            accent: try c.decodeIfPresent(Float.self, forKey: .accent) ?? Self.defaultAccent)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(level, forKey: .level)
        try c.encode(accent, forKey: .accent)
    }
}
