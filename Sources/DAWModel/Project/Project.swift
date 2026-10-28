import Foundation

/// The document. A plain value: Commands mutate it (MODEL-001) and `ProjectStore` holds the
/// current one (MODEL-007).
public struct Project: Sendable {
    /// MODEL-040/042: bumped when the JSON shape changes; migrations bring older files forward.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: UUID
    public var name: String
    /// DW-020: the single source of truth for the session rate. `tempoMap` is always built at this
    /// rate and the file stores the rate once, here. Change it with `setSessionSampleRate`, which
    /// rebuilds the map.
    public private(set) var sessionSampleRate: Double
    /// Built at `sessionSampleRate`. Change it with `setTempoMap`.
    public private(set) var tempoMap: TempoMap
    public var ids: IDAllocator
    /// In display order.
    public var tracks: [Track]
    public var buses: [Bus]
    public var master: MasterChannel
    public var assets: [AssetRef]
    public var loop: LoopRange?

    /// An empty project at 48 kHz, 120 bpm 4/4.
    public init(id: UUID = UUID(), name: String = "Untitled") {
        var ids = IDAllocator()
        self.formatVersion = Self.currentFormatVersion
        self.id = id
        self.name = name
        self.sessionSampleRate = 48_000
        self.tempoMap = TempoMap()
        self.master = MasterChannel(id: ids.allocate())
        self.ids = ids
        self.tracks = []
        self.buses = []
        self.assets = []
        self.loop = nil
    }

    /// An empty project at `sessionSampleRate`, 120 bpm 4/4.
    public init(id: UUID = UUID(), name: String = "Untitled", sessionSampleRate: Double) throws(DAWError) {
        self.init(id: id, name: name)
        try setSessionSampleRate(sessionSampleRate)
    }

    /// DW-020: SetSessionSampleRate (MODEL-005) calls this; the tempo map follows the new rate.
    /// Re-converting assets (D-27) is the engine's job and isn't triggered here.
    public mutating func setSessionSampleRate(_ rate: Double) throws(DAWError) {
        do {
            tempoMap = try tempoMap.withSampleRate(rate)
        } catch {
            throw DAWError(error)
        }
        sessionSampleRate = rate
    }

    /// Replaces the tempo and time-signature events; the map is built at the session rate.
    public mutating func setTempoMap(
        tempoEvents: [TempoEvent], timeSignatures: [TimeSignatureEvent]
    ) throws(DAWError) {
        do {
            tempoMap = try TempoMap(
                tempoEvents: tempoEvents, timeSignatures: timeSignatures, sampleRate: sessionSampleRate)
        } catch {
            throw DAWError(error)
        }
    }

    // MARK: Lookup

    public func trackIndex(_ id: NodeIDValue) -> Int? {
        tracks.firstIndex { $0.id == id }
    }

    public func track(_ id: NodeIDValue) -> Track? {
        trackIndex(id).map { tracks[$0] }
    }

    public func busIndex(_ id: NodeIDValue) -> Int? {
        buses.firstIndex { $0.id == id }
    }

    public func bus(_ id: NodeIDValue) -> Bus? {
        busIndex(id).map { buses[$0] }
    }

    /// Runs `body` on the track in place, or throws `notFound` (MODEL-031).
    public mutating func updateTrack<R>(
        _ id: NodeIDValue, _ body: (inout Track) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        guard let index = trackIndex(id) else { throw .notFound(kind: "track", id: id) }
        return try body(&tracks[index])
    }

    /// Runs `body` on the bus in place, or throws `notFound` (MODEL-031).
    public mutating func updateBus<R>(
        _ id: NodeIDValue, _ body: (inout Bus) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        guard let index = busIndex(id) else { throw .notFound(kind: "bus", id: id) }
        return try body(&buses[index])
    }
}

// MARK: Equatable

extension Project: Equatable {
    /// Document equality. `ids` is left out on purpose: undo doesn't roll the allocator back
    /// (IDs are never reused), so a project after "add track, undo" equals the original even
    /// though its allocator has moved on (MODEL-002). Keep this in step with the stored properties.
    public static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.formatVersion == rhs.formatVersion && lhs.id == rhs.id && lhs.name == rhs.name
            && lhs.sessionSampleRate == rhs.sessionSampleRate && lhs.tempoMap == rhs.tempoMap
            && lhs.tracks == rhs.tracks && lhs.buses == rhs.buses && lhs.master == rhs.master
            && lhs.assets == rhs.assets && lhs.loop == rhs.loop
    }
}

// MARK: Codable

extension Project: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, sessionSampleRate, tempoMap, ids, tracks, buses, master, assets, loop
    }

    /// DW-020: the tempo map's events without a rate; the rate is `sessionSampleRate`.
    private struct TempoEvents: Codable {
        var tempoEvents: [TempoEvent]
        var timeSignatures: [TimeSignatureEvent]
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sessionSampleRate = try c.decode(Double.self, forKey: .sessionSampleRate)
        let events = try c.decode(TempoEvents.self, forKey: .tempoMap)
        do {
            tempoMap = try TempoMap(
                tempoEvents: events.tempoEvents, timeSignatures: events.timeSignatures,
                sampleRate: sessionSampleRate)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: c.codingPath + [CodingKeys.tempoMap],
                      debugDescription: "invalid tempo map: \(error)", underlyingError: DAWError(error)))
        }
        ids = try c.decode(IDAllocator.self, forKey: .ids)
        tracks = try c.decode([Track].self, forKey: .tracks)
        buses = try c.decode([Bus].self, forKey: .buses)
        master = try c.decode(MasterChannel.self, forKey: .master)
        assets = try c.decode([AssetRef].self, forKey: .assets)
        loop = try c.decodeIfPresent(LoopRange.self, forKey: .loop)

        // DW-031: a hand-edited or older file may hold IDs at or past its allocator's `next`.
        // Move the allocator past all of them so a new entity never takes an ID in use. An ID in
        // the NodeID role bits would overflow the allocator and can't become a NodeID, so it is
        // rejected here; the remaining invariants are `validate()`'s (MODEL-032).
        var largest: ModelID = 0
        forEachID { id, _ in largest = max(largest, id) }
        guard largest <= GraphNodeID.maxModelID else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: c.codingPath,
                      debugDescription: "id \(largest) is above the largest model id \(GraphNodeID.maxModelID)"))
        }
        ids.reserve(largest)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(sessionSampleRate, forKey: .sessionSampleRate)
        try c.encode(
            TempoEvents(tempoEvents: tempoMap.tempoEvents, timeSignatures: tempoMap.timeSignatures),
            forKey: .tempoMap)
        try c.encode(ids, forKey: .ids)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(buses, forKey: .buses)
        try c.encode(master, forKey: .master)
        try c.encode(assets, forKey: .assets)
        try c.encodeIfPresent(loop, forKey: .loop)
    }
}
