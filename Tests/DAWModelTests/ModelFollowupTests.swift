import Foundation
import Testing

@testable import DAWModel

// T-099 model fixes (docs/autobuild/DECISIONS.md "T-099 model fixes"): RemoveAsset and take clips
// (DW-258), take offsets on a session-rate change (DW-259), RestoreSessionSampleRate's optional
// arrays (DW-185), Bus/MasterChannel without an `automation` key (DW-235), and validate()'s
// inputPair (DW-199) and insert kinds (DW-251). MODEL-005, MODEL-031, MODEL-032.

/// 48 kHz, an audio track "Mic" with a take folder of two audio takes (offsets 0 and 48 080) on
/// one asset, and a second asset no one uses.
private func takeProject() throws -> (Project, track: NodeIDValue, used: ModelID, unused: ModelID) {
    var p = Project()
    let used = AssetRef(id: p.ids.next, path: "/tmp/take.caf", channels: 2, originalSampleRate: 48_000, frames: 480_000)
    _ = try ImportAsset(asset: used).apply(to: &p)
    let unused = AssetRef(id: p.ids.next, path: "/tmp/other.wav", channels: 2, originalSampleRate: 44_100, frames: 44_100)
    _ = try ImportAsset(asset: unused).apply(to: &p)
    _ = try AddTrack(name: "Mic", kind: .audio).apply(to: &p)
    let track = p.tracks[0].id
    _ = try CreateTakeFolder(trackID: track, takes: [
        .init(start: 0, length: 1920, assetID: used.id, sourceOffsetSamples: 0),
        .init(start: 0, length: 1920, assetID: used.id, sourceOffsetSamples: 48_080),
    ]).apply(to: &p)
    try p.validate()
    return (p, track, used.id, unused.id)
}

private func takeOffsets(_ p: Project) -> [Int64] {
    p.tracks.flatMap(\.takeFolders).flatMap(\.takes).compactMap {
        if case .audio(let clip) = $0.clip { clip.sourceOffsetSamples } else { nil }
    }
}

@Suite("Model follow-ups (T-099)")
@MainActor
struct ModelFollowupTests {
    init() { TestCommands.register() }

    // MARK: DW-258

    @Test("DW-258, MODEL-031: RemoveAsset refuses an asset a take clip uses (like a clip); validate() never sees a dangling take")
    func removeAssetTakes() throws {
        var (p, track, used, unused) = try takeProject()
        let before = p
        #expect(throws: DAWError.self) { try RemoveAsset(assetID: used).applyChecked(to: &p) }
        #expect(p == before)
        do {
            _ = try RemoveAsset(assetID: used).apply(to: &p)
            Issue.record("RemoveAsset removed an asset a take uses")
        } catch {
            #expect("\(error)".contains("take"))
        }
        // An asset nobody uses still goes (and comes back exactly).
        try expectApplyRoundTrip(RemoveAsset(assetID: unused), on: before)
        // Once the folder is gone, the take's asset can go too, and the project stays valid.
        var q = before
        let folder = try #require(q.tracks[0].takeFolders.first).id
        _ = try RemoveTakeFolder(folderID: folder).applyChecked(to: &q)
        let removed = try expectApplyRoundTrip(RemoveAsset(assetID: used), on: q)
        #expect(!removed.assets.contains { $0.id == used })
        #expect(removed.tracks[0].id == track)
    }

    @Test("DW-258: through the undo stack (Debug validate() after every command), a refused removal leaves no undo entry")
    func removeAssetUndoStack() throws {
        let (p, _, used, _) = try takeProject()
        let stack = UndoStack()
        var q = p
        #expect(throws: DAWError.self) { try stack.perform(RemoveAsset(assetID: used), on: &q) }
        #expect(q == p && !stack.canUndo)
    }

    // MARK: DW-259

