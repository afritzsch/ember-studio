/// TIME-010 (project part, T-026): changes `Project.metronome`. Fields left out keep their value;
/// at least one must be given. Levels are linear 0…+12 dB, like `Metronome::kParamInfo` (06).
///
/// A `HistoryExemptCommand` (07, docs/autobuild/DECISIONS.md T-026 Q2): it is validated, persisted
/// and marks the project dirty, but it doesn't enter undo history, so ⌘Z never toggles the click.
/// Engine sync turns it into param-slot writes on the metronome node, never a rebuild (MODEL-021).
public struct SetMetronome: HistoryExemptCommand {
    public static let type = "SetMetronome"

    public var enabled: Bool?
    public var level: Float?
    public var accent: Float?

    public init(enabled: Bool? = nil, level: Float? = nil, accent: Float? = nil) {
        self.enabled = enabled
        self.level = level
        self.accent = accent
    }

    public var label: String { "Set Metronome" }

    /// The inverse sets every field back; it is only used by callers that apply it themselves
    /// (the store never records it).
    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard enabled != nil || level != nil || accent != nil else {
            throw .invalidArgument("SetMetronome needs at least one of enabled, level, accent")
        }
        let old = project.metronome
        var new = old
        if let enabled { new.enabled = enabled }
        if let level { new.level = level }
        if let accent { new.accent = accent }
        if let problem = MetronomeSettings.rangeProblem(level: new.level, accent: new.accent) {
            throw .invalidArgument(problem)
        }
        project.metronome = new
        return SetMetronome(enabled: old.enabled, level: old.level, accent: old.accent)
    }
}
