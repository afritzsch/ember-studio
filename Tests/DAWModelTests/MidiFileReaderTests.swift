import Foundation
import Testing

@testable import DAWModel

// T-128: MODEL-047, reading Standard MIDI Files into 960-PPQ notes and importing them as one
// undoable [AddClip, AddNotes] composite. The files are built here as bytes (`SMF`), so each test
// shows exactly what it feeds the reader.

/// Builds Standard MIDI Files byte by byte.
enum SMF {
    static func vlq(_ value: Int) -> [UInt8] {
        var v = value, out: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            out.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return out
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    static func header(format: UInt16 = 0, tracks: UInt16 = 1, division: UInt16 = 960) -> [UInt8] {
        Array("MThd".utf8) + be32(6) + be16(format) + be16(tracks) + be16(division)
    }

    /// A track chunk of `events`, each `(delta, bytes)`, ending with end-of-track unless told not to.
    static func track(_ events: [(Int, [UInt8])], endOfTrack: (Int)? = 0) -> [UInt8] {
        var body: [UInt8] = []
        for (delta, bytes) in events { body += vlq(delta) + bytes }
        if let eot = endOfTrack { body += vlq(eot) + [0xFF, 0x2F, 0x00] }
        return Array("MTrk".utf8) + be32(UInt32(body.count)) + body
    }

    static func file(format: UInt16 = 0, division: UInt16 = 960, _ tracks: [[UInt8]]) -> [UInt8] {
        header(format: format, tracks: UInt16(tracks.count), division: division) + tracks.joined()
    }

    static func on(_ ch: UInt8 = 0, _ pitch: UInt8, _ vel: UInt8 = 100) -> [UInt8] { [0x90 | ch, pitch, vel] }
    static func off(_ ch: UInt8 = 0, _ pitch: UInt8, _ vel: UInt8 = 64) -> [UInt8] { [0x80 | ch, pitch, vel] }
    static let tempo120: [UInt8] = [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]
    static let timeSig34: [UInt8] = [0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08]
}

private typealias N = MidiFile.Note

private func note(_ start: Int64, _ length: Int64, _ pitch: UInt8, vel: UInt8 = 100, ch: UInt8 = 0) -> N {
    N(start: Tick(start), length: Tick(length), pitch: pitch, velocity: vel, channel: ch)
}

private func read(_ bytes: [UInt8]) throws -> MidiFile { try MidiFileReader.read(bytes: bytes) }

private func readError(_ bytes: [UInt8]) -> MidiFileError? {
    do { _ = try MidiFileReader.read(bytes: bytes); return nil } catch { return error }
}

@Suite("MIDI file reader and import (MODEL-047)")
struct MidiFileReaderTests {
    // MARK: Formats and PPQ

    @Test("MODEL-047: format 0 at 960 PPQ reads note pairs at their ticks, channel and velocity kept")
    func format0() throws {
        let file = try read(SMF.file([SMF.track([
            (0, SMF.on(0, 60, 90)), (480, SMF.off(0, 60)),
            (0, SMF.on(3, 64, 70)), (960, SMF.off(3, 64)),
        ])]))
        #expect(file.notes == [note(0, 480, 60, vel: 90), note(480, 960, 64, vel: 70, ch: 3)])
        #expect(file.lengthTicks == Tick(3840))
    }

    @Test("MODEL-047: format 1 merges every track (tempo track, two note tracks) into one sorted list")
    func format1Merged() throws {
        let file = try read(SMF.file(format: 1, [
            SMF.track([(0, SMF.tempo120), (0, SMF.timeSig34)], endOfTrack: 7680),
            SMF.track([(960, SMF.on(0, 62)), (960, SMF.off(0, 62))]),
            SMF.track([(0, SMF.on(9, 36, 127)), (240, SMF.off(9, 36)), (720, SMF.on(9, 38)), (240, SMF.off(9, 38))]),
        ]))
        #expect(file.notes == [note(0, 240, 36, vel: 127, ch: 9), note(960, 240, 38, ch: 9), note(960, 960, 62)])
        // The tempo track's end of track at 7680 is the last event: two bars exactly.
        #expect(file.lengthTicks == Tick(7680))
    }