    @Test("DW-259, DW-126: SetSessionSampleRate rescales take clips' offsets like clips; the inverse (through JSON) restores them exactly")
    func sessionRateTakes() throws {
        let (original, _, _, _) = try takeProject()
        var p = original
        let inverse = try SetSessionSampleRate(sampleRate: 44_100).apply(to: &p)
        // 48 080 × 147/160 = 44 173.5 → 44 174 (halves up, Project.rescaleSamples).
        #expect(takeOffsets(p) == [0, 44_174])
        try p.validate()
        let restore = try #require(try CommandRegistry.decode(CommandRegistry.encode(inverse)) as? RestoreSessionSampleRate)
        #expect(restore.clipOffsets.map(\.sourceOffsetSamples) == [0, 48_080])
        let redo = try restore.apply(to: &p)
        #expect(p == original, "the inverse restores the takes' exact offsets")
        _ = try CommandRegistry.decode(CommandRegistry.encode(redo)).apply(to: &p)
        #expect(takeOffsets(p) == [0, 44_174])

        // A change there and back without the inverse can be a sample off; the inverse is exact.
        var bounced = original
        _ = try SetSessionSampleRate(sampleRate: 44_100).apply(to: &bounced)
        _ = try SetSessionSampleRate(sampleRate: 48_000).apply(to: &bounced)
        #expect(takeOffsets(bounced) == [0, 48_081])
    }

