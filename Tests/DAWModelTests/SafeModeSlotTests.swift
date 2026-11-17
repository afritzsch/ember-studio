import Foundation
import Testing

@testable import DAWModel

// T-083 (DW-224, docs/autobuild/DECISIONS.md "T-083 safe mode slots"): in safe mode (PLUG-021) the
// graph builds AU/VST3 slots as absent, so their plugins are never instantiated; the document's
// slots, params and state blobs stay untouched and saving keeps the stored state exactly. The
// engine half (the hosts never instantiate a disabled slot) is in DAWEngineTests (AUPluginTests,
// VST3PluginTests "safe mode").

@MainActor
private func safeModeProject() -> (Project, au: ModelID, vst3: ModelID, eq: ModelID, instrument: ModelID) {
    var p = Project(name: "safe")
    let audio = p.ids.allocate()
    let au = p.ids.allocate()
    let eq = p.ids.allocate()
    let midi = p.ids.allocate()
    let instrument = p.ids.allocate()
    let vst3 = p.ids.allocate()
    p.tracks = [
        Track(id: audio, name: "Audio", kind: .audio,
              inserts: [DeviceSlot(id: au, kind: .au(AUDescriptor(identifier: "aufx:dely:appl", name: "AUDelay")),
                                   params: [ParamValue(index: 0, value: 0.5)], pluginState: Data([1, 2, 3])),
                        DeviceSlot(id: eq, kind: .builtin(.eq))]),
        Track(id: midi, name: "Keys", kind: .midi,
              instrument: DeviceSlot(id: instrument, kind: .au(AUDescriptor(identifier: "aumu:samp:appl", name: "AUSampler")))),
    ]
    // A VST3 whose bundle doesn't exist: loading it fails (pluginCrashed), so an attempt shows.
    p.master.inserts = [DeviceSlot(id: vst3, kind: .vst3(VST3Descriptor(
        identifier: "/nonexistent/Ember Missing.vst3#84E8DE5F92554F5396FAE4133C935A18", name: "Missing")))]
    return (p, au, vst3, eq, instrument)
}

@Suite("Safe mode builds plugin slots without their plugin (DW-224, PLUG-021)")
@MainActor
struct SafeModeSlotTests {
    private func node(_ graph: EngineGraph, _ id: ModelID) -> EngineGraph.Node? { graph.nodes.first { $0.id == id } }

    @Test("DW-224: build(pluginsDisabled:) marks AU/VST3 configs disabled, keeping identifier and state; built-ins unchanged")
    func disabledConfigJSON() throws {
        let (p, au, vst3, eq, instrument) = safeModeProject()
        let normal = GraphDescriptionBuilder.build(p, runtime: RuntimeIDs())
        let safe = GraphDescriptionBuilder.build(p, runtime: RuntimeIDs(), pluginsDisabled: true)
        #expect(try #require(node(normal, au)).configJSON == #"{"identifier":"aufx:dely:appl","state":"AQID"}"#)
        #expect(try #require(node(safe, au)).configJSON == #"{"disabled":true,"identifier":"aufx:dely:appl","state":"AQID"}"#)
        #expect(try #require(node(safe, instrument)).configJSON == #"{"disabled":true,"identifier":"aumu:samp:appl"}"#)
        #expect(try #require(node(safe, vst3)).configJSON.hasPrefix(#"{"disabled":true,"identifier":"/nonexistent/"#))
        #expect(node(safe, eq)?.configJSON == node(normal, eq)?.configJSON)
        // Same nodes, kinds, edges and params: only the plugin configs differ.
        #expect(safe.nodes.map(\.id) == normal.nodes.map(\.id) && safe.edges == normal.edges)
        #expect(safe.nodes.map(\.kind) == normal.nodes.map(\.kind))
        #expect(p.allDeviceSlots.first { $0.id == au }?.configJSON == node(normal, au)?.configJSON)
    }

