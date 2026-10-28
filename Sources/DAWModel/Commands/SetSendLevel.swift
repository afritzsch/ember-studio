/// MODEL-005: a send's level, linear 0…+12 dB (MIX-007). A param-slot write in the engine, never a
/// rebuild (MODEL-021); fader drags coalesce it in a gesture (MODEL-003).
public struct SetSendLevel: Command {
    public static let type = "SetSendLevel"

    public var sendID: ModelID
    public var level: Float

    public init(sendID: ModelID, level: Float) {
        self.sendID = sendID
        self.level = level
    }

    public var label: String { "Set Send Level" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        try checkSendLevel(level)
        let old = try project.updateSend(sendID) { send in
            defer { send.level = level }
            return send.level
        }
        return SetSendLevel(sendID: sendID, level: old)
    }
}
