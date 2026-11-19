import Foundation

/// MODEL-047: why a Standard MIDI File couldn't be read. Every malformed or truncated input ends
/// in one of these; the reader never traps or loops on bad bytes.
public enum MidiFileError: Error, Hashable, Sendable {
    /// The data doesn't start with an `MThd` chunk.
    case notAMidiFile
    /// A chunk, an event or a length field runs past the end of the data. `offset` is the byte
    /// where the missing data should have been.
    case truncated(offset: Int)
    /// The bytes break the SMF format, e.g. a data byte without a running status or a status byte
    /// that can't appear in a file. `offset` is the byte at fault.
    case malformed(offset: Int, detail: String)
    /// Format 2 (independent sequences) or an unknown format; only 0 and 1 are read.
    case unsupportedFormat(UInt16)
    /// The header gives an SMPTE time division (frames and ticks per frame) instead of PPQ.
    case smpteTimeDivision
    /// An event lies past `Tick.timelineEnd` once converted to 960 PPQ.
    case beyondTimeline
    /// The file is larger than `MidiFileReader.maxFileSize`.
    case tooLarge(bytes: Int)
    /// `read(contentsOf:)` couldn't read the file.
    case fileIO(path: String, detail: String)

    /// The model-wide error for this (CONV §4), for callers that throw `DAWError`.
    public var dawError: DAWError {
        switch self {
        case .fileIO(let path, let detail): .fileIO(path: path, detail: detail)
        default: .invalidArgument("MIDI file: \(self)")
        }
    }
}

extension MidiFileError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notAMidiFile: "not a Standard MIDI File (no MThd header)"
        case .truncated(let offset): "truncated at byte \(offset)"
        case .malformed(let offset, let detail): "malformed at byte \(offset): \(detail)"
        case .unsupportedFormat(let format): "SMF format \(format) isn't supported (only 0 and 1)"
        case .smpteTimeDivision: "SMPTE time division isn't supported (only PPQ)"
        case .beyondTimeline: "events lie past the end of the timeline"
        case .tooLarge(let bytes): "file of \(bytes) bytes is larger than \(MidiFileReader.maxFileSize)"
        case .fileIO(let path, let detail): "can't read \(path): \(detail)"
        }
    }
}

/// MODEL-047: what `MidiFileReader` reads from a file: its notes in 960-PPQ ticks, from tick 0 of
/// the file, and a clip length that holds them.
public struct MidiFile: Hashable, Sendable {
    public struct Note: Hashable, Sendable {
        public var start: Tick
        /// At least one tick.
        public var length: Tick
        public var pitch: UInt8
        /// 1…127.
        public var velocity: UInt8
        /// 0…15, the channel of the file's note-on.
        public var channel: UInt8

        public init(start: Tick, length: Tick, pitch: UInt8, velocity: UInt8, channel: UInt8) {
            self.start = start
            self.length = length
            self.pitch = pitch
            self.velocity = velocity
            self.channel = channel
        }
    }

    /// Sorted by (start, pitch, channel). No two notes of one pitch overlap.
    public var notes: [Note]
    /// The last event (or note end) rounded up to a whole 4/4 bar, at least one bar.
    public var lengthTicks: Tick

    public init(notes: [Note], lengthTicks: Tick) {
        self.notes = notes
        self.lengthTicks = lengthTicks
    }
}

/// MODEL-047 (T-128): reads Standard MIDI Files, formats 0 and 1, at any PPQ. Note-on/off pairs
/// from every track and channel are merged into one note list at 960 PPQ. Tempo, time signature,
/// CCs, pitch bend and SysEx are skipped: notes keep their beat positions and the project tempo
/// applies.
///
/// Robustness: every length field is checked against the bytes that are left before anything is
/// read or skipped, nothing is allocated from a count in the file (the header's track count, a
/// chunk or event length), and every loop advances through the data, so any input ends in a
/// result or a `MidiFileError` in time linear in its size.
public enum MidiFileReader {
    /// Larger files are refused before they're read (real MIDI files are a few hundred KB).
    public static let maxFileSize = 64 << 20
    /// One 4/4 bar at 960 PPQ.
    public static let barTicks: Int64 = 4 * Tick.ppq

