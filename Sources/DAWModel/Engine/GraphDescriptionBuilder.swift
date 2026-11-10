import Foundation

/// MODEL-020: turns a `Project` into the `EngineGraph` the engine compiles (05 Interfaces,
/// `GraphDescription`). Pure: the same project and runtime IDs always give the same graph, in the
/// same order, so it can be snapshot-tested and compared to decide whether a change is structural
/// (MODEL-021).
///
/// Layout (05 Topology), NodeIDs from GraphNodeID:
/// ```
/// audio track: clipPlayer(source) → inserts… → strip(track)
/// MIDI track:  midiClipPlayer(source) ─midi→ instrument(slot) → inserts… → strip(track)
/// bus:         bus(input) → inserts… → strip(bus)
/// master:      bus(input) → inserts… → strip(master) → master(output)
/// metronome:   metronome(master) → master(output)    (T-026, always there; its slots switch it)
/// strip → input of the output target (a bus or the master)
/// send:        tap → gain(send) → input of the target bus
///              post-fader tap = the strip; pre-fader tap = the node feeding the strip
/// sidechain:   tap of the source channel ─sidechain→ device slot
/// ```
/// Buses and the master sum at a dedicated input node, so changing their inserts doesn't touch the
/// edges coming in (MIX-022 keeps those edges' delay lines).
///
/// Edge IDs hash (from, to, kind), so an edge whose ends don't change keeps its ID across rebuilds.
///
/// Not in the graph: bypassed devices (until host-side bypass, PLUG-018), an instrument on an audio
/// track, a MIDI track's clip player when it has no (active) instrument, outputs and sends to a bus
/// that doesn't exist. Param values aren't in the graph either; they travel through `setParam`
/// (`paramValues`).
public enum GraphDescriptionBuilder {
    public static func build(_ project: Project, runtime: RuntimeIDs) -> EngineGraph {
        var b = Emitter(runtime: runtime)
        b.graph.tempoEvents = project.tempoMap.tempoEvents
        b.graph.timeSignatures = project.tempoMap.timeSignatures

        // Where sends and sidechains pick up each channel: pre-fader (nil if nothing feeds the
        // strip) and post-fader.
        var taps: [NodeIDValue: (pre: NodeIDValue?, post: NodeIDValue)] = [:]

        for track in project.tracks {
            var head: NodeIDValue?
            let source = GraphNodeID.source(of: track.id)
            switch track.kind {
            case .audio:
                b.node(source, .audioClipPlayer)
                for case .audio(let clip) in track.clips {
                    b.graph.audioClips.append(.init(
                        player: source, clipID: clip.id, start: clip.start, length: clip.length,
                        assetID: clip.assetID, sourceOffsetSamples: clip.sourceOffsetSamples, gain: clip.gain,
                        fadeIn: clip.fadeIn, fadeOut: clip.fadeOut))
                }
                head = source
            case .midi:
                if let instrument = track.instrument, !instrument.bypass {
                    b.node(source, .midiClipPlayer)
                    for case .midi(let clip) in track.clips { b.appendNotes(of: clip, player: source) }
                    b.node(instrument.id, instrument.nodeKind, config: instrument.configJSON)
                    b.edge(source, instrument.id, .midi)
                    head = instrument.id
                }
            }
            head = b.chain(track.inserts, after: head)
            b.node(track.id, .channelStrip)
            if let head { b.edge(head, track.id) }
            taps[track.id] = (head, track.id)
        }

        for bus in project.buses {
            let input = GraphNodeID.input(of: bus.id)
            b.node(input, .bus)
            let head = b.chain(bus.inserts, after: input)
            b.node(bus.id, .channelStrip)
            b.edge(head, bus.id)
            taps[bus.id] = (head, bus.id)
        }

        let master = project.master
        let masterInput = GraphNodeID.input(of: master.id)
        let masterOutput = GraphNodeID.output(of: master.id)
        b.node(masterInput, .bus)
        let masterHead = b.chain(master.inserts, after: masterInput)
        b.node(master.id, .channelStrip)
        b.edge(masterHead, master.id)
        b.node(masterOutput, .master)
        b.edge(master.id, masterOutput)
        b.graph.master = masterOutput

        // TIME-010 (T-026): the click goes straight into the master node, past the master's
        // inserts and fader, so no solo, mute or master FX touches it. It is always in the graph:
        // `project.metronome` only reaches its param slots, so toggling it never rebuilds.
        let metronome = GraphNodeID.metronome(of: master.id)
        b.node(metronome, .metronome)
        b.edge(metronome, masterOutput)

        // Outputs, then sends, then sidechains: every node they connect exists by now.
        let buses = Set(project.buses.map(\.id))
        func input(of target: OutputTarget) -> NodeIDValue? {
            switch target {
            case .master: masterInput
            case .bus(let id): buses.contains(id) ? GraphNodeID.input(of: id) : nil
            }
        }
        let channels = project.tracks.map { ($0.id, $0.output, $0.sends) }
            + project.buses.map { ($0.id, $0.output, $0.sends) }
        for (id, output, _) in channels {
            if let target = input(of: output) { b.edge(id, target) }
        }
        for (id, _, sends) in channels {
            for send in sends where buses.contains(send.target) {
                b.node(send.id, .gain)
                let tap = taps[id].flatMap { send.tap == .postFader ? $0.post : $0.pre }
                if let tap { b.edge(tap, send.id) }
                b.edge(send.id, GraphNodeID.input(of: send.target))
            }
        }
        for slot in project.allDeviceSlots where b.emitted.contains(slot.id) {
            guard let ref = slot.sidechainSource, let tap = taps[ref.source],
                let from = ref.tap == .postFader ? tap.post : tap.pre
            else { continue }
            b.edge(from, slot.id, .sidechain)
        }
        return b.graph
    }

