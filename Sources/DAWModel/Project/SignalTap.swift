/// Where a send or sidechain picks up its signal on the source channel (MIX-007, MIX-008).
public enum SignalTap: String, Hashable, Sendable, Codable {
    case preFader, postFader
}
