public struct MidiClip: Identifiable, Hashable, Sendable, Codable {
    public var id: ModelID
    public var start: Tick
    public var length: Tick
    /// Sorted by `start` (MODEL-032).
    public var notes: [Note]

    public init(id: ModelID, start: Tick, length: Tick, notes: [Note] = []) {
        self.id = id
        self.start = start
        self.length = length
        self.notes = notes
    }
}

/// A MIDI note. Field names follow `NoteDesc` (05 Interfaces), except that `start` is relative to
/// the clip so notes move with it; GraphDescriptionBuilder adds the clip start.
public struct Note: Identifiable, Hashable, Sendable, Codable {
    public var id: ModelID
    public var start: Tick
    public var length: Tick
    public var pitch: UInt8
    public var velocity: UInt8
    public var channel: UInt8

    public init(id: ModelID, start: Tick, length: Tick, pitch: UInt8, velocity: UInt8 = 100, channel: UInt8 = 0) {
        self.id = id
        self.start = start
        self.length = length
        self.pitch = pitch
        self.velocity = velocity
        self.channel = channel
    }
}
