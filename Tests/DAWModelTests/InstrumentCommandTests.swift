import Foundation
import Testing

@testable import DAWModel

// MODEL-005 (T-042): the instrument slot on MIDI tracks (SetInstrument, RemoveInstrument,
// RestoreInstrument) and DW-140: sampler zones in the model (SetSamplerZones, configJSON,
// configVersion bumps). The project is ClipProject (ClipCommandTests): an audio track "Gtr", a MIDI
// track "Keys" without an instrument, and one asset.

@Suite("Instrument slot and sampler zones")
struct InstrumentCommandTests {
    init() { TestCommands.register() }

    let p = ClipProject.make()
    var keys: NodeIDValue { p.keys.id }
    var asset: ModelID { p.loopAsset.id }

    /// `p` with a sampler on Keys.
    func withSampler(zones: [SamplerZone] = []) throws -> Project {
        var q = p
        _ = try SetInstrument(trackID: keys, device: .builtin(.sampler), zones: zones).applyChecked(to: &q)
        return q
    }

    // MARK: Instrument slot

    @Test("MODEL-005: SetInstrument puts a sampler with a new slot ID on a MIDI track; the graph gets player → sampler → strip")
    func setInstrument() throws {
        #expect(!GraphDescriptionBuilder.build(p, runtime: RuntimeIDs()).nodes.contains { $0.id == GraphNodeID.source(of: keys) },
                "no instrument: no player")
        let set = try expectApplyRoundTrip(SetInstrument(trackID: keys, device: .builtin(.sampler)), on: p)
        let slot = p.ids.next
        #expect(set.keys.instrument == DeviceSlot(id: slot, kind: .builtin(.sampler)))

        let graph = GraphDescriptionBuilder.build(set, runtime: RuntimeIDs())
        let player = GraphNodeID.source(of: keys)
        #expect(graph.nodes.contains { $0.id == player && $0.kind == .midiClipPlayer })
        #expect(graph.nodes.contains { $0.id == slot && $0.kind == .sampler && $0.configJSON == "" })
        #expect(graph.edges.contains { $0.from == player && $0.to == slot && $0.kind == .midi })
        #expect(graph.edges.contains { $0.from == slot && $0.to == keys && $0.kind == .audio })
        #expect(graph.notes.count == 2)

