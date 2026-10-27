/// The loop region (TIME-004). It stays in the project while looping is off.
public struct LoopRange: Hashable, Sendable, Codable {
    public var start: Tick
    public var end: Tick
    public var isEnabled: Bool

    public init(start: Tick, end: Tick, isEnabled: Bool = true) {
        self.start = start
        self.end = end
        self.isEnabled = isEnabled
    }
}