    @Test("DW-224: safe mode is in the first graph; toggling it re-applies with plugin nodes re-created; the document never changes")
    func engineSyncFollowsSafeMode() async throws {
        let folder = try TempFolder("safe-slots")
        defer { folder.remove() }
        let (p, au, vst3, eq, instrument) = safeModeProject()
        let url = folder.url.appending(path: "Safe.dawproject")
        let saved = ProjectStore(project: p)
        saved.autosavePolicy = nil
        try await saved.save(to: url)

        let store = try await ProjectStore.open(url, recover: false, safeMode: true)
        store.autosavePolicy = nil
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        let first = try #require(engine.appliedGraphs.first)
        for slot in [au, vst3, instrument] { #expect(node(first, slot)?.configJSON.contains(#""disabled":true"#) == true) }
        #expect(node(first, eq)?.configJSON == "")
        let versions = Dictionary(uniqueKeysWithValues: first.nodes.map { ($0.id, $0.configVersion) })

        store.isSafeMode = false
        let enabled = try #require(engine.appliedGraphs.last)
        #expect(engine.appliedGraphs.count == 2)
        for slot in [au, vst3, instrument] {
            #expect(node(enabled, slot)?.configJSON.contains("disabled") == false)
            #expect(node(enabled, slot)?.configVersion != versions[slot])  // re-created: the plugin loads now
        }
        #expect(node(enabled, eq)?.configVersion == versions[eq])

        store.isSafeMode = true
        #expect(engine.appliedGraphs.count == 3)
        #expect(node(try #require(engine.appliedGraphs.last), au)?.configJSON.contains(#""disabled":true"#) == true)
        #expect(store.project == p && !store.isDirty && !store.canUndo)
        _ = sync
        await store.close()
    }

    @Test("DW-224: with a real engine, safe mode never loads a plugin (no failure for a missing one); saving keeps the stored state exactly")
    func realEngineNeverInstantiates() async throws {
        let folder = try TempFolder("safe-real")
        defer { folder.remove() }
        let (p, au, vst3, _, instrument) = safeModeProject()
        let url = folder.url.appending(path: "Safe.dawproject")
        let saved = ProjectStore(project: p)
        saved.autosavePolicy = nil
        try await saved.save(to: url)
        let stateFile = url.appending(path: "Plugins/\(au).state")
        #expect(try Data(contentsOf: stateFile) == Data([1, 2, 3]))

        let store = try await ProjectStore.open(url, recover: false, safeMode: true)
        store.autosavePolicy = nil
        let engine = try EngineClient(.offline(sampleRate: 48_000))
        let sync = try store.attachEngine(engine, debounce: .zero)
        store.pluginStateProvider = EnginePluginStates(engine: engine)
        sync.flush()
        // The graph builds on daw.compile; give it time to report anything.
        var events: [EngineEvent] = []
        for _ in 0..<20 {
            events += sync.pollEvents()
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!events.contains { $0.kind == .pluginCrashed }, "a disabled slot loads nothing, so nothing fails")
        for slot in [au, vst3, instrument] {
            let info = engine.pluginInfoJSON(slot: slot)
            #expect(info.contains(#""disabled":true"#) && info.contains(#""loaded":false"#), "\(info)")
        }
        // Saving in safe mode writes the stored blob back byte for byte (the engine hands back the
        // configured state), and the document is unchanged.
        try await store.save(to: nil)
        #expect(try Data(contentsOf: stateFile) == Data([1, 2, 3]))
        #expect(store.project == p)

        // Leaving safe mode loads them: the missing VST3 now fails (pluginCrashed) and AUDelay loads.
        store.isSafeMode = false
        sync.flush()
        var crashed: Set<ModelID> = []
        for _ in 0..<200 where !crashed.contains(vst3) {
            for event in sync.pollEvents() where event.kind == .pluginCrashed { crashed.insert(event.subject) }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(crashed.contains(vst3))
        #expect(!engine.pluginInfoJSON(slot: au).contains("disabled"))
        await store.close()
    }
}