    @Test("MODEL-047: the same music at PPQ 96, 480 and 960 reads the same 960-PPQ notes", arguments: [96, 480, 960])
    func anyPPQ(ppq: Int) throws {
        let q = ppq  // ticks per quarter in the file
        let file = try read(SMF.file(division: UInt16(ppq), [SMF.track([
            (0, SMF.on(0, 60)), (q / 2, SMF.off(0, 60)),        // eighth at 0
            (q / 2, SMF.on(0, 67)), (q * 3, SMF.off(0, 67)),    // dotted half at beat 2
            (q / 4, SMF.on(0, 72)), (q / 4, SMF.off(0, 72)),    // sixteenth at beat 5¼
        ])]))
        #expect(file.notes == [note(0, 480, 60), note(960, 2880, 67), note(4080, 240, 72)])
        #expect(file.lengthTicks == Tick(7680))
    }

    @Test("MODEL-047: odd PPQs round to the nearest 960-PPQ tick, halves up")
    func rounding() throws {
        // PPQ 1920: file tick 1 is half a tick (→ 1), 3 is 1.5 (→ 2), 4 is exactly 2.
        let fine = try read(SMF.file(division: 1920, [SMF.track([(1, SMF.on(0, 60)), (2, SMF.off(0, 60)), (1, SMF.on(0, 61)), (0, SMF.off(0, 61))])]))
        #expect(fine.notes == [note(1, 1, 60), note(2, 1, 61)])  // 61 is zero-long in the file: one tick
        // PPQ 7: one file tick is 137.14 ticks; 3 is 411.43 → 411, 4 is 548.57 → 549.
        let coarse = try read(SMF.file(division: 7, [SMF.track([(3, SMF.on(0, 60)), (1, SMF.off(0, 60))])]))
        #expect(coarse.notes == [note(411, 138, 60)])
    }

    // MARK: Events

    @Test("MODEL-047: running status, including velocity-0 note-ons as offs, reads like full status bytes")
    func runningStatus() throws {
        let file = try read(SMF.file([SMF.track([
            (0, [0x90, 60, 100]), (0, [64, 90]), (0, [67, 80]),  // a chord under one status byte
            (480, [60, 0]), (0, [64, 0]), (0, [67, 0]),           // velocity 0 = note-off
            (0, [0xB0, 7, 100]), (0, [10, 64]),                   // a CC under running status
            (0, [0x91, 48, 50]), (240, [48, 0]),
        ])]))
        #expect(file.notes == [note(0, 480, 60), note(0, 480, 64, vel: 90), note(0, 480, 67, vel: 80), note(480, 240, 48, vel: 50, ch: 1)])
    }

    @Test("MODEL-047: a velocity-0 note-on ends the note like a note-off")
    func velocityZeroOff() throws {
        let file = try read(SMF.file([SMF.track([(0, SMF.on(0, 60)), (360, SMF.on(0, 60, 0))])]))
        #expect(file.notes == [note(0, 360, 60)])
    }

    @Test("MODEL-047: tempo, time signature, CC, pitch bend, program change, pressure and SysEx are skipped")
    func ignoredEvents() throws {
        let file = try read(SMF.file([SMF.track([
            (0, SMF.tempo120), (0, SMF.timeSig34), (0, [0xF0, 0x03, 0x7E, 0x09, 0xF7]),
            (0, [0xC0, 5]), (0, SMF.on(0, 60)), (100, [0xE0, 0x00, 0x60]), (100, [0xB0, 1, 64]),
            (40, [0xD0, 30]), (0, [0xA0, 60, 20]), (0, [0xF7, 0x01, 0x42]),
            (0, [0xFF, 0x03, 0x04] + Array("Lead".utf8)), (240, SMF.off(0, 60)),
        ])]))
        #expect(file.notes == [note(0, 480, 60)])
    }

