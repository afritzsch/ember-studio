import Foundation

/// AUTO-008 (T-075): how a lane's normalized value (0…1) relates to the value its param slot
/// holds, the model's mirror of the engine's `ParamMapping` (automation/ParamMapping.h; 11
/// "Contract delta (T-074)" *Mapping*). The recorder uses it to turn a control's value into a
/// lane value (`normalize`) and the controls use it to show a lane's value (`denormalize`).
public struct AutomationMapping: Hashable, Sendable {
    public enum Scale: Hashable, Sendable { case linear, log, db }

    /// The engine's floor for a db range that reaches silence (`ParamMapping::kDbFloor`).
    public static let dbFloor = -60.0

    public var min: Float
    public var max: Float
    public var scale: Scale

    public init(min: Float = 0, max: Float = 1, scale: Scale = .linear) {
        self.min = min
        self.max = max
        self.scale = scale
    }

    public static let identity = AutomationMapping()

    /// Normalized → native, as the engine maps it (clamped to 0…1 first; NaN is 0).
    public func denormalize(_ normalized: Float) -> Float {
        let v = Double(normalized >= 0 ? (normalized <= 1 ? normalized : 1) : 0)
        let lo = Double(min), hi = Double(max)
        switch scale {
        case .log where lo > 0 && hi > 0:
            return Float(lo * pow(hi / lo, v))
        case .db where hi > 0:
            if lo > 0 { return Float(lo * pow(hi / lo, v)) }
            if v <= 0 { return min }
            let top = 20 * log10(hi)
            return Float(pow(10, (Self.dbFloor + v * (top - Self.dbFloor)) / 20))
        default:
            return Float(lo + v * (hi - lo))
        }
    }

    /// Native → normalized, the inverse of `denormalize`, clamped to 0…1. In a db range that
    /// reaches silence, anything at or below silence is 0 and anything quieter than the floor
    /// (−60 dB) is the floor's value just above 0.
    public func normalize(_ native: Float) -> Float {
        guard native.isFinite else { return 0 }
        let x = Double(native), lo = Double(min), hi = Double(max)
        var v: Double
        switch scale {
        case .log where lo > 0 && hi > 0:
            v = x > 0 ? log(x / lo) / log(hi / lo) : 0
        case .db where hi > 0:
            if lo > 0 {
                v = x > 0 ? log(x / lo) / log(hi / lo) : 0
            } else {
                guard x > lo, x > 0 else { return 0 }
                let top = 20 * log10(hi)
                v = Swift.max((20 * log10(x) - Self.dbFloor) / (top - Self.dbFloor), Double(Float.ulpOfOne))
            }
        default:
            v = hi != lo ? (x - lo) / (hi - lo) : 0
        }
        return Float(Swift.min(Swift.max(v, 0), 1))
    }
}

extension Project {
    /// AUTO-008: the mapping a lane on `target` plays through, as GraphBuilder resolves it:
    /// strip gain and send level are db faders reaching silence (0…+12 dB), pan is linear −1…1,
    /// mute 0…1; a built-in device param uses its ParamInfo row from `catalog`; a hosted VST3
    /// param is already normalized; a hosted AU param (whose range the model doesn't know) and a
    /// kind without ParamInfo map 0…1 as is.
    public func automationMapping(for target: ParamTarget, catalog: ParamCatalog = .builtin) -> AutomationMapping {
        switch target {
        case .strip(_, .gain):
            return AutomationMapping(min: 0, max: ChannelStripState.maxGain, scale: .db)
        case .strip(_, .pan):
            return AutomationMapping(min: -1, max: 1, scale: .linear)
        case .strip:
            return .identity
        case .sendLevel:
            return AutomationMapping(min: 0, max: Send.maxLevel, scale: .db)
        case .device(let slotID, let index):
            guard let slot = findDeviceSlot(slotID), case .builtin(let kind) = slot.kind,
                  let info = catalog.info(kind, index) else { return .identity }
            return info.mapping
        }
    }
}