        // Replacing: a new slot, and the inverse restores the old one with its ID.
        let au = DeviceSlot.Kind.au(AUDescriptor(identifier: "aumu:samp:appl", name: "AUSampler"))
        let replaced = try expectApplyRoundTrip(SetInstrument(trackID: keys, device: au), on: set)
        #expect(replaced.keys.instrument == DeviceSlot(id: slot + 1, kind: au))
        let vst = DeviceSlot.Kind.vst3(VST3Descriptor(identifier: "/x.vst3#1", name: "Synth"))
        #expect(try expectApplyRoundTrip(SetInstrument(trackID: keys, device: vst), on: p).keys.instrument?.kind == vst)
    }

    @Test("MODEL-005: RemoveInstrument removes the slot (and the player leaves the graph); undo restores it with ID, params and zones")
    func removeInstrument() throws {
        var set = try withSampler(zones: [SamplerZone(assetID: asset, rootKey: 69)])
        _ = try SetParam(target: .device(slot: set.keys.instrument!.id, index: 3), value: 0.5).applyChecked(to: &set)
        let removed = try expectApplyRoundTrip(RemoveInstrument(trackID: keys), on: set)
        #expect(removed.keys.instrument == nil)
        let graph = GraphDescriptionBuilder.build(removed, runtime: RuntimeIDs())
        #expect(!graph.nodes.contains { $0.kind == .midiClipPlayer || $0.kind == .sampler } && graph.notes.isEmpty)
    }

    @Test("MODEL-005: RestoreInstrument sets the slot to exactly the one given, or none; it inverts to itself")
    func restoreInstrument() throws {
        let set = try withSampler()
        let slot = try #require(set.keys.instrument)
        let restored = try expectApplyRoundTrip(RestoreInstrument(trackID: keys, instrument: slot), on: p)
        #expect(restored.keys.instrument == slot && restored.ids.next == slot.id + 1)
        #expect(try expectApplyRoundTrip(RestoreInstrument(trackID: keys, instrument: nil), on: set).keys.instrument == nil)
        // Over itself: the slot it replaces gives its ID up first.
        var changed = slot
        changed.bypass = true
        #expect(try expectApplyRoundTrip(RestoreInstrument(trackID: keys, instrument: changed), on: set).keys.instrument == changed)
    }

    @Test("MODEL-005: undo and redo of instrument edits keep slot IDs, so later history entries still apply")
    func redoKeepsSlotIDs() throws {
        var project = p
        var stack = UndoStack()
        try stack.perform(SetInstrument(trackID: keys, device: .builtin(.sampler)), on: &project)
        let slot = try #require(project.keys.instrument?.id)
        try stack.perform(SetSamplerZones(slotID: slot, zones: [SamplerZone(assetID: asset)]), on: &project)
        try stack.perform(SetParam(target: .device(slot: slot, index: 0), value: 0.1), on: &project)
        try stack.perform(RemoveInstrument(trackID: keys), on: &project)
        try stack.perform(SetInstrument(trackID: keys, device: .builtin(.sampler)), on: &project)
        let final = project
        while try stack.undo(&project) != nil {}
        #expect(project == p)
        while try stack.redo(&project) != nil {}
        #expect(project == final)
    }

    @Test("MODEL-006: instrument and zone commands' wire shapes")
    func wireShapes() throws {
        let json = #"{"type":"SetInstrument","trackID":3,"device":{"format":"builtin","node":"sampler"},"zones":[{"assetID":1,"rootKey":69}]}"#
        let set = try #require(try CommandRegistry.decode(Data(json.utf8)) as? SetInstrument)
        #expect(set.device == .builtin(.sampler) && set.zones == [SamplerZone(assetID: 1, rootKey: 69)])
        func wire(_ command: any Command) throws -> String { String(decoding: try CommandRegistry.encode(command), as: UTF8.self) }
        #expect(try wire(RemoveInstrument(trackID: 3)) == #"{"trackID":3,"type":"RemoveInstrument"}"#)
        #expect(try wire(RestoreInstrument(trackID: 3, instrument: nil)) == #"{"trackID":3,"type":"RestoreInstrument"}"#)
        #expect(try wire(SetSamplerZones(slotID: 4, zones: [SamplerZone(assetID: 1, loopStart: 0, loopEnd: 10)]))
            == #"{"slotID":4,"type":"SetSamplerZones","zones":[{"assetID":1,"gain":1,"highKey":127,"highVel":127,"loopEnd":10,"loopStart":0,"lowKey":0,"lowVel":1,"rootKey":60,"tune":0}]}"#)
    }

    // MARK: Sampler zones (DW-140)

    @Test("DW-140: SetSamplerZones replaces a sampler's zones; the inverse sets the old ones")
    func setZones() throws {
        let set = try withSampler()
        let slot = try #require(set.keys.instrument?.id)
        let zones = [SamplerZone(assetID: asset, rootKey: 69, lowKey: 0, highKey: 70, tune: -0.5, gain: 0.5),
                     SamplerZone(assetID: asset, lowKey: 71, lowVel: 64, loopStart: 100, loopEnd: 48_000)]
        let zoned = try expectApplyRoundTrip(SetSamplerZones(slotID: slot, zones: zones), on: set)
        #expect(zoned.keys.instrument?.zones == zones)
        let cleared = try expectApplyRoundTrip(SetSamplerZones(slotID: slot, zones: []), on: zoned)
        #expect(cleared.keys.instrument?.zones == [])
    }

    @Test("DW-140: a sampler's zones become its node's configJSON in 06's format; no zones, no config")
    func configJSON() throws {
        let zoned = try withSampler(zones: [SamplerZone(assetID: asset, rootKey: 69, tune: 0.25, loopStart: 0, loopEnd: 480)])
        let slot = try #require(zoned.keys.instrument?.id)
        let node = try #require(GraphDescriptionBuilder.build(zoned, runtime: RuntimeIDs()).nodes.first { $0.id == slot })
        #expect(node.configJSON == #"{"zones":[{"assetID":\#(asset),"gain":1,"highKey":127,"highVel":127,"loopEnd":480,"loopStart":0,"lowKey":0,"lowVel":1,"rootKey":69,"tune":0.25}]}"#)
    }

    @Test("DW-140: project.json stores zones only for slots that have some; they round-trip")
    func persistence() throws {
        let plain = try JSONEncoder().encode(DeviceSlot(id: 4, kind: .builtin(.eq)))
        #expect(!String(decoding: plain, as: UTF8.self).contains("zones"))
        let zoned = try withSampler(zones: [SamplerZone(assetID: asset, highVel: 100)])
        let json = try JSONEncoder().encode(zoned)
        #expect(try JSONDecoder().decode(Project.self, from: json) == zoned)
        let minimal = try JSONDecoder().decode(SamplerZone.self, from: Data(#"{"assetID":7}"#.utf8))
        #expect(minimal == SamplerZone(assetID: 7), "06 defaults")
    }

    @Test("DW-140: RemoveAsset refuses an asset a zone uses; validate() requires zone assets to exist")
    func zoneAssets() throws {
        var zoned = try withSampler(zones: [SamplerZone(assetID: asset)])
        zoned.tracks[0].clips = []
        let slot = try #require(zoned.keys.instrument?.id)
        var q = zoned
        #expect(throws: DAWError.invalidArgument("asset \(asset) is used by sampler \(slot)")) {
            _ = try RemoveAsset(assetID: asset).applyChecked(to: &q)
        }
        q.assets = []
        #expect(throws: DAWError.brokenInvariant("sampler \(slot) uses missing asset \(asset)")) { try q.validate() }
    }

    // MARK: MODEL-031 / MODEL-032

    @Test("MODEL-031: unknown IDs and bad arguments throw and change nothing")
    func invalidCommands() throws {
        let missing: ModelID = 999
        let gtr = p.gtr.id
        let set = try withSampler()
        let sampler = try #require(set.keys.instrument)
        var withEQ = set
        withEQ.tracks[0].inserts = [DeviceSlot(id: withEQ.ids.allocate(), kind: .builtin(.eq))]
        let next = withEQ.ids.next
        let eq = withEQ.tracks[0].inserts[0].id
        func zone(_ edit: (inout SamplerZone) -> Void) -> SamplerZone {
            var z = SamplerZone(assetID: asset)
            edit(&z)
            return z
        }
        let z = "sampler \(sampler.id) zone of asset \(asset)"
        let cases: [(any Command, DAWError)] = [
            (SetInstrument(trackID: missing, device: .builtin(.sampler)), .notFound(kind: "track", id: missing)),
            (SetInstrument(trackID: gtr, device: .builtin(.sampler)), .invalidArgument("track \(gtr) is not a MIDI track")),
            (SetInstrument(trackID: keys, device: .builtin(.eq)), .brokenInvariant("device slot \(next) is a built-in eq, which is no instrument")),
            (SetInstrument(trackID: keys, device: .builtin(.sampler), zones: [SamplerZone(assetID: missing)]), .notFound(kind: "asset", id: missing)),
            (SetInstrument(trackID: keys, device: .au(AUDescriptor(identifier: "a:b:c", name: "x")), zones: [SamplerZone(assetID: asset)]),
             .brokenInvariant("device slot \(next) has zones but is no sampler")),

            (RemoveInstrument(trackID: missing), .notFound(kind: "track", id: missing)),
            (RemoveInstrument(trackID: gtr), .invalidArgument("track \(gtr) has no instrument")),

            (RestoreInstrument(trackID: gtr, instrument: nil), .invalidArgument("track \(gtr) is not a MIDI track")),
            (RestoreInstrument(trackID: missing, instrument: nil), .notFound(kind: "track", id: missing)),
            (RestoreInstrument(trackID: keys, instrument: DeviceSlot(id: gtr, kind: .builtin(.sampler))),
             .invalidArgument("device slot id \(gtr) is already in use")),
            (RestoreInstrument(trackID: keys, instrument: DeviceSlot(id: 0, kind: .builtin(.sampler))),
             .invalidArgument("device slot id 0 is outside 1…\(GraphNodeID.maxModelID)")),
            (RestoreInstrument(trackID: keys, instrument: DeviceSlot(id: 900, kind: .builtin(.sampler), sidechainSource: SidechainRef(source: missing))),
             .notFound(kind: "track or bus", id: missing)),
            (RestoreInstrument(trackID: keys, instrument: DeviceSlot(id: 900, kind: .builtin(.sampler), sidechainSource: SidechainRef(source: keys))),
             .routingCycle(path: [keys, keys])),
            (RestoreInstrument(trackID: keys, instrument: DeviceSlot(id: 900, kind: .builtin(.sampler), params: [ParamValue(index: -1, value: 0)])),
             .brokenInvariant("device slot 900 has a bad or repeated param index -1")),

            (SetSamplerZones(slotID: missing, zones: []), .notFound(kind: "device slot", id: missing)),
            (SetSamplerZones(slotID: eq, zones: []), .invalidArgument("device slot \(eq) is not a sampler")),
            (SetSamplerZones(slotID: sampler.id, zones: [SamplerZone(assetID: missing)]), .notFound(kind: "asset", id: missing)),
            (SetSamplerZones(slotID: sampler.id, zones: [zone { $0.rootKey = 128 }]),
             .brokenInvariant("\(z) has keys 0…127 root 128, velocities 1…127")),
            (SetSamplerZones(slotID: sampler.id, zones: [zone { $0.lowKey = 61; $0.highKey = 60 }]),
             .brokenInvariant("\(z) has keys 61…60 root 60, velocities 1…127")),
            (SetSamplerZones(slotID: sampler.id, zones: [zone { $0.lowVel = 0 }]),
             .brokenInvariant("\(z) has keys 0…127 root 60, velocities 0…127")),
            (SetSamplerZones(slotID: sampler.id, zones: [zone { $0.highVel = 128 }]),
             .brokenInvariant("\(z) has keys 0…127 root 60, velocities 1…128")),
            (SetSamplerZones(slotID: sampler.id, zones: [zone { $0.tune = .nan }]), .brokenInvariant("\(z) tune nan is outside ±120.0")),
            (SetSamplerZones(slotID: sampler.id, zones: [zone { $0.tune = 121 }]), .brokenInvariant("\(z) tune 121.0 is outside ±120.0")),
            (SetSamplerZones(slotID: sampler.id, zones: [zone { $0.gain = -1 }]), .brokenInvariant("\(z) gain -1.0 is outside 0…3.9810717")),
            (SetSamplerZones(slotID: sampler.id, zones: [zone { $0.loopStart = 0 }]),
             .brokenInvariant("\(z) loop must be both or neither of 0 ≤ loopStart < loopEnd ≤ 2^48")),
            (SetSamplerZones(slotID: sampler.id, zones: [zone { $0.loopStart = 10; $0.loopEnd = 10 }]),
             .brokenInvariant("\(z) loop must be both or neither of 0 ≤ loopStart < loopEnd ≤ 2^48")),
            (SetSamplerZones(slotID: sampler.id, zones: [zone { $0.loopStart = -1; $0.loopEnd = 10 }]),
             .brokenInvariant("\(z) loop must be both or neither of 0 ≤ loopStart < loopEnd ≤ 2^48")),
        ]
        for (command, error) in cases {
            var q = withEQ
            #expect(throws: error, "\(type(of: command).type)") { _ = try command.applyChecked(to: &q) }
            #expect(q == withEQ)
        }
    }

    @Test("MODEL-032: an instrument sits only on a MIDI track and a built-in one is the sampler; zones only on a sampler")
    func validation() throws {
        var audio = p
        audio.tracks[0].instrument = DeviceSlot(id: audio.ids.allocate(), kind: .builtin(.sampler))
        #expect(throws: DAWError.brokenInvariant("audio track \(p.gtr.id) has an instrument")) { try audio.validate() }
        var eq = p
        let id = eq.ids.allocate()
        eq.tracks[1].instrument = DeviceSlot(id: id, kind: .builtin(.eq))
        #expect(throws: DAWError.brokenInvariant("device slot \(id) is a built-in eq, which is no instrument")) { try eq.validate() }
        var zonedEQ = p
        zonedEQ.tracks[0].inserts = [DeviceSlot(id: id, kind: .builtin(.eq), zones: [SamplerZone(assetID: asset)])]
        zonedEQ.ids.reserve(id)
        #expect(throws: DAWError.brokenInvariant("device slot \(id) has zones but is no sampler")) { try zonedEQ.validate() }
    }

    // MARK: Engine sync (DW-051, DW-072, DW-140)

    @Test("DW-140: zone edits and zone-asset loads bump the sampler's configVersion; instrument edits rebuild the graph")
    @MainActor
    func engineSync() async throws {
        let store = ProjectStore(project: p)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine)
        let player = GraphNodeID.source(of: keys)
        #expect(engine.appliedGraphs.last?.nodes.contains { $0.id == player } == false)

        try store.perform(SetInstrument(trackID: keys, device: .builtin(.sampler)))
        await sync.settle()
        let slot = try #require(store.project.keys.instrument?.id)
        func node() throws -> EngineGraph.Node { try #require(engine.appliedGraphs.last?.nodes.first { $0.id == slot }) }
        #expect(engine.appliedGraphs.last?.edges.contains { $0.from == player && $0.to == slot && $0.kind == .midi } == true)
        let v0 = try node().configVersion

        try store.perform(SetSamplerZones(slotID: slot, zones: [SamplerZone(assetID: asset)]))
        await sync.settle()
        #expect(try node().configVersion > v0)
        #expect(try node().configJSON.contains(#""assetID":\#(asset)"#))

        let v1 = try node().configVersion
        engine.post(EngineEvent(kind: .assetLoaded, subject: asset))
        _ = sync.pollEvents()
        await sync.settle()
        #expect(try node().configVersion > v1, "the sampler resolves its zones' assets when created")

        let v2 = try node().configVersion
        let applied = engine.appliedGraphs.count
        try store.perform(SetNoteProps(clipID: store.project.keys.clips[0].id,
                                       notes: [.init(id: store.project.keys.clips[0].midiNotes[0].id, velocity: 3)]))
        await sync.settle()
        #expect(engine.appliedGraphs.count == applied + 1)
        #expect(try node().configVersion == v2, "a note edit re-creates the player, not the sampler")

        try store.perform(RemoveInstrument(trackID: keys))
        await sync.settle()
        #expect(engine.appliedGraphs.last?.nodes.contains { $0.id == player || $0.id == slot } == false)
        store.undo()
        await sync.settle()
        #expect(engine.appliedGraphs.last?.nodes.contains { $0.id == slot } == true)
    }
}