    @Test("MODEL-047: an unmatched note-on ends at the file's last event; at the last event itself it is one tick")
    func unmatched() throws {
        let file = try read(SMF.file(format: 1, [
            SMF.track([(0, SMF.on(0, 60)), (480, SMF.on(0, 62))], endOfTrack: 0),
            SMF.track([(0, SMF.on(0, 64)), (960, SMF.off(0, 64))], endOfTrack: 1920),  // last event: 2880
        ]))
        #expect(file.notes == [note(0, 2880, 60), note(0, 960, 64), note(480, 2400, 62)])

        let atEnd = try read(SMF.file([SMF.track([(3840, SMF.on(0, 60))], endOfTrack: 0)]))
        #expect(atEnd.notes == [note(3840, 1, 60)])
        #expect(atEnd.lengthTicks == Tick(7680))  // the note's tick past the bar line needs a second bar
    }

    @Test("MODEL-047: overlapping same-pitch notes end the earlier one, in a track and across tracks and channels")
    func overlapping() throws {
        // In one track: a retrigger before the note-off ends the first note; the second off then
        // ends the second note, and a stray off is ignored.
        let retrigger = try read(SMF.file([SMF.track([
            (0, SMF.on(0, 60)), (240, SMF.on(0, 60, 80)), (240, SMF.off(0, 60)), (240, SMF.off(0, 60)),
        ])]))
        #expect(retrigger.notes == [note(0, 240, 60), note(240, 240, 60, vel: 80)])

        // Across tracks and channels: the merged list has no same-pitch overlap.
        let merged = try read(SMF.file(format: 1, [
            SMF.track([(0, SMF.on(0, 60)), (960, SMF.off(0, 60))]),
            SMF.track([(480, SMF.on(2, 60, 70)), (960, SMF.off(2, 60)), (0, SMF.on(0, 61)), (100, SMF.off(0, 61))]),
        ]))
        #expect(merged.notes == [note(0, 480, 60), note(480, 960, 60, vel: 70, ch: 2), note(1440, 100, 61)])

        // Two same-pitch notes on one tick are one note: the longer.
        let unison = try read(SMF.file(format: 1, [
            SMF.track([(0, SMF.on(0, 60, 50)), (240, SMF.off(0, 60))]),
            SMF.track([(0, SMF.on(1, 60, 90)), (720, SMF.off(1, 60))]),
        ]))
        #expect(unison.notes == [note(0, 720, 60, vel: 90, ch: 1)])
    }

    @Test("MODEL-047: length is the last event rounded up to a whole 4/4 bar, at least one bar")
    func length() throws {
        #expect(try read(SMF.file([SMF.track([])])).lengthTicks == Tick(3840))  // empty: one bar
        #expect(try read(SMF.file([])).lengthTicks == Tick(3840))  // no tracks at all
        #expect(try read(SMF.file([SMF.track([], endOfTrack: 3840)])).lengthTicks == Tick(3840))
        #expect(try read(SMF.file([SMF.track([], endOfTrack: 3841)])).lengthTicks == Tick(7680))
        // At PPQ 96 a 3/4 bar of 288 file ticks: 2880 ticks, so one 4/4 bar (the signature is ignored).
        #expect(try read(SMF.file(division: 96, [SMF.track([(0, SMF.timeSig34)], endOfTrack: 288)])).lengthTicks == Tick(3840))
    }

    @Test("MODEL-047: unknown chunks are skipped; bytes after the end of track and after the last track are ignored")
    func chunks() throws {
        let unknown = Array("XFIH".utf8) + SMF.be32(3) + [1, 2, 3]
        var trackChunk = SMF.track([(0, SMF.on(0, 60)), (480, SMF.off(0, 60))])
        // Junk inside the chunk after end of track.
        trackChunk += [0x12, 0x34]
        trackChunk.replaceSubrange(4..<8, with: SMF.be32(UInt32(trackChunk.count - 8)))
        let bytes = SMF.header(tracks: 1) + unknown + trackChunk + [0xDE, 0xAD]
        #expect(try read(bytes).notes == [note(0, 480, 60)])

        // A longer header's extra bytes are skipped.
        var longHeader = Array("MThd".utf8) + SMF.be32(8) + SMF.be16(0) + SMF.be16(1) + SMF.be16(960) + [0, 0]
        longHeader += SMF.track([(0, SMF.on(0, 60)), (10, SMF.off(0, 60))])
        #expect(try read(longHeader).notes == [note(0, 10, 60)])

        // A track that ends at its chunk's end without an end-of-track event still reads.
        #expect(try read(SMF.file([SMF.track([(0, SMF.on(0, 60)), (10, SMF.off(0, 60))], endOfTrack: nil)])).notes == [note(0, 10, 60)])
    }