    @Test("DW-259, MODEL-031: RestoreSessionSampleRate sets a take clip's offset by its clip ID; a MIDI take's clip is refused")
    func restoreTakeOffset() throws {
        var (p, _, _, _) = try takeProject()
        let takeClip = try #require(p.tracks[0].takeFolders.first?.takes.last?.clip.id)
        _ = try RestoreSessionSampleRate(sampleRate: 48_000, clipOffsets: [.init(clipID: takeClip, sourceOffsetSamples: 7)])
            .applyChecked(to: &p)
        #expect(takeOffsets(p) == [0, 7])

        _ = try AddTrack(name: "Keys", kind: .midi).apply(to: &p)
        _ = try CreateTakeFolder(trackID: p.tracks[1].id, takes: [.init(start: 0, length: 960, notes: [])]).apply(to: &p)
        let midiClip = try #require(p.tracks[1].takeFolders.first?.takes.first?.clip.id)
        let before = p
        #expect(throws: DAWError.invalidArgument("clip \(midiClip) is not an audio clip")) {
            try RestoreSessionSampleRate(sampleRate: 48_000, clipOffsets: [.init(clipID: midiClip, sourceOffsetSamples: 1)])
                .applyChecked(to: &p)
        }
        #expect(p == before)
    }

    // MARK: DW-185

    @Test("DW-185, MODEL-006: RestoreSessionSampleRate JSON may leave out clipOffsets and zoneLoops (missing = empty); encoding still writes both")
    func restoreOptionalArrays() throws {
        let json = Data(#"{"type": "RestoreSessionSampleRate", "sampleRate": 44100}"#.utf8)
        let decoded = try #require(try CommandRegistry.decode(json) as? RestoreSessionSampleRate)
        #expect(decoded.sampleRate == 44_100 && decoded.clipOffsets.isEmpty && decoded.zoneLoops.isEmpty)
        let partial = Data(#"{"type": "RestoreSessionSampleRate", "sampleRate": 48000, "zoneLoops": []}"#.utf8)
        #expect((try CommandRegistry.decode(partial) as? RestoreSessionSampleRate)?.clipOffsets == [])
        let encoded = try JSONSerialization.jsonObject(with: CommandRegistry.encode(decoded)) as? [String: Any]
        #expect(encoded?["clipOffsets"] != nil && encoded?["zoneLoops"] != nil)
        // It applies like any other: the rate changes.
        var (p, _, _, _) = try takeProject()
        _ = try decoded.applyChecked(to: &p)
        #expect(p.sessionSampleRate == 44_100)
        // A missing sampleRate is still an error.
        #expect(throws: DAWError.self) {
            try CommandRegistry.decode(Data(#"{"type": "RestoreSessionSampleRate"}"#.utf8))
        }
    }

    // MARK: DW-235

    @Test("DW-235: Bus and MasterChannel decode a missing automation key as no lanes; encoding keeps the key (byte-identical files)")
    func busMasterAutomationOptional() throws {
        let bus = Bus(id: 4, name: "FX", inserts: [DeviceSlot(id: 5, kind: .builtin(.reverb))])
        let master = MasterChannel(id: 1, inserts: [DeviceSlot(id: 6, kind: .builtin(.eq))])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (value, type) in [(try encoder.encode(bus), "bus"), (try encoder.encode(master), "master")] {
            var object = try #require(try JSONSerialization.jsonObject(with: value) as? [String: Any], "\(type)")
            #expect(object["automation"] != nil, "\(type) writes the key")
            object.removeValue(forKey: "automation")
            let stripped = try JSONSerialization.data(withJSONObject: object)
            if type == "bus" {
                let decoded = try JSONDecoder().decode(Bus.self, from: stripped)
                #expect(decoded == bus)
                #expect(try encoder.encode(decoded) == value)  // re-encoding is byte-identical
            } else {
                let decoded = try JSONDecoder().decode(MasterChannel.self, from: stripped)
                #expect(decoded == master)
                #expect(try encoder.encode(decoded) == value)
            }
        }
        // Other keys stay required.
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Bus.self, from: Data(#"{"id": 4}"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MasterChannel.self, from: Data(#"{"id": 1}"#.utf8)) }
    }

    @Test("DW-235, MODEL-040: a whole project with lanes on a bus and the master round-trips through JSON byte for byte")
    func projectRoundTrip() throws {
        var p = Project()
        _ = try AddBus(name: "FX").apply(to: &p)
        let bus = p.buses[0].id
        _ = try AddAutomationPoints(target: .strip(channel: bus, param: .gain), points: [.init(tick: 0, value: 0.5)]).apply(to: &p)
        _ = try AddAutomationPoints(target: .strip(channel: p.master.id, param: .pan), points: [.init(tick: 960, value: 0.25)]).apply(to: &p)
        #expect(!p.buses[0].automation.isEmpty && !p.master.automation.isEmpty)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(p)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == p)
        #expect(try encoder.encode(decoded) == data)
    }

    // MARK: DW-199

    @Test("DW-199, MODEL-032: validate() checks Track.inputPair ≤ 15 (files and RestoreTrack, not only ArmTrack)")
    func inputPairChecked() throws {
        var p = Project()
        _ = try AddTrack(name: "Mic", kind: .audio).apply(to: &p)
        p.tracks[0].inputPair = Track.maxInputPair
        try p.validate()
        p.tracks[0].inputPair = Track.maxInputPair + 1
        #expect(throws: DAWError.self) { try p.validate() }

        // RestoreTrack checks the track like validate() does.
        var q = Project()
        var track = Track(id: q.ids.allocate(), name: "Hand-edited", kind: .audio)
        track.inputPair = 16
        #expect(throws: DAWError.self) { try RestoreTrack(track: track, index: 0).applyChecked(to: &q) }
        #expect(q.tracks.isEmpty)
        track.inputPair = 15
        _ = try RestoreTrack(track: track, index: 0).applyChecked(to: &q)
        try q.validate()
    }

    // MARK: DW-251

    @Test("DW-251, MODEL-032: validate() rejects the sampler and structural built-ins in any insert chain; effects, the metronome and plugins pass")
    func insertKindsValidated() throws {
        var p = Project()
        _ = try AddTrack(name: "Audio", kind: .audio).apply(to: &p)
        _ = try AddBus(name: "Bus").apply(to: &p)
        let allowed: [DeviceSlot.Kind] = [.builtin(.gain), .builtin(.eq), .builtin(.compressor), .builtin(.delay),
                                          .builtin(.reverb), .builtin(.metronome),
                                          .au(AUDescriptor(identifier: "aufx:dely:appl", name: "Delay"))]
        let refused: [NodeKind] = [.sampler, .audioClipPlayer, .midiClipPlayer, .channelStrip, .auPlugin, .vst3Plugin,
                                   .master, .bus]
        #expect(Set(allowed.compactMap { if case .builtin(let k) = $0 { k } else { nil } }).union(refused)
                == Set(NodeKind.allCases), "every built-in kind is covered")
        for channel in 0..<3 {
            func with(_ kind: DeviceSlot.Kind) -> Project {
                var q = p
                let slot = DeviceSlot(id: q.ids.allocate(), kind: kind)
                switch channel {
                case 0: q.tracks[0].inserts.append(slot)
                case 1: q.buses[0].inserts.append(slot)
                default: q.master.inserts.append(slot)
                }
                return q
            }
            for kind in allowed { try with(kind).validate() }
            for kind in refused {
                #expect(throws: DAWError.self, "\(kind) on channel \(channel)") { try with(.builtin(kind)).validate() }
            }
        }
    }

    @Test("DW-251, MODEL-031: RestoreDevice, RestoreTrack and RestoreBus refuse a sampler insert; RestoreDevice may put a metronome back")
    func restoreChecksInsertKinds() throws {
        var p = Project()
        _ = try AddTrack(name: "Audio", kind: .audio).apply(to: &p)
        let track = p.tracks[0].id
        let before = p

        let sampler = DeviceSlot(id: p.ids.next, kind: .builtin(.sampler))
        #expect(throws: DAWError.self) { try RestoreDevice(channel: track, index: 0, slot: sampler).applyChecked(to: &p) }
        #expect(p == before)
        let metronome = DeviceSlot(id: p.ids.next, kind: .builtin(.metronome))
        try expectApplyRoundTrip(RestoreDevice(channel: track, index: 0, slot: metronome), on: p)
        // InsertDevice stays stricter: no metronome.
        #expect(throws: DAWError.self) { try InsertDevice(channel: track, device: .builtin(.metronome)).applyChecked(to: &p) }

        var q = Project()
        var withSampler = Track(id: q.ids.allocate(), name: "Bad", kind: .audio)
        withSampler.inserts = [DeviceSlot(id: q.ids.allocate(), kind: .builtin(.sampler))]
        #expect(throws: DAWError.self) { try RestoreTrack(track: withSampler, index: 0).applyChecked(to: &q) }
        let bus = Bus(id: q.ids.allocate(), name: "Bad", inserts: [DeviceSlot(id: q.ids.allocate(), kind: .builtin(.channelStrip))])
        #expect(throws: DAWError.self) { try RestoreBus(bus: bus, index: 0).applyChecked(to: &q) }
        #expect(q.tracks.isEmpty && q.buses.isEmpty)
    }

    @Test("DW-251: the metronome_click fixture's track (a metronome insert) is still valid")
    func metronomeClickStillValid() throws {
        var p = Project()
        let json = #"""
        {"type": "RestoreTrack", "index": 0, "track": {"id": 2, "name": "Click", "kind": "audio", "color": {"red": 0.5, "green": 0.5, "blue": 0.5}, "clips": [], "takeFolders": [], "inserts": [{"id": 3, "kind": {"format": "builtin", "node": "metronome"}, "params": [{"index": 0, "value": 1}, {"index": 1, "value": 0.5}, {"index": 2, "value": 2}], "bypass": false}], "strip": {"gain": 1, "pan": 0, "mute": false, "solo": false, "phaseInvert": false}, "sends": [], "output": {"kind": "master"}, "armed": false, "monitoring": "auto", "automation": []}}
        """#
        _ = try CommandRegistry.decode(Data(json.utf8)).applyChecked(to: &p)
        try p.validate()
    }
}
