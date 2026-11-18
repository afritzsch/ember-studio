import Foundation
import PluginCatalog

// T-098 (DW-016): stand-ins for PLUG-001..004's discovery and scanner, so plugins.* tests never
// depend on the plugins installed on this machine. This file imports PluginCatalog without
// DAWModel (both name a `PluginDescriptor`).

/// Candidates by name: VST3 bundles at `/fake/<name>.vst3`.
struct FakePluginDiscovery: PluginDiscovering {
    var names: [String]

    func candidates() -> [PluginCandidate] {
        names.map { PluginCandidate(format: .vst3, path: "/fake/\($0).vst3", mtime: 1, version: "1", name: $0) }
    }
}

/// Scans: a name in `crashing` is blocked as crashed, in `hanging` as timed out after the limit it
/// was given; others are usable. Records each scan's limit (nil: the scanner's own).
final class FakePluginScanner: PluginScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var _scans: [(name: String, timeout: TimeInterval?)] = []
    private var _crashing: Set<String>
    private var _hanging: Set<String>

    init(crashing: Set<String> = [], hanging: Set<String> = []) {
        _crashing = crashing
        _hanging = hanging
    }

    var scans: [(name: String, timeout: TimeInterval?)] { lock.withLock { _scans } }

    /// Lets a plugin scan cleanly from now on (it was fixed).
    func heal(_ name: String) {
        lock.withLock {
            _crashing.remove(name)
            _hanging.remove(name)
        }
    }

    func scan(_ candidate: PluginCandidate) throws(PluginCatalogError) -> [PluginDescriptor] {
        result(candidate, timeout: nil)
    }

    func scan(_ candidate: PluginCandidate, timeout: TimeInterval) throws(PluginCatalogError) -> [PluginDescriptor] {
        result(candidate, timeout: timeout)
    }

    private func result(_ candidate: PluginCandidate, timeout: TimeInterval?) -> [PluginDescriptor] {
        let (crash, hang) = lock.withLock { () -> (Bool, Bool) in
            _scans.append((candidate.name, timeout))
            return (_crashing.contains(candidate.name), _hanging.contains(candidate.name))
        }
        if crash { return [.blocked(candidate, reason: "scanner crashed (SIGSEGV)")] }
        if hang { return [.timedOut(candidate, after: timeout ?? 30)] }
        return [PluginDescriptor(format: .vst3, identifier: candidate.path + "#00", name: candidate.name, vendor: "Fake",
                                 version: "1", isInstrument: candidate.name.hasPrefix("Synth"), hasSidechain: false, numParams: 2)]
    }
}

/// A `CatalogPluginControl` over the fakes, its cache in `folder`.
func fakePluginControl(in folder: URL, names: [String], scanner: FakePluginScanner) -> CatalogPluginControlBox {
    CatalogPluginControlBox(cacheURL: folder.appending(path: "plugins.json"),
                            discovery: FakePluginDiscovery(names: names), scanner: scanner)
}

/// Carries the fakes to the test files that import DAWControl (and DAWModel).
struct CatalogPluginControlBox: Sendable {
    let cacheURL: URL
    let discovery: any PluginDiscovering
    let scanner: any PluginScanning
}
