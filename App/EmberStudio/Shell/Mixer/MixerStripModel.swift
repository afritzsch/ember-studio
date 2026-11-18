import DAWModel
import Foundation

/// A continuous control on a strip (`MixerSliderView`). Drags on it coalesce into one undo step.
enum MixerParam: Hashable, Sendable {
    case gain(NodeIDValue)
    case pan(NodeIDValue)
    case sendLevel(ModelID)

    /// The automation target the control drives (AUTO-006, T-075).
    var target: ParamTarget {
        switch self {
        case .gain(let channel): .strip(channel: channel, param: .gain)
        case .pan(let channel): .strip(channel: channel, param: .pan)
        case .sendLevel(let send): .sendLevel(send: send)
        }
    }

    /// The gesture's undo label.
    var label: String {
        switch self {
        case .gain: "Set Gain"
        case .pan: "Set Pan"
        case .sendLevel: "Set Send Level"
        }
    }
}

/// UI-030: one channel strip (track, bus or the master), derived from the project by `MixerModel`.
///
/// `values` are what the strip shows; a strip whose `values` are equal needs no redraw (`==` compares
/// only those: every control's action is a function of them), so a change to one channel doesn't
/// re-render the others. `MixerStripView` uses this as its `Equatable`.
@dynamicMemberLookup
@MainActor
struct MixerStripModel: Identifiable, Equatable {
    enum Kind: String, Sendable { case audio, midi, bus, master }

    struct Values: Equatable, Sendable {
        var id: NodeIDValue
        var kind: Kind
        var name: String
        /// `mixer.track.<id>`, `mixer.bus.<id>`, `mixer.master`.
        var controlPrefix: String
        var gain: Float
        var pan: Float
        var mute: Bool
        var solo: Bool
        /// Tracks only.
        var isSelected: Bool
        var armed: Bool
        var inputPair: UInt32
        var monitoring: Track.Monitoring
        var inputChoices: [UInt32]
        /// nil on the master.
        var output: OutputTarget?
        var outputTitle: String?
        var outputChoices: [MixerRouteChoice]
        var sends: [MixerSendValues]
        var sendTargets: [MixerRouteChoice]
        var inserts: [MixerInsert]
        /// PLUG-017 (T-063): a MIDI track's instrument (nil: none or not a track).
        var instrument: MixerInsert? = nil
        /// DW-250 (T-065): what the strip's "+" device picker offers.
        var insertChoices: [DeviceChoice] = []
        /// T-093, DW-298: a MIDI track's input picker as shown (title, tooltip, menu entries), so a
        /// change redraws the strip (the picker's controls are the header's, outside `values`).
        var midiInputFace: [String] = []
        /// DW-227: the monitor menu's latency line (audio tracks), for the same reason.
        var monitoringLatency: String? = nil
    }

    let values: Values
    /// Tracks only: the header's arm, monitor and input controls and its mute, solo and select, the
    /// same descriptors the arrange view uses (DW-202), so a strip and a header can't disagree.
    let header: TrackHeaderModel?
    /// A track's are the header's; a bus's and the master's are the strip's own. The master has no solo.
    let muteControl: UIControl
    let soloControl: UIControl?
    let faderUp: UIControl
    let faderDown: UIControl
    let faderReset: UIControl
    let panLeft: UIControl
    let panRight: UIControl
    let panCenter: UIControl
    /// `<prefix>.clip.reset`: the same as clicking the meter.
    let clipReset: UIControl
    /// `<prefix>.output.master|bus.<id>`.
    let outputControls: [UIControl]
    let sends: [MixerSendModel]
    /// `<prefix>.send.add.<bus>`.
    let sendAddControls: [UIControl]
    /// PLUG-017 (T-063): `<prefix>.insert.<slot>.editor` per AU/VST3 insert and
    /// `<prefix>.instrument.editor` for a plugin instrument (toggles, on while the editor is open).
    var editorControls: [UIControl] = []
    /// DW-250 (T-065): per insert `<prefix>.insert.<slot>.bypass` (toggle), `.remove`, `.up`, `.down`,
    /// `.show` (opens it in the Device Chain tab).
    var insertControls: [UIControl] = []
    /// DW-250: `<prefix>.insert.add.<key>`, the device picker (`DeviceChoice` keys).
    var insertAddControls: [UIControl] = []

    nonisolated var id: NodeIDValue { values.id }
    var faderPosition: Double { FaderTaper.position(gain: values.gain) }
    var panPosition: Double { PanTaper.position(pan: values.pan) }

    subscript<T>(dynamicMember path: KeyPath<Values, T>) -> T { values[keyPath: path] }

    nonisolated static func == (a: MixerStripModel, b: MixerStripModel) -> Bool { a.values == b.values }

    /// The controls this strip adds to the window. A track's header controls (`track.<id>.…`) are
    /// already there, from its header.
    var ownControls: [UIControl] {
        var controls = [faderUp, faderDown, faderReset, panLeft, panRight, panCenter, clipReset] + outputControls + sendAddControls
        controls += sends.flatMap(\.controls)
        controls += editorControls  // T-063
        controls += insertControls + insertAddControls  // T-065 (DW-250)
        if header == nil {
            controls.append(muteControl)
            if let soloControl { controls.append(soloControl) }
        }
        return controls
    }

    /// Every control the strip shows, for `ui.state`.
    var allControlIDs: [String] {
        let shared = header.map { $0.controls.map(\.id) } ?? []
        return (shared + ownControls.map(\.id)).sorted()
    }
}

/// A send on a strip: what it shows.
struct MixerSendValues: Equatable, Sendable, Identifiable {
    var id: ModelID
    var target: NodeIDValue
    var targetName: String
    var level: Float
    var tap: SignalTap
}

/// A send on a strip: `<prefix>.send.<id>.…`.
@MainActor
struct MixerSendModel: Identifiable {
    let values: MixerSendValues
    let levelUp: UIControl
    let levelDown: UIControl
    let levelReset: UIControl
    /// On: pre-fader; off: post-fader.
    let tapPre: UIControl
    let remove: UIControl

    nonisolated var id: ModelID { values.id }
    var levelPosition: Double { FaderTaper.position(gain: values.level) }
    var controls: [UIControl] { [levelUp, levelDown, levelReset, tapPre, remove] }
}

/// A bus (or the master) a strip's output or send can go to.
struct MixerRouteChoice: Equatable, Sendable, Identifiable {
    /// The channel's ID; the master's in an output menu.
    var id: NodeIDValue
    var name: String
    var isCurrent: Bool
}

/// UI-030, DW-250 (T-065): an insert in the strip's list, editable through `insertControls`.
struct MixerInsert: Equatable, Sendable, Identifiable {
    var id: NodeIDValue
    var name: String
    var bypass: Bool
    /// PLUG-017 (T-063): an AU or VST3 (it has an editor to open), and whether that editor is open.
    var isPlugin: Bool = false
    var editorOpen: Bool = false
    /// DW-226 (T-065): an AU/VST3 slot in safe mode (PLUG-021): bypassed whatever `bypass` says.
    var safeModeBypassed: Bool = false
    /// `builtin`, `au`, `vst3`.
    var format: String = "builtin"

    var isBypassed: Bool { bypass || safeModeBypassed }
}
