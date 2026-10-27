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
    ]

    @Test("MODEL-006: built-in type strings are stable and unique")
    func stableTypeStrings() {
        // Renaming one breaks saved scripts and the wire format; add a migration instead.
        #expect(CommandRegistry.builtIn.map { $0.type } == ["Composite", "RenameTrack"])
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
        var project = Project()
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