    // MARK: Refusals

    @Test("MODEL-047: SMPTE time division is refused with a typed error")
    func smpteRefused() {
        // -25 fps, 40 ticks per frame.
        let bytes = SMF.header(division: 0xE728) + SMF.track([(0, SMF.on(0, 60)), (40, SMF.off(0, 60))])
        #expect(readError(bytes) == .smpteTimeDivision)
        #expect(MidiFileError.smpteTimeDivision.dawError.code == "invalidArgument")
    }

    @Test("MODEL-047: format 2, a missing header, zero PPQ and malformed or truncated bytes throw typed errors")
    func refusals() {
        #expect(readError(SMF.header(format: 2, tracks: 0)) == .unsupportedFormat(2))
        #expect(readError(Array("RIFF....".utf8)) == .notAMidiFile)
        #expect(readError([]) == .notAMidiFile)
        #expect(readError(SMF.header(division: 0)) == .malformed(offset: 12, detail: "zero ticks per quarter note"))
        // Header length below 6, or past the end.
        #expect(readError(Array("MThd".utf8) + SMF.be32(4) + [0, 0, 0, 1]) == .malformed(offset: 4, detail: "header length 4 is below 6"))
        #expect(readError(Array("MThd".utf8) + SMF.be32(6) + [0, 0]) == .truncated(offset: 10))
        // More tracks announced than present.
        #expect(readError(SMF.header(tracks: 2) + SMF.track([])) == .truncated(offset: 14 + 12))
        // A chunk length past the end.
        #expect(readError(SMF.header() + Array("MTrk".utf8) + SMF.be32(100) + [0, 0x90, 60, 1]) == .truncated(offset: 26))
        // A data byte with no running status, a status byte where data belongs, a real-time byte.
        if case .malformed? = readError(SMF.file([SMF.track([(0, [60, 100])])])) {} else { Issue.record("no running status") }
        if case .malformed? = readError(SMF.file([SMF.track([(0, [0x90, 60, 0x90])])])) {} else { Issue.record("status as data") }
        if case .malformed? = readError(SMF.file([SMF.track([(0, [0xF8])])])) {} else { Issue.record("real-time byte") }
        // Meta and SysEx cancel running status.
        if case .malformed? = readError(SMF.file([SMF.track([(0, SMF.on(0, 60)), (0, SMF.tempo120), (0, [60, 0])])])) {} else {
            Issue.record("running status after a meta event")
        }
        // A 5-byte variable-length quantity.
        let longVLQ = SMF.header() + Array("MTrk".utf8) + SMF.be32(8) + [0x81, 0x81, 0x81, 0x81, 0x00, 0xFF, 0x2F, 0x00]
        if case .malformed? = readError(longVLQ) {} else { Issue.record("5-byte VLQ") }
        // A meta length past the chunk's end (but inside the file) is truncation, not a read past it.
        let metaOverrun = SMF.header() + Array("MTrk".utf8) + SMF.be32(4) + [0x00, 0xFF, 0x01, 0x7F] + Array(repeating: 0x41, count: 200)
        #expect(readError(metaOverrun) == .truncated(offset: 26))
    }

    @Test("MODEL-047: events past the end of the timeline are refused, without overflow")
    func beyondTimeline() {
        // PPQ 1: each delta of 2^28 − 1 quarters is 2^28 · 960 ticks; 5 of them pass 2^40.
        let huge = Array(repeating: (0x0FFF_FFFF, [UInt8]([0xFF, 0x01, 0x00])), count: 6)
        #expect(readError(SMF.file(division: 1, [SMF.track(huge)])) == .beyondTimeline)
    }