    /// MODEL-022: the param slots every param-bearing node needs, by NodeID. Device slots and
    /// sends get theirs whether or not they are in the graph right now (bypassed, dangling), so
    /// toggling bypass keeps their slots.
    public static func paramRequirements(_ project: Project, catalog: ParamCatalog) -> [NodeIDValue: UInt32] {
        var out: [NodeIDValue: UInt32] = [:]
        out[project.master.id] = ParamLayout.Strip.count
        out[GraphNodeID.output(of: project.master.id)] = ParamLayout.Master.count
        out[GraphNodeID.metronome(of: project.master.id)] = ParamLayout.Metronome.count
        for track in project.tracks {
            out[track.id] = ParamLayout.Strip.count
            for send in track.sends { out[send.id] = ParamLayout.Send.count }
        }
        for bus in project.buses {
            out[bus.id] = ParamLayout.Strip.count
            for send in bus.sends { out[send.id] = ParamLayout.Send.count }
        }
        for slot in project.allDeviceSlots {
            let count = catalog.paramCount(for: slot)
            if count > 0 { out[slot.id] = count }
        }
        return out
    }

    /// MODEL-021: the value every allocated slot should hold for `project`. A channel's resolved
    /// mute (manual or solo, MIX-006) goes into its strip's mute slot and into the mute slot of
    /// every send it owns (MIX-007), so a muted channel can't leak into a bus through a pre-fader
    /// send. Send levels keep their value while muted.
    ///
    /// T-026: the metronome's `on` slot holds `project.metronome.enabled`, unless
    /// `metronomeSuppressed` (an export that leaves the click out) forces it off.
    public static func paramValues(
        _ project: Project, runtime: RuntimeIDs, catalog: ParamCatalog, metronomeSuppressed: Bool = false
    ) -> [ParamID: Float] {
        let muted = SoloResolver.mutedChannels(in: project)
        var out: [ParamID: Float] = [:]
        func set(_ node: NodeIDValue, _ index: UInt32, _ value: Float) {
            if let id = runtime.paramID(node, index) { out[id] = value }
        }
        func strip(_ id: NodeIDValue, _ state: ChannelStripState) {
            set(id, ParamLayout.Strip.gain, state.gain)
            set(id, ParamLayout.Strip.pan, state.pan)
            set(id, ParamLayout.Strip.mute, muted.contains(id) ? 1 : 0)
            set(id, ParamLayout.Strip.phase, state.phaseInvert ? 1 : 0)
        }
        func sends(_ owner: NodeIDValue, _ sends: [Send]) {
            for send in sends {
                set(send.id, ParamLayout.Send.level, send.level)
                set(send.id, ParamLayout.Send.mute, muted.contains(owner) ? 1 : 0)
            }
        }

        strip(project.master.id, project.master.strip)
        set(GraphNodeID.output(of: project.master.id), ParamLayout.Master.limiter, 0)
        let metronome = GraphNodeID.metronome(of: project.master.id)
        set(metronome, ParamLayout.Metronome.on, project.metronome.enabled && !metronomeSuppressed ? 1 : 0)
        set(metronome, ParamLayout.Metronome.level, project.metronome.level)
        set(metronome, ParamLayout.Metronome.accent, project.metronome.accent)
        for track in project.tracks {
            strip(track.id, track.strip)
            sends(track.id, track.sends)
        }
        for bus in project.buses {
            strip(bus.id, bus.strip)
            sends(bus.id, bus.sends)
        }
        for slot in project.allDeviceSlots {
            guard let range = runtime.params[slot.id] else { continue }
            var values = (0..<Int(range.count)).map { catalog.defaultValue(for: slot, $0) }
            for p in slot.params where values.indices.contains(p.index) { values[p.index] = p.value }
            for (i, value) in values.enumerated() { out[range.first + UInt32(i)] = value }
        }
        return out
    }

