import Foundation

/// MODEL-005 `InsertDevice` (T-088, DW-149): puts a new device slot (new ID) into the insert chain
/// of a track, a bus or the master (`channel` is the master's ID for the master, DECISIONS "T-088
/// master"), at `index` (0…insert count; nil appends). The device is a built-in effect
/// (`DeviceSlot.builtinInsertKinds`) with optional params, or an AU/VST3 plugin with optional
/// params and state. The sampler is an instrument (`SetInstrument`). A sidechain source must be a
/// track or bus whose route into the channel can't close a cycle (MODEL-030).
///
/// GraphDescriptionBuilder emits the chain in order between the channel's source (or input) and
/// its strip; a master insert sits before the master strip. The inverse is `RemoveDevice`.
///
/// JSON: `{"type": "InsertDevice", "channel": 2, "index": 0, "device": {"format": "builtin", "node": "eq"},
/// "params": [{"index": 0, "value": 0.5}]}`.
public struct InsertDevice: Command {
    public static let type = "InsertDevice"

    public var channel: NodeIDValue
    /// 0…insert count; nil appends.
    public var index: Int?
    public var device: DeviceSlot.Kind
    public var params: [ParamValue]?
    /// AU/VST3 only (MODEL-043's opaque state).
    public var pluginState: Data?
    public var sidechainSource: SidechainRef?

    public init(
        channel: NodeIDValue, index: Int? = nil, device: DeviceSlot.Kind, params: [ParamValue]? = nil,
        pluginState: Data? = nil, sidechainSource: SidechainRef? = nil
    ) {
        self.channel = channel
        self.index = index
        self.device = device
        self.params = params
        self.pluginState = pluginState
        self.sidechainSource = sidechainSource
    }

    public var label: String { "Insert Device" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard project.inserts(of: channel) != nil else { throw .notFound(kind: "channel", id: channel) }
        if pluginState != nil, case .builtin = device {
            throw .invalidArgument("pluginState is for AU and VST3 devices, not built-ins")
        }
        // On a copy: a rejected insert allocates no ID.
        var working = project
        let slot = DeviceSlot(id: working.ids.allocate(), kind: device, params: params ?? [], pluginState: pluginState,
                              sidechainSource: sidechainSource)
        try slot.checkInsertKind()
        try working.placeInsert(slot, on: channel, at: index)
        project = working
        return RemoveDevice(slotID: slot.id)
    }
}
