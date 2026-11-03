import DAWModel
import Foundation
import Testing

@Suite("CommandRegistry")
struct CommandRegistryTests {
    init() { TestCommands.register() }

    /// One sample of each built-in command. A new built-in without a sample fails `everyBuiltIn`.
    static let builtInSamples: [any Command] = [
        CompositeCommand("Two", [RenameTrack(trackID: 3, name: "A"), RenameTrack(trackID: 4, name: "B")]),
        RenameTrack(trackID: 7, name: "Lead Vox"),
        // T-022: routing
        AddTrack(name: "Bass", kind: .midi, index: 2, output: .bus(4), color: TrackColor(red: 1, green: 0, blue: 0)),
        AddTrack(name: "Bare", kind: .audio),
        RemoveTrack(trackID: 3),
        RestoreTrack(track: RoutingProject.make().tracks[0], index: 0),
        MoveTrack(trackID: 3, index: 1),
        SetTrackOutput(channelID: 3, output: .master),
        AddBus(name: "FX", index: 0, output: .bus(2)),
        RemoveBus(busID: 2),
        RestoreBus(bus: Bus(id: 2, name: "A", sends: [Send(id: 9, target: 4)]), index: 1),
        AddSend(channelID: 3, busID: 2, level: 0.5, tap: .preFader),
        RemoveSend(sendID: 9),
        RestoreSend(channelID: 3, send: Send(id: 9, target: 2, level: 0.25), index: 0),
        SetSendLevel(sendID: 9, level: 0.75),
        SetSendTap(sendID: 9, tap: .postFader),
        SetSidechain(slotID: 11, source: SidechainRef(source: 3, tap: .preFader)),
        SetSidechain(slotID: 11, source: nil),
        SetParam(target: .strip(channel: 3, param: .pan), value: -0.5),
        SetParam(target: .sendLevel(send: 9), value: 1),
        SetParam(target: .device(slot: 11, index: 2), value: nil),
        // T-030: assets, clips, tempo, loop
        ImportAsset(asset: AssetRef(id: 12, path: "Audio/a.wav", channels: 2, originalSampleRate: 44_100, frames: 1000)),
        ImportAsset(asset: AssetRef(id: 12, path: "/abs/a.wav", channels: 1, originalSampleRate: 48_000, frames: 0), index: 0),
        RemoveAsset(assetID: 12),
        AddClip(trackID: 3, start: 960, length: 1920, assetID: 12, sourceOffsetSamples: 10, gain: 0.5, fadeIn: 1, fadeOut: 2),
        AddClip(trackID: 3, start: 0),
        RemoveClip(clipID: 20),
        RestoreClip(trackID: 3, clip: ClipProject.make().keys.clips[0]),
        MoveClip(clipID: 20, start: 480, trackID: 4),
        MoveClip(clipID: 20, start: 0),
        ResizeClip(clipID: 20, start: 240, length: 720),
        SplitClip(clipID: 20, at: 1000),
        SetClip(clip: ClipProject.make().gtr.clips[1]),
        SetClipGain(clipID: 20, gain: 0.7),
        SetClipFades(clipID: 20, fadeIn: 0, fadeOut: 96),
        SetTempoEvent(tick: 3840, bpm: 92.5),
        RemoveTempoEvent(tick: 3840),
        SetTimeSignature(tick: 7680, numerator: 7, denominator: 8),
        RemoveTimeSignature(tick: 7680),
        SetLoop(start: 0, end: 3840),
        SetLoop(loop: nil),
        RestoreLoop(loop: LoopRange(start: 960, end: 1920, isEnabled: false)),
        RestoreLoop(loop: nil),
        AddNotes(clipID: 5, notes: [.init(start: -480, length: 480, pitch: 60, velocity: 90, channel: 1), .init(start: 0, length: 1, pitch: 0)]),
        RemoveNotes(clipID: 5, noteIDs: [6, 7]),
        RestoreNotes(clipID: 5, notes: [Note(id: 6, start: -10, length: 480, pitch: 60, velocity: 1, channel: 15)]),
        MoveNotes(clipID: 5, noteIDs: [6], ticks: -960, semitones: -12),
        SetNoteProps(clipID: 5, notes: [.init(id: 6, start: 3, length: 4, pitch: 5, velocity: 6, channel: 7), .init(id: 8, velocity: 9)]),
        SetInstrument(trackID: 2, device: .builtin(.sampler), zones: [SamplerZone(assetID: 1, rootKey: 69, tune: 0.5, loopStart: 0, loopEnd: 9)]),
        SetInstrument(trackID: 2, device: .vst3(VST3Descriptor(identifier: "/s.vst3#1", name: "Synth"))),
        RemoveInstrument(trackID: 2),
        RestoreInstrument(trackID: 2, instrument: DeviceSlot(id: 4, kind: .builtin(.sampler), params: [ParamValue(index: 0, value: 0.5)],
                                                             zones: [SamplerZone(assetID: 1)])),
        RestoreInstrument(trackID: 2, instrument: nil),
        SetSamplerZones(slotID: 4, zones: [SamplerZone(assetID: 1, lowKey: 10, highKey: 20, lowVel: 30, highVel: 40, gain: 0.5)]),
        SetSamplerZones(slotID: 4, zones: []),
        // T-026 (TIME-010)
        SetMetronome(enabled: true, level: 0.5, accent: 1.5),
        SetMetronome(enabled: false),
    ]

