import Foundation
import Synchronization

/// DW-236 (T-075): one row of a node kind's ParamInfo (06, DSP-041) as `EngineProtocol.paramInfoJSON`
/// publishes it: `{"index", "id", "name", "min", "max", "default", "curve", "unit", "automatable"}`,
/// and since T-065 (DW-196) `"steps"` and `"labels"?` (06 "Contract delta (T-065)").
public struct ParamDescriptor: Hashable, Sendable, Codable {
    public enum Curve: String, Hashable, Sendable, Codable { case linear, log, db }

    public var index: Int
    public var id: String
    public var name: String
    public var min: Float
    public var max: Float
    public var `default`: Float
    public var curve: Curve
    public var unit: String
    /// AUTO-008: whether a lane may drive it. A lane on a row that isn't is refused by the
    /// commands that create lanes (DW-236) and left out of the graph by the engine.
    public var automatable: Bool
    /// DW-196 (T-065): steps between `min` and `max` (0 = continuous, 1 = a switch, n = n + 1
    /// values). Rows without it are continuous.
    public var steps: Int = 0
    /// DW-196: `steps + 1` display names in value order, or nil (numbers; Off/On for a switch).
    public var labels: [String]? = nil

    public init(index: Int, id: String, name: String, min: Float, max: Float, default: Float,
                curve: Curve = .linear, unit: String = "", automatable: Bool = true, steps: Int = 0,
                labels: [String]? = nil) {
        self.index = index
        self.id = id
        self.name = name
        self.min = min
        self.max = max
        self.default = `default`
        self.curve = curve
        self.unit = unit
        self.automatable = automatable
        self.steps = Swift.max(steps, 0)
        self.labels = labels
    }

    private enum CodingKeys: String, CodingKey {
        case index, id, name, min, max, `default`, curve, unit, automatable
        case steps, labels  // DW-196 (T-065)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        min = try c.decodeIfPresent(Float.self, forKey: .min) ?? 0
        max = try c.decodeIfPresent(Float.self, forKey: .max) ?? 1
        `default` = try c.decodeIfPresent(Float.self, forKey: .default) ?? 0
        curve = try c.decodeIfPresent(Curve.self, forKey: .curve) ?? .linear
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        // A row without the flag predates it (06): automatable, as the engine treats it.
        automatable = try c.decodeIfPresent(Bool.self, forKey: .automatable) ?? true
        // DW-196 (T-065): rows from engines before T-065 have neither; labels that don't match
        // the steps are dropped (the numbers show instead).
        steps = Swift.max(try c.decodeIfPresent(Int.self, forKey: .steps) ?? 0, 0)
        let labels = try c.decodeIfPresent([String].self, forKey: .labels)
        self.labels = labels?.count == steps + 1 && steps > 0 ? labels : nil
    }

    // MARK: Discrete params (DW-196, T-065)

    /// A param with a fixed set of values (a switch or a menu), not a knob.
    public var isDiscrete: Bool { steps > 0 }
    /// A two-valued param: drawn as a toggle unless it has labels of its own.
    public var isSwitch: Bool { steps == 1 }

    /// The native value of step `k` (0…steps).
    public func value(ofStep k: Int) -> Float {
        guard steps > 0 else { return min }
        let k = Swift.min(Swift.max(k, 0), steps)
        return k == steps ? max : min + (max - min) * Float(k) / Float(steps)
    }

    /// The step nearest to `value` (the engine rounds the same way: the delay's note, a switch at ≥ ½).
    public func step(of value: Float) -> Int {
        guard steps > 0, max > min, value.isFinite else { return 0 }
        let k = ((value - min) / (max - min) * Float(steps)).rounded()
        return Int(Swift.min(Swift.max(k, 0), Float(steps)))
    }

    /// Every value of a discrete param with its display name (`labels`, else "Off"/"On" for a
    /// switch, else the number); empty for a continuous one.
    public var choices: [(value: Float, label: String)] {
        guard steps > 0 else { return [] }
        return (0...steps).map { k in
            let value = value(ofStep: k)
            if let labels { return (value, labels[k]) }
            if steps == 1 { return (value, k == 0 ? "Off" : "On") }
            return (value, ParamDescriptor.number(value))
        }
    }

    /// The display text of `value`: a discrete param's choice, else the number and unit.
    public func display(_ value: Float) -> String {
        if isDiscrete { return choices[step(of: value)].label }
        let number = ParamDescriptor.number(value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    static func number(_ value: Float) -> String {
        let magnitude = abs(value)
        if value == value.rounded() && magnitude < 100_000 { return String(Int(value)) }
        if magnitude >= 100 { return String(format: "%.0f", value) }
        if magnitude >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    /// AUTO-008: this row's normalized ↔ native mapping (the engine's ParamMapping).
    public var mapping: AutomationMapping {
        switch curve {
        case .linear: AutomationMapping(min: min, max: max, scale: .linear)
        case .log: AutomationMapping(min: min, max: max, scale: .log)
        case .db: AutomationMapping(min: min, max: max, scale: .db)
        }
    }
}

extension ParamCatalog {
    /// `[{"index": 0, "min": …, "automatable": true, …}, …]` → rows by index. Malformed JSON gives none.
    static func parseInfos(_ json: String) -> [Int: ParamDescriptor] {
        guard let rows = try? JSONDecoder().decode([ParamDescriptor].self, from: Data(json.utf8)) else { return [:] }
        var out: [Int: ParamDescriptor] = [:]
        for row in rows where row.index >= 0 && row.index < 4096 { out[row.index] = row }
        return out
    }

    /// The ParamInfo row of param `index` of `kind`, if the kind publishes one.
    public func info(_ kind: NodeKind, _ index: Int) -> ParamDescriptor? { infos[kind]?[index] }

    /// DW-236: whether a lane may drive param `index` of `kind`: false only for a published row
    /// that says so. Hosted plugins (AU, VST3) and kinds without ParamInfo are automatable.
    public func isAutomatable(_ kind: NodeKind, _ index: Int) -> Bool {
        info(kind, index)?.automatable ?? true
    }

    // MARK: The built-in catalog (DW-236)

    /// The built-ins' ParamInfo is compiled into the engine (06), the same for every engine of the
    /// process, so the last catalog read from an engine that publishes it stands for all of them.
    /// Commands apply to a `Project` without an engine; they consult this to refuse lanes on
    /// non-automatable built-in params. Empty (everything allowed) until an engine was read.
    public static var builtin: ParamCatalog { builtinStore.withLock { $0 } }

    /// Makes `catalog` the built-in catalog (tests may install one of their own).
    public static func registerBuiltin(_ catalog: ParamCatalog) {
        builtinStore.withLock { $0 = catalog }
    }

    private static let builtinStore = Mutex(ParamCatalog())
}
