import Foundation
import Testing

@testable import DAWModel

// T-102 model follow-ups (docs/autobuild/DECISIONS.md "T-102 model shapes"; 07 "Contract delta
// (T-102)"): plugin descriptors without `vendor`/`version` (DW-296), `RenameBus`/`MoveBus` (DW-113)
// and `SetParam`'s cap at a built-in kind's published params (DW-112). MODEL-005, MODEL-006,
// MODEL-031.

@Suite("Model follow-ups (T-102)")
@MainActor
struct ModelFollowup3Tests {
    init() { TestCommands.register() }

    let p = RoutingProject.make()

    // MARK: DW-296

    @Test("DW-296, MODEL-006: InsertDevice decodes an AU or VST3 descriptor without vendor/version as \"\"; the full form is unchanged")
    func descriptorWithoutVendorOrVersion() throws {
        let au = #"{"type":"InsertDevice","channel":\#(p.a.id),"device":{"format":"au","identifier":"aufx:dely:appl","name":"AUDelay"}}"#
        let decoded = try #require(try CommandRegistry.decode(Data(au.utf8)) as? InsertDevice)
        #expect(decoded.device == .au(AUDescriptor(identifier: "aufx:dely:appl", name: "AUDelay", vendor: "", version: "")))
        let applied = try expectApplyRoundTrip(decoded, on: p)
        #expect(applied.a.inserts.map(\.kind) == [decoded.device])

        let vst3 = #"{"type":"InsertDevice","channel":\#(p.a.id),"device":{"format":"vst3","identifier":"/x.vst3#00","name":"X","vendor":"V"}}"#
        let decodedVST3 = try #require(try CommandRegistry.decode(Data(vst3.utf8)) as? InsertDevice)
        #expect(decodedVST3.device == .vst3(VST3Descriptor(identifier: "/x.vst3#00", name: "X", vendor: "V", version: "")))

        // Encoding still writes both keys, so files and wire forms stay byte-identical.
        let full = DeviceSlot.Kind.au(AUDescriptor(identifier: "aufx:dely:appl", name: "AUDelay", vendor: "Apple", version: "1.0"))
        let json = try JSONEncoder().encode(full)
        #expect(String(decoding: json, as: UTF8.self).contains(#""vendor":"Apple""#))
        #expect(try JSONDecoder().decode(DeviceSlot.Kind.self, from: json) == full)
        // identifier and name stay required.
        let nameless = #"{"type":"InsertDevice","channel":\#(p.a.id),"device":{"format":"au","identifier":"aufx:dely:appl"}}"#
        #expect(throws: DAWError.self) { _ = try CommandRegistry.decode(Data(nameless.utf8)) }
    }

    // MARK: DW-113

    @Test("DW-113, MODEL-005: RenameBus and MoveBus round-trip and survive JSON; unknown bus and bad index throw like the track commands")
    func busCommands() throws {
        let renamed = try expectApplyRoundTrip(RenameBus(busID: p.b.id, name: "Verb"), on: p)
        #expect(renamed.buses.map(\.name) == ["A", "Verb"])
        let moved = try expectApplyRoundTrip(MoveBus(busID: p.a.id, index: 1), on: p)
        #expect(moved.buses.map(\.name) == ["B", "A"])
        #expect(moved.a.id == p.b.id && moved.b.id == p.a.id)
        #expect(RenameBus(busID: 1, name: "x").label == "Rename Bus" && MoveBus(busID: 1, index: 0).label == "Move Bus")

        let missing: NodeIDValue = 999
        let cases: [(any Command, DAWError)] = [
            (RenameBus(busID: missing, name: "x"), .notFound(kind: "bus", id: missing)),
            (RenameBus(busID: p.vox.id, name: "x"), .notFound(kind: "bus", id: p.vox.id)),
            (MoveBus(busID: missing, index: 0), .notFound(kind: "bus", id: missing)),
            (MoveBus(busID: p.a.id, index: 2), .invalidArgument("bus index 2 is outside 0…1")),
            (MoveBus(busID: p.a.id, index: -1), .invalidArgument("bus index -1 is outside 0…1")),
        ]
        for (command, error) in cases {
            var q = p
            #expect(throws: error) { _ = try command.apply(to: &q) }
            #expect(q == p)
        }

        // Wire form (MODEL-006).
        let rename = try #require(try CommandRegistry.decode(Data(#"{"type":"RenameBus","busID":\#(p.a.id),"name":"Drums"}"#.utf8)) as? RenameBus)
        #expect(rename.busID == p.a.id && rename.name == "Drums")
        #expect(String(decoding: try CommandRegistry.encode(MoveBus(busID: 3, index: 1)), as: UTF8.self)
            == #"{"busID":3,"index":1,"type":"MoveBus"}"#)
    }

    @Test("DW-113, MODEL-002: RenameBus and MoveBus are one undo entry each through ProjectStore")
    func busCommandsUndo() throws {
        let store = ProjectStore(project: p)
        try store.perform(RenameBus(busID: p.a.id, name: "Drums"))
        try store.perform(MoveBus(busID: p.a.id, index: 1))
        #expect(store.project.buses.map(\.name) == ["B", "Drums"])
        store.undo()
        #expect(store.project.buses.map(\.name) == ["Drums", "B"])
        store.undo()
        #expect(store.project == p && !store.canUndo)
        store.redo()
        store.redo()
        #expect(store.project.buses.map(\.name) == ["B", "Drums"])
    }

    // MARK: DW-112

    @Test("DW-112, MODEL-031: SetParam refuses an index past a built-in kind's published params; plugins and kinds without ParamInfo are unchanged")
    func paramIndexCap() throws {
        // The real engine's ParamInfo becomes ParamCatalog.builtin (DW-236): compressor 7 params.
        let catalog = ParamCatalog(engine: try EngineClient(.offline()))
        #expect(catalog.defaults[.compressor]?.count == 7 && catalog.defaults[.gain]?.count == 2)
        #expect(ParamCatalog.builtin.defaults[.compressor]?.count == 7)

        let comp = p.vox.inserts[0].id
        _ = try expectApplyRoundTrip(SetParam(target: .device(slot: comp, index: 6), value: 0.5), on: p)
        for value in [Float(0.5), nil] {
            var q = p
            #expect(throws: DAWError.invalidArgument("compressor has params 0…6; index 7 is not one")) {
                _ = try SetParam(target: .device(slot: comp, index: 7), value: value).apply(to: &q)
            }
            #expect(q == p)
        }
        var q = p
        #expect(throws: DAWError.invalidArgument("eq has params 0…21; index 22 is not one")) {
            _ = try SetParam(target: .device(slot: p.master.inserts[0].id, index: 22), value: 1).apply(to: &q)
        }

        // A hosted plugin keeps any index up to DeviceSlot.maxParamIndex.
        var withAU = p
        _ = try InsertDevice(channel: p.a.id, device: .au(AUDescriptor(identifier: "aufx:dely:appl", name: "AUDelay"))).apply(to: &withAU)
        _ = try expectApplyRoundTrip(SetParam(target: .device(slot: withAU.a.inserts[0].id, index: 300), value: 0.5), on: withAU)

        // A kind without published ParamInfo (an engine that publishes none, e.g. FakeEngine) is taken as before.
        let slot = p.vox.inserts[0]
        try SetParam.checkPublishedIndex(300, of: slot, catalog: ParamCatalog())
        #expect(throws: DAWError.self) { try SetParam.checkPublishedIndex(7, of: slot, catalog: catalog) }
        try SetParam.checkPublishedIndex(6, of: slot, catalog: catalog)
    }
}
