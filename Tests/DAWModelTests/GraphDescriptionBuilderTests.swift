import Foundation
import Testing

@testable import DAWModel

/// Stand-in ParamInfo for kinds whose nodes don't publish any yet (06 is later), so snapshots show
/// device param ranges. Fixed here so snapshots don't move when the engine adds ParamInfo.
let testCatalog = ParamCatalog(defaults: [
    .eq: [0, 0, 1],
    .compressor: [-12, 4, 10, 100],
    .delay: [0.25, 0.3],
    .reverb: [0.5],
])

@Suite("GraphDescriptionBuilder (MODEL-020)")
struct GraphDescriptionBuilderTests {
    private static var record: Bool { ProcessInfo.processInfo.environment["DAW_RECORD_SNAPSHOTS"] == "1" }

    private static func encode(_ project: Project) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(project) + Data("\n".utf8)
    }

    @Test("MODEL-020: snapshot of each fixture project's graph", arguments: GraphFixtures.names)
    func snapshot(_ name: String) throws {
        let projectURL = GraphFixtures.fixturesDir.appending(path: "projects/\(name).json")
        let snapshotURL = GraphFixtures.fixturesDir.appending(path: "graph_snapshots/\(name).txt")
        let defined = try GraphFixtures.project(named: name)
        if Self.record {
            try FileManager.default.createDirectory(at: projectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encode(defined).write(to: projectURL)
        }

        let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: projectURL))
        #expect(project == defined, "Tests/Fixtures/projects/\(name).json is out of date with GraphFixtures")

        let graph = GraphDescriptionBuilder.build(project, runtime: .sequential(for: project, catalog: testCatalog))
        let text = GraphSnapshot.render(graph)
        if Self.record {
            try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: snapshotURL, atomically: true, encoding: .utf8)
        }
        let expected = try String(contentsOf: snapshotURL, encoding: .utf8)
        #expect(text == expected, "graph of \(name) differs from Tests/Fixtures/graph_snapshots/\(name).txt:\n\(text)")
    }

    @Test("MODEL-020: every fixture graph is well formed", arguments: GraphFixtures.names)
    func wellFormed(_ name: String) throws {
        let project = try GraphFixtures.project(named: name)
        let runtime = RuntimeIDs.sequential(for: project, catalog: testCatalog)
        let graph = GraphDescriptionBuilder.build(project, runtime: runtime)
        let ids = graph.nodes.map(\.id)
        #expect(Set(ids).count == ids.count, "node IDs are unique")
        #expect(Set(graph.edges.map(\.id)).count == graph.edges.count, "edge IDs are unique (MIX-022)")
        #expect(graph.nodes.filter { $0.kind == .master }.map(\.id) == [graph.master], "one master, the graph's (MIX-009)")
        for e in graph.edges {
            #expect(ids.contains(e.from) && ids.contains(e.to), "edge \(e.id) connects known nodes")
            #expect(e.toPort == 0 && e.from != graph.master, "MIX-004 ports; nothing leaves the master")
        }
        #expect(isAcyclic(graph))
        // Every node with params got the range the runtime holds for it, and strips have room for
        // the agreed layout (gain, pan, mute, phase).
        for n in graph.nodes where n.numParams > 0 {
            #expect(runtime.params[n.id] == .init(first: n.firstParam, count: n.numParams))
        }
        for n in graph.nodes where n.kind == .channelStrip { #expect(n.numParams == ParamLayout.Strip.count) }
        for n in graph.nodes where n.kind == .gain { #expect(n.numParams == ParamLayout.Send.count) }
    }

    @Test("MODEL-020: pure; names, colors, monitoring modes and param values don't change the graph")
    func pure() throws {
        let project = GraphFixtures.routing()
        let runtime = RuntimeIDs.sequential(for: project, catalog: testCatalog)
        let graph = GraphDescriptionBuilder.build(project, runtime: runtime)
        #expect(GraphDescriptionBuilder.build(project, runtime: runtime) == graph)

        var edited = project
        edited.name = "renamed"
        edited.tracks[0].name = "Lead"
        edited.tracks[0].color = TrackColor(red: 1, green: 0, blue: 0)
        edited.tracks[0].monitoring = .on  // REC-022 (T-054): a slot, not structure
        edited.tracks[0].strip = ChannelStripState(gain: 0.1, pan: 1, mute: true, solo: true, phaseInvert: true)
        edited.tracks[0].sends[0].level = 0
        edited.tracks[0].inserts[0].params = [ParamValue(index: 0, value: 0.9)]
        edited.buses[1].strip.solo = true
        #expect(GraphDescriptionBuilder.build(edited, runtime: runtime) == graph, "param-only edits aren't structural (MODEL-021)")

        // REC-022 (T-054): arming and the input pair are structural (the track's monitor), so they
        // change the graph; the monitoring mode only reaches its slot.
        var armed = project
        armed.tracks[0].armed = true
        let armedGraph = GraphDescriptionBuilder.build(armed, runtime: runtime)
        #expect(armedGraph != graph)
        #expect(armedGraph.monitors.first { $0.player == GraphNodeID.source(of: project.tracks[0].id) }?.armed == true)
        var paired = project
        paired.tracks[0].inputPair = 3
        #expect(GraphDescriptionBuilder.build(paired, runtime: runtime) != graph)
    }

    @Test("REC-020..022: every audio track's clip player gets a monitor with its arm, input pair and mode slot")
    func monitors() throws {
        var project = GraphFixtures.routing()
        project.tracks[0].monitoring = .off
        let audio = project.tracks.filter { $0.kind == .audio }
        #expect(!audio.isEmpty)
        let runtime = RuntimeIDs.sequential(for: project, catalog: testCatalog)
        let graph = GraphDescriptionBuilder.build(project, runtime: runtime)
        #expect(graph.monitors.count == audio.count)
        for track in audio {
            let monitor = try #require(graph.monitors.first { $0.player == GraphNodeID.source(of: track.id) })
            #expect(monitor.armed == track.armed && monitor.inputPair == track.inputPair)
            #expect(monitor.modeSlot == runtime.paramID(GraphNodeID.monitor(of: track.id), 0))
        }
        // The slots hold the modes: off 0, on 1, auto 2.
        let values = GraphDescriptionBuilder.paramValues(project, runtime: runtime, catalog: testCatalog)
        for track in audio {
            let slot = try #require(runtime.paramID(GraphNodeID.monitor(of: track.id), 0))
            #expect(values[slot] == EngineGraph.MonitoringSlot.value(track.monitoring))
        }
        #expect(EngineGraph.MonitoringSlot.value(.off) == 0 && EngineGraph.MonitoringSlot.value(.on) == 1
            && EngineGraph.MonitoringSlot.value(.auto) == 2)
        // MIDI tracks have none (play-through ignores the mode, REC-011).
        for track in project.tracks where track.kind == .midi {
            #expect(!graph.monitors.contains { $0.player == GraphNodeID.source(of: track.id) })
            #expect(runtime.params[GraphNodeID.monitor(of: track.id)] == nil)
        }
    }

    @Test("MODEL-020: send taps, sidechain tap and bypass follow the send design")
    func routingDetails() throws {
        let p = GraphFixtures.routing()
        let graph = GraphDescriptionBuilder.build(p, runtime: .sequential(for: p, catalog: testCatalog))
        let (vox, kick) = (p.tracks[0], p.tracks[1])
        let (group, verb) = (p.buses[0], p.buses[2])
        func has(_ from: NodeIDValue, _ to: NodeIDValue, _ kind: EngineGraph.EdgeKind = .audio) -> Bool {
            graph.edges.contains { $0.from == from && $0.to == to && $0.kind == kind }
        }
        // Post-fader send: strip → gain(send) → bus input.
        #expect(has(vox.id, vox.sends[0].id) && has(vox.sends[0].id, GraphNodeID.input(of: verb.id)))
        // Pre-fader send: the node feeding the strip (Kick has no inserts: its clip player).
        #expect(has(GraphNodeID.source(of: kick.id), kick.sends[0].id))
        // Pre-fader sidechain from Kick into Vox's compressor.
        #expect(has(GraphNodeID.source(of: kick.id), vox.inserts[1].id, .sidechain))
        // Group's bypassed compressor is left out; the bus input feeds the strip directly.
        #expect(!graph.nodes.contains { $0.id == group.inserts[0].id })
        #expect(has(GraphNodeID.input(of: group.id), group.id))
        // A send to a bus that doesn't exist is dropped, as is an output to one.
        var dangling = p
        dangling.tracks[1].sends[0].target = 999
        dangling.tracks[1].output = .bus(999)
        let g2 = GraphDescriptionBuilder.build(dangling, runtime: .sequential(for: dangling, catalog: testCatalog))
        #expect(!g2.nodes.contains { $0.id == kick.sends[0].id })
        #expect(!g2.edges.contains { $0.from == kick.id })
    }

    @Test("MODEL-020: edge IDs are stable for edges whose ends don't change")
    func stableEdgeIDs() throws {
        let p = GraphFixtures.routing()
        let before = GraphDescriptionBuilder.build(p, runtime: .sequential(for: p, catalog: testCatalog))
        var q = p
        q.buses[1].inserts = []  // Main loses its EQ
        let after = GraphDescriptionBuilder.build(q, runtime: .sequential(for: q, catalog: testCatalog))
        let key = { (e: EngineGraph.Edge) in "\(e.from)-\(e.to)-\(e.kind)" }
        let old = Dictionary(uniqueKeysWithValues: before.edges.map { (key($0), $0.id) })
        var shared = 0
        for e in after.edges {
            if let id = old[key(e)] {
                #expect(id == e.id)
                shared += 1
            }
        }
        #expect(shared == after.edges.count - 1, "only Main's input → strip edge is new")
    }

    @Test("MODEL-020: NodeIDs are role-tagged model IDs")
    func nodeIDs() {
        let source = GraphNodeID.source(of: 42)
        #expect(source != 42 && GraphNodeID.owner(of: source) == 42 && GraphNodeID.role(of: source) == .source)
        #expect(GraphNodeID.make(.entity, 42) == 42)
        let ids = GraphNodeID.Role.allCases.map { GraphNodeID.make($0, 7) }
        #expect(Set(ids).count == ids.count)
    }

    @Test("08 delta 4: applyGraph(project, runtime) sends the built graph")
    func applyProject() throws {
        let engine = FakeEngine()
        let p = GraphFixtures.audioTracks()
        let runtime = RuntimeIDs.sequential(for: p)
        #expect(engine.applyGraph(p, runtime: runtime) == 1)
        #expect(engine.appliedGraphs == [GraphDescriptionBuilder.build(p, runtime: runtime)])
    }

    private func isAcyclic(_ g: EngineGraph) -> Bool {
        var indegree = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, 0) })
        for e in g.edges { indegree[e.to, default: 0] += 1 }
        var ready = indegree.filter { $0.value == 0 }.map(\.key)
        var seen = 0
        while let n = ready.popLast() {
            seen += 1
            for e in g.edges where e.from == n {
                indegree[e.to]! -= 1
                if indegree[e.to] == 0 { ready.append(e.to) }
            }
        }
        return seen == g.nodes.count
    }
}