    /// Stable edge ID: a hash of the edge's ends and kind (MIX-022 keys delay lines by it).
    public static func edgeID(from: NodeIDValue, to: NodeIDValue, kind: EngineGraph.EdgeKind) -> ModelID {
        let k: UInt64 = switch kind {
        case .audio: 1
        case .midi: 2
        case .sidechain: 3
        }
        return mix(mix(mix(from) ^ to) ^ k)
    }

    /// SplitMix64's finalizer.
    private static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Appends nodes and edges with their params and versions from the runtime IDs.
private struct Emitter {
    let runtime: RuntimeIDs
    var graph = EngineGraph()
    /// Device slots that made it into the graph (sidechain targets).
    var emitted = Set<NodeIDValue>()

    init(runtime: RuntimeIDs) {
        self.runtime = runtime
    }

    mutating func node(_ id: NodeIDValue, _ kind: NodeKind, config: String = "") {
        let range = runtime.params[id]
        graph.nodes.append(.init(id: id, kind: kind, configVersion: runtime.configVersions[id] ?? 0,
                                 firstParam: range?.first ?? 0, numParams: range?.count ?? 0, configJSON: config))
        emitted.insert(id)
    }

    mutating func edge(_ from: NodeIDValue, _ to: NodeIDValue, _ kind: EngineGraph.EdgeKind = .audio) {
        // No two edges share ends and kind, so IDs are unique unless the 64-bit hash collides; the
        // engine rejects a duplicate ID (GraphBuilder) rather than mixing up delay lines.
        graph.edges.append(.init(id: GraphDescriptionBuilder.edgeID(from: from, to: to, kind: kind),
                                 from: from, to: to, kind: kind))
    }

    /// The active inserts in order after `head`; returns the new head.
    mutating func chain(_ inserts: [DeviceSlot], after head: NodeIDValue?) -> NodeIDValue? {
        var head = head
        for slot in inserts where !slot.bypass {
            node(slot.id, slot.nodeKind, config: slot.configJSON)
            if let head { edge(head, slot.id) }
            head = slot.id
        }
        return head
    }

    mutating func chain(_ inserts: [DeviceSlot], after head: NodeIDValue) -> NodeIDValue {
        chain(inserts, after: Optional(head)) ?? head
    }

    /// Note starts are relative to the clip (MidiClip); the clip window trims them.
    mutating func appendNotes(of clip: MidiClip, player: NodeIDValue) {
        for note in clip.notes {
            let start = max(note.start.raw, 0)
            let end = min(note.start.raw + note.length.raw, clip.length.raw)
            guard end > start else { continue }
            graph.notes.append(.init(player: player, start: Tick(clip.start.raw + start), length: Tick(end - start),
                                     pitch: note.pitch, velocity: note.velocity, channel: note.channel))
        }
    }
}

extension DeviceSlot {
    /// DW-140: the node's `configJSON`. A sampler with zones gets `{"zones": [...]}` in the
    /// format of 06 "Sampler semantics", keys sorted so equal zones give equal strings (MODEL-021
    /// compares graphs); an AU or VST3 plugin gets its identifier and state (T-061, T-062); every other slot gets "".
    var configJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // PLUG-010/016 (T-061): an AU slot's identifier and its stored state (base64 of the binary
        // plist), `{"identifier": …, "state": …}` (plugins/AUPluginConfig.h). The engine applies the
        // state when it makes the slot's AU (a project being opened) or when it changes later.
        // PLUG-011/016 (T-062): a VST3 slot's config is the same shape (identifier `path#classUID`,
        // state = the engine's state container, plugins/VST3PluginConfig.h).
        let pluginIdentifier: String? = switch kind {
        case .au(let descriptor): descriptor.identifier
        case .vst3(let descriptor): descriptor.identifier
        default: nil
        }
        if let pluginIdentifier {
            struct PluginConfig: Encodable {
                var identifier: String
                var state: String?
            }
            let config = PluginConfig(identifier: pluginIdentifier, state: pluginState?.base64EncodedString())
            guard let data = try? encoder.encode(config) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        guard isSampler, !zones.isEmpty else { return "" }
        // Plain integers, floats and optionals: encoding can't fail.
        guard let data = try? encoder.encode(["zones": zones]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Project {
    /// Every instrument and insert, master's included, in layout order.
    var allDeviceSlots: [DeviceSlot] {
        var out: [DeviceSlot] = []
        for track in tracks {
            if track.kind == .midi, let instrument = track.instrument { out.append(instrument) }
            out += track.inserts
        }
        for bus in buses { out += bus.inserts }
        out += master.inserts
        return out
    }
}