// The real engine: the sampler accepts the configJSON the model emits, and the graph a MIDI track
// with a sampler, zones and notes builds into compiles and renders with 0 RT violations.
@Suite("Instrument slot and the engine")
@MainActor
struct InstrumentEngineTests {
    init() { TestCommands.register() }

    @Test("DW-140, MODEL-005: the real engine accepts a MIDI track with a sampler, zones and notes built through commands")
    func realEngineAcceptsSampler() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "instrument-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "sine.wav")
        try writeTestSineWAV(wav, frames: 48_000)

        let engine = try EngineClient(.offline(sampleRate: 48_000))
        let store = ProjectStore(project: Project(name: "instrument"))
        let sync = try store.attachEngine(engine)
        let id = store.project.ids.next
        let loaded = try #require(await engine.waitForJob(engine.loadAsset(id, path: wav.path)).asset)
        try store.perform(ImportAsset(asset: AssetRef(id: id, path: wav.path, channels: Int(loaded.channels),
                                                      originalSampleRate: loaded.fileSampleRate, frames: loaded.fileFrames)))
        try store.perform(AddTrack(name: "Keys", kind: .midi))
        let track = store.project.tracks[0].id
        try store.perform(SetInstrument(trackID: track, device: .builtin(.sampler),
                                        zones: [SamplerZone(assetID: id, rootKey: 69, tune: 0.5, gain: 0.8, loopStart: 0, loopEnd: 48)]))
        try store.perform(AddClip(trackID: track, start: 0, length: 3840))
        let clip = store.project.tracks[0].clips[0].id
        try store.perform(AddNotes(clipID: clip, notes: [.init(start: 0, length: 1920, pitch: 69), .init(start: 960, length: 960, pitch: 81)]))
        _ = sync.pollEvents()
        await sync.settle()
        let status = await engine.graphApplied(engine.graphStatus().submittedVersion)
        #expect(status.lastError == nil, "the engine compiled the graph, sampler config included")

        let path = dir.appending(path: "out.wav").path
        let result = try #require(await engine.waitForJob(
            engine.renderOffline(from: 0, to: 3840, spec: ExportSpec(path: path, blockSize: 256, tailEnabled: false))).render)
        #expect(result.rtViolations == 0)
        // Whether this is audible depends on MIDI routing in the engine (DW-099), not on the model.
    }
}

/// A mono 32-bit float WAV of a 1 kHz sine at half scale, 48 kHz.
func writeTestSineWAV(_ url: URL, frames: Int) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 4))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(3)); append(UInt16(1))
    append(UInt32(48_000)); append(UInt32(192_000)); append(UInt16(4)); append(UInt16(32))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 4))
    for i in 0..<frames { append(Float(0.5 * sin(2 * Double.pi * 1000 * Double(i) / 48_000)).bitPattern) }
    try data.write(to: url)
}