    @Test("MODEL-047: read(contentsOf:) reads a file and reports a missing one as fileIO")
    func readsURL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("midifile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("one.mid")
        try Data(SMF.file([SMF.track([(0, SMF.on(0, 60)), (480, SMF.off(0, 60))])])).write(to: url)
        #expect(try MidiFileReader.read(contentsOf: url).notes == [note(0, 480, 60)])
        do {
            _ = try MidiFileReader.read(contentsOf: dir.appendingPathComponent("missing.mid"))
            Issue.record("a missing file read")
        } catch {
            guard case .fileIO = error else { Issue.record("expected fileIO, got \(error)"); return }
            #expect(error.dawError.code == "fileIO")
        }
    }

    // MARK: Fuzz

    /// SplitMix64: a fixed seed, so a failure reproduces.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    }

    @Test("MODEL-047: fuzz — truncated, mutated and garbage input never crashes or hangs, and results hold the invariants")
    func fuzz() {
        let seeds: [[UInt8]] = [
            SMF.file(format: 1, division: 480, [
                SMF.track([(0, SMF.tempo120), (0, SMF.timeSig34)], endOfTrack: 1920),
                SMF.track([(0, [0x90, 60, 100]), (0, [64, 90]), (240, [60, 0]), (0, [64, 0]), (0, [0xB0, 7, 99]), (0, [0xE0, 0, 64]),
                           (0, [0xF0, 2, 1, 0xF7]), (120, SMF.on(1, 72)), (0, SMF.on(1, 72)), (480, SMF.off(1, 72))]),
            ]),
            SMF.file([SMF.track([(0, SMF.on(9, 36)), (96, SMF.off(9, 36)), (300, SMF.on(9, 38)), (0, [0xFF, 0x03, 3, 65, 66, 67])])]),
            SMF.file(division: 7, [SMF.track([(0x0FFF_FFFF, SMF.on(0, 1)), (5, SMF.off(0, 1))])]),
        ]
        var rng = Rng(state: 0x7128_4D49_4449)
        var cases = 0, accepted = 0
        let started = ContinuousClock.now

        func check(_ bytes: [UInt8]) {
            cases += 1
            guard let file = try? MidiFileReader.read(bytes: bytes) else { return }
            accepted += 1
            // Whatever is accepted holds MODEL-047's guarantees and the note invariant (MODEL-032).
            #expect(file.lengthTicks.raw >= MidiFileReader.barTicks && file.lengthTicks.raw % MidiFileReader.barTicks == 0)
            #expect(file.lengthTicks <= Tick.timelineEnd)
            var lastByPitch = [Int64](repeating: -1, count: 128)
            for n in file.notes {
                #expect(n.length.raw >= 1 && n.start.raw >= 0 && n.start.raw + n.length.raw <= file.lengthTicks.raw)
                #expect(n.pitch < 128 && (1...127).contains(n.velocity) && n.channel < 16)
                #expect(lastByPitch[Int(n.pitch)] <= n.start.raw, "same-pitch overlap")
                lastByPitch[Int(n.pitch)] = n.start.raw + n.length.raw
            }
            #expect(file.notes.map(\.start) == file.notes.map(\.start).sorted())
        }

        for seed in seeds {
            for cut in 0..<seed.count { check(Array(seed[..<cut])) }  // every truncation
            for _ in 0..<1200 {  // byte flips, inserts and deletes
                var bytes = seed
                for _ in 0..<(1 + rng.below(6)) {
                    switch rng.below(3) {
                    case 0: bytes[rng.below(bytes.count)] = rng.byte()
                    case 1: bytes.insert(rng.byte(), at: rng.below(bytes.count + 1))
                    default: if bytes.count > 1 { bytes.remove(at: rng.below(bytes.count)) }
                    }
                }
                check(bytes)
            }
        }
        // Garbage after a valid header and track header, with huge length fields in it.
        for _ in 0..<1500 {
            var body = (0..<rng.below(64)).map { _ in rng.byte() }
            if rng.below(2) == 0 { body.insert(contentsOf: [0x00, 0xFF, 0x01, 0x8F, 0xFF, 0xFF, 0x7F], at: 0) }
            let length = rng.below(4) == 0 ? UInt32.max : UInt32(body.count)
            check(SMF.header(format: UInt16(rng.below(2)), tracks: UInt16(rng.below(4)), division: UInt16(1 + rng.below(0x7FFF)))
                  + Array("MTrk".utf8) + SMF.be32(length) + body)
        }
        // Pure garbage, sometimes behind the magic.
        for _ in 0..<500 {
            let body = (0..<rng.below(128)).map { _ in rng.byte() }
            check(rng.below(2) == 0 ? Array("MThd".utf8) + body : body)
        }
        // A header announcing 65 535 tracks and a chunk claiming 4 GB allocate nothing from those counts.
        check(SMF.header(format: 1, tracks: 0xFFFF) + SMF.track([]))
        check(SMF.header() + Array("MTrk".utf8) + SMF.be32(0xFFFF_FFFF))

        #expect(cases > 5000)
        #expect(accepted > 0)
        #expect(ContinuousClock.now - started < .seconds(20), "fuzz took too long")
    }

