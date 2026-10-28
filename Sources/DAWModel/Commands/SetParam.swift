/// MODEL-005, DW-094: sets one parameter of the document: a strip control (gain, pan, mute, solo,
/// phase), a send level, or a device param. Never structural: engine sync turns it into
/// `setParam` writes, with solo and mute resolved into mute slots (MODEL-021, MIX-006). Continuous
/// edits coalesce in a gesture (MODEL-003).
///
/// Values: gain and send level are linear 0…+12 dB, pan −1…1, switches are on at ≥ 0.5 (the inverse
/// carries 0 or 1). Device params are stored as given, finite. A nil `value` is only for device
/// params: it removes the stored value, so the param falls back to its kind's default.
public struct SetParam: Command {
    public static let type = "SetParam"

    public var target: ParamTarget
    public var value: Float?

    public init(target: ParamTarget, value: Float?) {
        self.target = target
        self.value = value
    }

    public var label: String {
        switch target {
        case .strip(_, .gain): "Set Gain"
        case .strip(_, .pan): "Set Pan"
        case .strip(_, .mute): "Set Mute"
        case .strip(_, .solo): "Set Solo"
        case .strip(_, .phase): "Set Phase Invert"
        case .sendLevel: "Set Send Level"
        case .device: "Set Parameter"
        }
    }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        switch target {
        case .strip(let channel, let param):
            guard let value else { throw .invalidArgument("\(param.rawValue) needs a value") }
            return SetParam(target: target, value: try setStrip(param, of: channel, to: value, in: &project))
        case .sendLevel(let send):
            guard let value else { throw .invalidArgument("a send level needs a value") }
            try checkSendLevel(value)
            let old = try project.updateSend(send) { send in
                defer { send.level = value }
                return send.level
            }
            return SetParam(target: target, value: old)
        case .device(let slot, let index):
            guard (0...DeviceSlot.maxParamIndex).contains(index) else {
                throw .invalidArgument("param index \(index) is outside 0…\(DeviceSlot.maxParamIndex)")
            }
            if let value, !value.isFinite { throw .invalidArgument("param value \(value) is not finite") }
            let old = try project.updateDeviceSlot(slot) { slot in
                let at = slot.params.firstIndex { $0.index >= index }
                let old = at.flatMap { slot.params[$0].index == index ? slot.params[$0].value : nil }
                if old != nil { slot.params.remove(at: at!) }
                // Kept sorted by index, so equal settings are equal projects.
                if let value { slot.params.insert(ParamValue(index: index, value: value), at: at ?? slot.params.endIndex) }
                return old
            }
            return SetParam(target: target, value: old)
        }
    }

    /// Returns the old value.
    private func setStrip(
        _ param: ParamTarget.StripParam, of channel: NodeIDValue, to value: Float, in project: inout Project
    ) throws(DAWError) -> Float {
        guard value.isFinite else { throw .invalidArgument("\(param.rawValue) \(value) is not finite") }
        switch param {
        case .gain:
            guard (0...ChannelStripState.maxGain).contains(value) else {
                throw .invalidArgument("gain \(value) is outside 0…\(ChannelStripState.maxGain)")
            }
        case .pan:
            guard (-1...1).contains(value) else { throw .invalidArgument("pan \(value) is outside −1…1") }
        case .solo:
            // MIX-006: solo never mutes the master, and the master can't be soloed.
            if channel == project.master.id { throw .invalidArgument("the master has no solo") }
        case .mute, .phase:
            break
        }
        let on = value >= 0.5
        return try project.updateStrip(of: channel) { strip in
            switch param {
            case .gain: defer { strip.gain = value }; return strip.gain
            case .pan: defer { strip.pan = value }; return strip.pan
            case .mute: defer { strip.mute = on }; return strip.mute ? 1 : 0
            case .solo: defer { strip.solo = on }; return strip.solo ? 1 : 0
            case .phase: defer { strip.phaseInvert = on }; return strip.phaseInvert ? 1 : 0
            }
        }
    }
}
