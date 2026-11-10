import DAWModel
import Foundation

/// A continuous control on a strip (`MixerSliderView`). Drags on it coalesce into one undo step.
enum MixerParam: Hashable, Sendable {
    case gain(NodeIDValue)
    case pan(NodeIDValue)
    case sendLevel(ModelID)

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

/// UI-030: an insert in the list (read-only until the insert-chain commands of DW-149 exist).
struct MixerInsert: Equatable, Sendable, Identifiable {
    var id: NodeIDValue
    var name: String
    var bypass: Bool
}
