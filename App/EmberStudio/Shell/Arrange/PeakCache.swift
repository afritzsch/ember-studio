import DAWModel
import Foundation

/// UI-011: peak levels fetched from the engine (IO-034), kept until the asset reloads. A miss (not
/// loaded yet) is remembered too, so drawing doesn't ask the engine every frame; the next
/// `assetLoaded` event clears it.
@MainActor
final class PeakCache {
    private struct Key: Hashable {
        var assetID: ModelID
        var level: Int
    }

    private var levels: [Key: PeakLevel?] = [:]

    func level(_ assetID: ModelID, level: Int, engine: (any EngineProtocol)?) -> PeakLevel? {
        let key = Key(assetID: assetID, level: level)
        if let cached = levels[key] { return cached }
        guard let engine else { return nil }
        let fetched = engine.peaks(assetID, level: level)
        levels[key] = .some(fetched)
        return fetched
    }

    /// Drops what is cached for `assets` (nil: everything) and every miss.
    func invalidate(_ assets: Set<ModelID>?) {
        levels = levels.filter { key, value in
            value != nil && !(assets?.contains(key.assetID) ?? true)
        }
    }

    var count: Int { levels.count }
}