    @Test("MODEL-006: built-in type strings are stable and unique")
    func stableTypeStrings() {
        // Renaming one breaks saved scripts and the wire format; add a migration instead.
        #expect(CommandRegistry.builtIn.map { $0.type } == [
            "Composite", "RenameTrack",
            "AddTrack", "RemoveTrack", "RestoreTrack", "MoveTrack", "SetTrackOutput", "AddBus", "RemoveBus", "RestoreBus",
            "AddSend", "RemoveSend", "RestoreSend", "SetSendLevel", "SetSendTap", "SetSidechain", "SetParam",
            "ImportAsset", "RemoveAsset", "AddClip", "RemoveClip", "RestoreClip", "MoveClip", "ResizeClip", "SplitClip",
            "SetClip", "SetClipGain", "SetClipFades", "SetTempoEvent", "RemoveTempoEvent", "SetTimeSignature",
            "RemoveTimeSignature", "SetLoop", "RestoreLoop",
            "AddNotes", "RemoveNotes", "RestoreNotes", "MoveNotes", "SetNoteProps", "SetInstrument", "RemoveInstrument",
            "RestoreInstrument", "SetSamplerZones",
            "SetMetronome",
        ])
        let all = CommandRegistry.registered.map { $0.type }
        #expect(Set(all).count == all.count)
    }

    @Test("MODEL-006: every built-in command round-trips through CommandRegistry.decode")
    func everyBuiltIn() throws {
        #expect(Set(Self.builtInSamples.map { Swift.type(of: $0).type }) == Set(CommandRegistry.builtIn.map { $0.type }))
        for command in Self.builtInSamples {
            try expectRoundTrip(command)
        }
    }

    @Test("MODEL-006: test commands, including ones holding whole tracks and clips, round-trip")
    func testCommandsRoundTrip() throws {
        var project = Project.withTestAsset()
        _ = try TestAddTrack(name: "A").apply(to: &project)
        let id = project.tracks[0].id
        _ = try TestAddClip(trackID: id, start: 480, length: 960).apply(to: &project)
        try expectRoundTrip(TestInsertTrack(track: project.tracks[0], index: 0))
        try expectRoundTrip(TestInsertClip(trackID: id, clip: project.tracks[0].clips[0], index: 0))
        try expectRoundTrip(TestNudgeClip(trackID: id, clipID: 9, delta: -12))
        try expectRoundTrip(CompositeCommand("Nested", [CompositeCommand("Inner", [TestSetGain(trackID: id, gain: 0.5)])]))
    }

    @Test("MODEL-006: the wire form is the command's fields plus \"type\"")
    func wireShape() throws {
        let data = try CommandRegistry.encode(RenameTrack(trackID: 7, name: "Vox"))
        #expect(String(decoding: data, as: UTF8.self) == #"{"name":"Vox","trackID":7,"type":"RenameTrack"}"#)
        let decoded = try CommandRegistry.decode(Data(#"{"type":"RenameTrack","trackID":2,"name":"Bass"}"#.utf8))
        let rename = try #require(decoded as? RenameTrack)
        #expect(rename.trackID == 2 && rename.name == "Bass")
    }

    @Test("MODEL-006: unknown types and malformed JSON throw DAWError")
    func decodeErrors() {
        #expect(throws: DAWError.unknownCommandType("Nope")) {
            try CommandRegistry.decode(Data(#"{"type":"Nope"}"#.utf8))
        }
        // An unknown type nested in a composite is reported as such, too.
        #expect(throws: DAWError.unknownCommandType("Nope")) {
            try CommandRegistry.decode(Data(#"{"type":"Composite","label":"x","commands":[{"type":"Nope"}]}"#.utf8))
        }
        for json in [#"{"type":"RenameTrack","trackID":"seven"}"#, #"{"trackID":1}"#, "not json"] {
            #expect("\(json)", performing: { try CommandRegistry.decode(Data(json.utf8)) }, throws: { error in
                if case .malformedCommand = error as? DAWError { true } else { false }
            })
        }
    }

    private func expectRoundTrip(_ command: any Command) throws {
        let data = try CommandRegistry.encode(command)
        let decoded = try CommandRegistry.decode(data)
        #expect(Swift.type(of: decoded) == Swift.type(of: command))
        #expect(decoded.label == command.label)
        // Encoding is sorted-keys, so equal commands give equal bytes.
        #expect(try CommandRegistry.encode(decoded) == data, "\(String(decoding: data, as: UTF8.self))")
    }
}
