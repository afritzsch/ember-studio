import Foundation
import Synchronization

/// DW-236 (T-075): one row of a node kind's ParamInfo (06, DSP-041) as `EngineProtocol.paramInfoJSON`
/// publishes it: `{"index", "id", "name", "min", "max", "default", "curve", "unit", "automatable"}`.
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

    public init(index: Int, id: String, name: String, min: Float, max: Float, default: Float,
                curve: Curve = .linear, unit: String = "", automatable: Bool = true) {
        self.index = index
        self.id = id
        self.name = name
        self.min = min
        self.max = max
        self.default = `default`
        self.curve = curve
        self.unit = unit
        self.automatable = automatable
    }

    private enum CodingKeys: String, CodingKey { case index, id, name, min, max, `default`, curve, unit, automatable }

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