    public static func read(contentsOf url: URL) throws(MidiFileError) -> MidiFile {
        let data: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxFileSize else { throw MidiFileError.tooLarge(bytes: size) }
            data = try Data(contentsOf: url)
        } catch let error as MidiFileError {
            throw error
        } catch {
            throw .fileIO(path: url.path, detail: error.localizedDescription)
        }
        return try read(data)
    }

    public static func read(_ data: Data) throws(MidiFileError) -> MidiFile {
        guard data.count <= maxFileSize else { throw .tooLarge(bytes: data.count) }
        return try read(bytes: [UInt8](data))
    }

    public static func read(bytes: [UInt8]) throws(MidiFileError) -> MidiFile {
        guard bytes.count <= maxFileSize else { throw .tooLarge(bytes: bytes.count) }
        var cursor = Cursor(bytes: bytes, end: bytes.count)

        // Header chunk: "MThd", length >= 6, format, track count, division.
        guard bytes.count >= 4, bytes[0..<4].elementsEqual(Self.mthd) else { throw .notAMidiFile }
        cursor.pos = 4
        let headerLength = try cursor.u32()
        guard headerLength >= 6 else { throw .malformed(offset: 4, detail: "header length \(headerLength) is below 6") }
        let headerEnd = try cursor.limit(headerLength)
        let format = try cursor.u16()
        let trackCount = Int(try cursor.u16())
        let division = try cursor.u16()
        cursor.pos = headerEnd  // a longer header's extra bytes are skipped (SMF: future fields)
        guard format <= 1 else { throw .unsupportedFormat(format) }
        guard division & 0x8000 == 0 else { throw .smpteTimeDivision }
        guard division > 0 else { throw .malformed(offset: 12, detail: "zero ticks per quarter note") }
        let ppq = Int64(division)

        var state = State(ppq: ppq)
        var tracksRead = 0
        while tracksRead < trackCount {
            // Chunks: "MTrk" holds a track; any other type is skipped (SMF: ignore unknown chunks).
            let chunkStart = cursor.pos
            guard cursor.end - cursor.pos >= 8 else { throw .truncated(offset: cursor.end) }
            let isTrack = bytes[chunkStart..<chunkStart + 4].elementsEqual(Self.mtrk)
            cursor.pos += 4
            let length = try cursor.u32()
            let chunkEnd = try cursor.limit(length)
            if isTrack {
                var track = Cursor(bytes: bytes, pos: cursor.pos, end: chunkEnd)
                try state.readTrack(&track)
                tracksRead += 1
            }
            cursor.pos = chunkEnd
        }
        return try state.result()
    }

    private static let mthd: [UInt8] = Array("MThd".utf8)
    private static let mtrk: [UInt8] = Array("MTrk".utf8)

    /// A read position in `bytes[..<end]`. Every read checks the bytes left first.
    struct Cursor {
        let bytes: [UInt8]
        var pos = 0
        let end: Int

        mutating func u8() throws(MidiFileError) -> UInt8 {
            guard pos < end else { throw .truncated(offset: pos) }
            defer { pos += 1 }
            return bytes[pos]
        }

        mutating func u16() throws(MidiFileError) -> UInt16 {
            UInt16(try u8()) << 8 | UInt16(try u8())
        }

        mutating func u32() throws(MidiFileError) -> UInt32 {
            UInt32(try u16()) << 16 | UInt32(try u16())
        }

        /// A variable-length quantity: at most 4 bytes, so at most 2^28 − 1 (SMF).
        mutating func vlq() throws(MidiFileError) -> Int64 {
            let start = pos
            var value: Int64 = 0
            for _ in 0..<4 {
                let byte = try u8()
                value = value << 7 | Int64(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            throw .malformed(offset: start, detail: "variable-length quantity longer than 4 bytes")
        }

        /// The end of the next `length` bytes, which must be there.
        func limit<Length: BinaryInteger>(_ length: Length) throws(MidiFileError) -> Int {
            guard length >= 0, UInt64(length) <= UInt64(end - pos) else { throw .truncated(offset: end) }
            return pos + Int(length)
        }

        mutating func skip(_ length: Int64) throws(MidiFileError) {
            pos = try limit(length)
        }

        /// A data byte (high bit clear).
        mutating func data() throws(MidiFileError) -> UInt8 {
            let byte = try u8()
            guard byte & 0x80 == 0 else { throw .malformed(offset: pos - 1, detail: "status byte where a data byte belongs") }
            return byte
        }
    }

    /// A note in the file's ticks. `end == nil` until its note-off.
    private struct RawNote {
        var start: Int64
        var end: Int64?
        var pitch: UInt8
        var velocity: UInt8
        var channel: UInt8
    }

    private struct State {
        let ppq: Int64
        /// The largest file tick that still converts to at most `Tick.timelineEnd`.
        let tickLimit: Int64
        var notes: [RawNote] = []
        var lastEvent: Int64 = 0

        init(ppq: Int64) {
            self.ppq = ppq
            // to960(t) <= timelineEnd for every t <= this. ppq < 2^15, so this is < 2^51 and
            // 2 * t * 960 stays far inside Int64.
            tickLimit = Tick.timelineEnd.raw * ppq / Tick.ppq
        }

        /// One `MTrk` chunk. Note-offs pair with the open note of their channel and pitch in this
        /// track; a note-on while one is open ends the earlier one there.
        mutating func readTrack(_ cursor: inout Cursor) throws(MidiFileError) {
            var tick: Int64 = 0
            var running: UInt8?
            // The index in `notes` of the open note per channel × pitch.
            var open = [Int?](repeating: nil, count: 16 * 128)
            while cursor.pos < cursor.end {
                tick += try cursor.vlq()  // < 2^28 per event, checked below, so no overflow
                guard tick <= tickLimit else { throw .beyondTimeline }
                lastEvent = max(lastEvent, tick)
                let statusOffset = cursor.pos
                let first = try cursor.u8()
                let status: UInt8
                let data1: UInt8?
                if first & 0x80 == 0 {
                    // Running status: the previous channel status applies, this is its first data byte.
                    guard let running else {
                        throw .malformed(offset: statusOffset, detail: "data byte without a running status")
                    }
                    status = running
                    data1 = first
                } else {
                    status = first
                    data1 = nil
                }
                switch status {
                case 0x80...0xEF:
                    running = status
                    let kind = status & 0xF0, channel = status & 0x0F
                    let a: UInt8
                    if let data1 { a = data1 } else { a = try cursor.data() }
                    if kind == 0xC0 || kind == 0xD0 { continue }  // program change, channel pressure
                    let b = try cursor.data()
                    guard kind == 0x80 || kind == 0x90 else { continue }  // CC, pitch bend, poly pressure
                    let key = Int(channel) * 128 + Int(a)
                    if let index = open[key] {
                        // Its note-off, or a retrigger: overlapping same-pitch notes end the earlier one.
                        notes[index].end = tick
                        open[key] = nil
                    }
                    if kind == 0x90, b > 0 {  // velocity 0 is a note-off
                        open[key] = notes.count
                        notes.append(RawNote(start: tick, end: nil, pitch: a, velocity: b, channel: channel))
                    }
                case 0xF0, 0xF7:  // SysEx: length, bytes. Cancels running status (SMF).
                    let length = try cursor.vlq()
                    try cursor.skip(length)
                    running = nil
                case 0xFF:  // Meta event: type, length, bytes. Cancels running status (SMF).
                    let type = try cursor.u8()
                    let length = try cursor.vlq()
                    try cursor.skip(length)
                    running = nil
                    if type == 0x2F { return }  // end of track; bytes after it are ignored
                default:
                    throw .malformed(offset: statusOffset, detail: String(format: "status byte 0x%02X can't appear in a file", status))
                }
            }
        }

        /// File ticks → 960 PPQ, to the nearest tick (halves up).
        func to960(_ tick: Int64) -> Int64 {
            (2 * tick * Tick.ppq + ppq) / (2 * ppq)
        }

        func result() throws(MidiFileError) -> MidiFile {
            let last = to960(lastEvent)
            // An unmatched note-on ends at the file's last event; every note is at least a tick.
            var converted = notes.map { raw in
                let start = to960(raw.start)
                let end = raw.end.map(to960) ?? last
                return MidiFile.Note(start: Tick(start), length: Tick(max(end - start, 1)), pitch: raw.pitch,
                                     velocity: raw.velocity, channel: raw.channel)
            }
            // Merged across tracks and channels (and after rounding), overlapping same-pitch notes
            // end the earlier one; two that start on one tick are one note, the longer one (the
            // first in the file on a tie). The sort is stable, so ties keep file order.
            converted = converted.enumerated().sorted { l, r in
                (l.element.pitch, l.element.start.raw, -l.element.length.raw, l.offset)
                    < (r.element.pitch, r.element.start.raw, -r.element.length.raw, r.offset)
            }.map(\.element)
            var merged: [MidiFile.Note] = []
            merged.reserveCapacity(converted.count)
            for note in converted {
                if let previous = merged.last, previous.pitch == note.pitch {
                    if previous.start == note.start { continue }  // the longer one is already in
                    if previous.start.raw + previous.length.raw > note.start.raw {
                        merged[merged.count - 1].length = Tick(note.start.raw - previous.start.raw)
                    }
                }
                merged.append(note)
            }
            merged.sort { ($0.start.raw, $0.pitch, $0.channel) < ($1.start.raw, $1.pitch, $1.channel) }

            let end = merged.reduce(last) { max($0, $1.start.raw + $1.length.raw) }
            let bars = max((end + MidiFileReader.barTicks - 1) / MidiFileReader.barTicks, 1)
            let length = bars * MidiFileReader.barTicks
            guard length <= Tick.timelineEnd.raw else { throw .beyondTimeline }
            return MidiFile(notes: merged, lengthTicks: Tick(length))
        }
    }
}
