/// Every ID in the document (tracks, buses, master, device slots, clips, notes, sends, assets…)
/// comes from one `IDAllocator`, so an ID names exactly one entity for the project's lifetime.
public typealias ModelID = UInt64

/// The IDs that become graph `NodeID`s (tracks, buses, master, device slots; 05-mixer-routing-pdc).
public typealias NodeIDValue = ModelID

/// Hands out `ModelID`s. Stored in the project and persisted, and never rolled back: undoing an
/// add doesn't free its ID, so an ID is never reused (07, "IDs are UInt64 … never reused"). Engine
/// state keyed by ID (delay lines, param slots, plugin state files) can't be confused by a reuse.
///
/// 0 is never allocated, so it can mean "none" where a plain ID is needed.
public struct IDAllocator: Hashable, Sendable, Codable {
    /// The next ID `allocate()` returns.
    public private(set) var next: ModelID

    public init(next: ModelID = 1) {
        self.next = max(next, 1)
    }

    public mutating func allocate() -> ModelID {
        defer { next += 1 }
        return next
    }

    /// Records that `id` is in use, so it is never handed out. Commands that re-insert an entity
    /// with its old ID (the inverse of a remove, redo, or a command decoded from JSON) call this.
    public mutating func reserve(_ id: ModelID) {
        if id >= next { next = id + 1 }
    }
}
