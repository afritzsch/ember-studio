import Foundation
import Testing

@testable import DAWModel

// T-061: what the model sends the engine for an AU slot. The node's configJSON carries the
// identifier and the stored state (PLUG-010/016, 08/10 Contract delta (T-061)); a param without a
// stored value is NaN, "not set" (PLUG-015), and EngineSync writes it once, not on every sync.

@Suite("AU slots in the engine graph (PLUG-010, 015, 016)")
@MainActor
struct AUSlotModelTests {
    init() { TestCommands.register() }

    let p = ClipProject.make()
    static let sampler = DeviceSlot.Kind.au(AUDescriptor(identifier: "aumu:samp:appl", name: "AUSampler"))

    func withAU() throws -> Project {
        var q = p
        _ = try SetInstrument(trackID: p.keys.id, device: Self.sampler).applyChecked(to: &q)
        return q
    }

    @Test("PLUG-010/016: an AU slot is an auPlugin node whose configJSON has its identifier and base64 state")
    func configJSON() throws {
        var q = try withAU()
        let slot = try #require(q.keys.instrument?.id)
        var node = try #require(GraphDescriptionBuilder.build(q, runtime: RuntimeIDs()).nodes.first { $0.id == slot })
        #expect(node.kind == .auPlugin)
        #expect(node.configJSON == #"{"identifier":"aumu:samp:appl"}"#)

        q.tracks[1].instrument?.pluginState = Data([1, 2, 3])
        #expect(q.keys.instrument?.pluginState == Data([1, 2, 3]))
        node = try #require(GraphDescriptionBuilder.build(q, runtime: RuntimeIDs()).nodes.first { $0.id == slot })
        #expect(node.configJSON == #"{"identifier":"aumu:samp:appl","state":"AQID"}"#)
    }

    @Test("PLUG-015: an AU param without a stored value is NaN; EngineSync writes it once and never again")
    func notSetParams() async throws {
        var q = try withAU()
        let slot = try #require(q.keys.instrument?.id)
        _ = try SetParam(target: .device(slot: slot, index: 2), value: 0.5).applyChecked(to: &q)
        #expect(ParamCatalog().defaultValue(for: try #require(q.keys.instrument), 0).isNaN)
        #expect(ParamCatalog().defaultValue(for: DeviceSlot(id: 1, kind: .builtin(.eq)), 0) == 0)

        let store = ProjectStore(project: q)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        let ids = try (UInt32(0)..<3).map { try #require(sync.runtime.deviceParam(slot, $0)) }
        var written: [ParamID: Float] = [:]
        for case .setParam(let id, let value) in engine.calls { written[id] = value }
        #expect(written[ids[0]]?.isNaN == true && written[ids[1]]?.isNaN == true)
        #expect(written[ids[2]] == 0.5)

        engine.clearCalls()
        try store.edit { $0.tracks[0].strip.gain = 0.25 }
        sync.flush()
        try await Task.sleep(for: .milliseconds(40))
        let rewrites = engine.calls.filter { if case .setParam(let id, _) = $0 { ids.contains(id) } else { false } }
        #expect(rewrites.isEmpty, "NaN compares unequal to itself; the bit pattern doesn't")
        #expect(engine.calls.contains { if case .setParam = $0 { true } else { false } }, "the strip gain was written")
    }
}