    // MARK: Import composite

    @MainActor
    private func midiProject() -> (Project, NodeIDValue, NodeIDValue) {
        var p = Project(id: GraphFixtures.fixedID, name: "midi import")
        let audio = p.ids.allocate(), keys = p.ids.allocate()
        p.tracks = [Track(id: audio, name: "Mic", kind: .audio), Track(id: keys, name: "Keys", kind: .midi)]
        return (p, audio, keys)
    }

    @Test("MODEL-047: the import is one composite [AddClip, AddNotes], one undo entry, clip lengthTicks long at the drop tick")
    @MainActor
    func importComposite() throws {
        TestCommands.register()
        let (project, _, keys) = midiProject()
        let file = try read(SMF.file(format: 1, [
            SMF.track([(0, SMF.on(0, 60)), (480, SMF.off(0, 60))]),
            SMF.track([(4000, SMF.on(1, 64, 70)), (100, SMF.off(1, 64))]),
        ]))
        let store = ProjectStore(project: project)
        let command = MidiFileImport.commands(file: file, track: keys, at: Tick(1920), in: store.project)
        #expect(command.commands.count == 2 && command.commands[0] is AddClip && command.commands[1] is AddNotes)
        try store.perform(command)

        guard case .midi(let clip)? = store.project.track(keys)?.clips.first else { Issue.record("no MIDI clip"); return }
        #expect(clip.start == Tick(1920) && clip.length == Tick(7680))
        #expect(clip.notes.map { [$0.start.raw, $0.length.raw, Int64($0.pitch), Int64($0.velocity), Int64($0.channel)] }
                == [[0, 480, 60, 100, 0], [4000, 100, 64, 70, 1]])
        #expect(store.undoLabel == MidiFileImport.label)
        store.undo()
        #expect(store.project == project)
        #expect(!store.canUndo)
        store.redo()
        guard case .midi(let again)? = store.project.track(keys)?.clips.first else { Issue.record("redo lost the clip"); return }
        #expect(again == clip)  // redo keeps the clip and note IDs

        // MODEL-006: the composite is wire-encodable and decodes to the same edit.
        let json = try JSONEncoder().encode(AnyCommand(command))
        let decoded = try JSONDecoder().decode(AnyCommand.self, from: json).base
        var a = project, b = project
        _ = try command.apply(to: &a)
        _ = try decoded.apply(to: &b)
        #expect(a == b)
    }

    @Test("MODEL-047: a file without notes imports an empty clip; an audio track refuses the import and changes nothing")
    @MainActor
    func importEdgeCases() throws {
        TestCommands.register()
        let (project, audio, keys) = midiProject()
        let empty = try read(SMF.file([SMF.track([(0, SMF.tempo120)], endOfTrack: 4000)]))
        let store = ProjectStore(project: project)
        try store.perform(MidiFileImport.commands(file: empty, track: keys, at: 0, in: store.project))
        guard case .midi(let clip)? = store.project.track(keys)?.clips.first else { Issue.record("no MIDI clip"); return }
        #expect(clip.notes.isEmpty && clip.length == Tick(7680))

        let file = try read(SMF.file([SMF.track([(0, SMF.on(0, 60)), (480, SMF.off(0, 60))])]))
        let before = store.project
        #expect(throws: DAWError.self) {
            try store.perform(MidiFileImport.commands(file: file, track: audio, at: 0, in: store.project))
        }
        #expect(store.project == before)
    }
}
