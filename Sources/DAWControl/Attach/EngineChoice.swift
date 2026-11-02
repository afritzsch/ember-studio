import DAWModel

/// `--engine` of the app and `dawctl serve`, and `daw_session_mode {engine}` (CTL-023): the engine a
/// project gets when `project.new`/`project.open` don't ask for a mode.
public enum EngineChoice: String, CaseIterable, Sendable, Codable {
    /// Realtime on the fake device driver (DW-089): transport, meters and device events work without
    /// a sound card, so parallel worktrees don't fight over one. Attach mode's default.
    case fake
    /// Realtime on the real CoreAudio device. The app's default when a person starts it.
    case coreAudio
    /// Offline only, as headless `dawctl`/`dawmcp`.
    case offline

    /// The `Dispatcher.Configuration.makeEngine` for this choice.
    @MainActor public var factory: Dispatcher.EngineFactory {
        switch self {
        case .offline:
            return { rate throws(DAWError) in try EngineClient(.offline(sampleRate: rate)) }
        case .fake, .coreAudio:
            let driver: DeviceDriverKind = self == .fake ? .fake : .coreAudio
            return { rate throws(DAWError) in
                try EngineClient(.realtime(DriverConfig(sampleRate: rate, bufferFrames: 256, driver: driver)))
            }
        }
    }

    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }
}
