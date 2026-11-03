/// What a mutation of the store changed (MODEL-007). The UI uses it to redraw, and engine sync
/// (MODEL-021) to choose between a param update and a graph rebuild.
public struct ProjectChange: Hashable, Sendable {
    public enum Cause: Hashable, Sendable {
        /// A command was performed and pushed onto the undo stack, or, for a
        /// `HistoryExemptCommand` (`SetMetronome`), performed outside the history.
        case perform
        case undo
        case redo
        /// A command applied inside a gesture, not pushed (MODEL-003). Engine sync can route
        /// param-only updates straight to param slots here (MODEL-021).
        case gestureUpdate
        /// The gesture ended. `changedIDs` and `changedFields` cover every update in the gesture,
        /// even if the end state equals the start, because the engine may have seen intermediate
        /// values.
        case gestureEnd
    }

    /// Document properties that have no ID of their own.
    public enum Field: String, Hashable, Sendable, Codable {
        case name, sessionSampleRate, tempoMap, loop, assets, trackOrder, busOrder
        /// T-026: `Project.metronome` (a history-exempt `SetMetronome`).
        case metronome
    }

    public var cause: Cause
    /// The undo label of the command or gesture.
    public var label: String
    /// Entities that were added, removed or modified. An entity counts as modified when anything
    /// inside it changed, so a moved clip reports the clip and its track.
    public var changedIDs: Set<ModelID>
    public var changedFields: Set<Field>

    public init(cause: Cause, label: String, changedIDs: Set<ModelID> = [], changedFields: Set<Field> = []) {
        self.cause = cause
        self.label = label
        self.changedIDs = changedIDs
        self.changedFields = changedFields
    }

    /// The difference between two versions of a project.
    public init(cause: Cause, label: String, from old: Project, to new: Project) {
        let before = old.entities()
        let after = new.entities()
        var ids = Set<ModelID>()
        for (id, value) in after where before[id] != value { ids.insert(id) }
        for id in before.keys where after[id] == nil { ids.insert(id) }

        var fields = Set<Field>()
        if old.name != new.name { fields.insert(.name) }
        if old.sessionSampleRate != new.sessionSampleRate { fields.insert(.sessionSampleRate) }
        if old.tempoMap != new.tempoMap { fields.insert(.tempoMap) }
        if old.loop != new.loop { fields.insert(.loop) }
        if old.metronome != new.metronome { fields.insert(.metronome) }
        if old.assets != new.assets { fields.insert(.assets) }
        if old.tracks.map(\.id) != new.tracks.map(\.id) { fields.insert(.trackOrder) }
        if old.buses.map(\.id) != new.buses.map(\.id) { fields.insert(.busOrder) }
        self.init(cause: cause, label: label, changedIDs: ids, changedFields: fields)
    }

    public var isEmpty: Bool { changedIDs.isEmpty && changedFields.isEmpty }

    mutating func formUnion(_ other: ProjectChange) {
        changedIDs.formUnion(other.changedIDs)
        changedFields.formUnion(other.changedFields)
    }
}

extension Project {
    /// Every entity with an ID, down to clips, device slots, sends, take folders and lanes (notes
    /// are reported through their clip). Values compare whole entities, so unchanged arrays that
    /// still share storage compare cheaply.
    fileprivate func entities() -> [ModelID: AnyHashable] {
        var out: [ModelID: AnyHashable] = [:]
        func add(_ slots: [DeviceSlot]) { for slot in slots { out[slot.id] = slot } }
        func add(_ sends: [Send]) { for send in sends { out[send.id] = send } }
        func add(_ lanes: [AutomationLane]) { for lane in lanes { out[lane.id] = lane } }

        out[master.id] = master
        add(master.inserts)
        add(master.automation)
        for track in tracks {
            out[track.id] = track
            for clip in track.clips { out[clip.id] = clip }
            for folder in track.takeFolders { out[folder.id] = folder }
            if let instrument = track.instrument { out[instrument.id] = instrument }
            add(track.inserts)
            add(track.sends)
            add(track.automation)
        }
        for bus in buses {
            out[bus.id] = bus
            add(bus.inserts)
            add(bus.sends)
            add(bus.automation)
        }
        for asset in assets { out[asset.id] = asset }
        return out
    }
}
