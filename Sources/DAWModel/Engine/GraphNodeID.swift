/// How GraphDescriptionBuilder (MODEL-020) names graph nodes. Some model entities become one
/// node (device slots, sends, channel strips); a channel also needs nodes the model has no entity
/// for (a track's clip player, a bus's summing input, the master node). Their NodeIDs are derived
/// from the owning entity's ID, so they are stable across rebuilds without extra persisted IDs
/// (delay-line carry-over, MIX-022, and node instance reuse, DW-036, are keyed by them).
///
/// The role sits in the top 8 bits. Model IDs are allocated upward from 1 and never get near 2^56,
/// so a role-0 NodeID is the entity's own ID:
///   - a channel strip is its track's, bus's or master's ID, so `meter(track.id)` reads the
///     track's post-fader meter;
///   - a device slot is the slot's ID (`instantiatePlugin(slot:)`, `pluginState(slot:)`);
///   - a send's gain node is the send's ID.
public enum GraphNodeID {
    public enum Role: UInt8, Hashable, Sendable, CaseIterable {
        /// The entity itself: strip, device slot or send.
        case entity = 0
        /// A track's clip player (audio or MIDI).
        case source = 1
        /// The summing input of a bus or of the master (`NodeKind.bus`).
        case input = 2
        /// The master's final node (`NodeKind.master`).
        case output = 3
        /// The project metronome (`NodeKind.metronome`, T-026), owned by the master.
        case metronome = 4
        /// A device slot's host-side bypass param slot (T-064, PLUG-018). Never a graph node: it
        /// keys the slot's bypass param range in `RuntimeIDs.params`.
        case bypass = 5
    }

    static let roleShift: UInt64 = 56
    /// Model IDs must stay below this (MODEL-032 can check it).
    public static let maxModelID: ModelID = (1 << roleShift) - 1

    public static func make(_ role: Role, _ owner: ModelID) -> NodeIDValue {
        assert(owner <= maxModelID, "model ID \(owner) collides with the NodeID role bits")
        return UInt64(role.rawValue) << roleShift | owner
    }

    /// The model entity a NodeID belongs to, e.g. to report an engine-side cycle (DW-050) in
    /// model terms.
    public static func owner(of node: NodeIDValue) -> ModelID { node & maxModelID }

    public static func role(of node: NodeIDValue) -> Role? { Role(rawValue: UInt8(node >> roleShift)) }

    /// A track's clip player.
    public static func source(of track: NodeIDValue) -> NodeIDValue { make(.source, track) }
    /// A bus's or the master's summing input.
    public static func input(of channel: NodeIDValue) -> NodeIDValue { make(.input, channel) }
    /// The master node (`EngineGraph.master`).
    public static func output(of master: NodeIDValue) -> NodeIDValue { make(.output, master) }
    /// The project metronome's node (TIME-010, T-026), feeding `output(of: master)`.
    public static func metronome(of master: NodeIDValue) -> NodeIDValue { make(.metronome, master) }
    /// PLUG-018 (T-064): the key of a device slot's bypass param slot in `RuntimeIDs.params`.
    public static func bypass(of slot: NodeIDValue) -> NodeIDValue { make(.bypass, slot) }
}
