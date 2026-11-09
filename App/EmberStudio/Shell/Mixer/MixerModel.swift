import DAWModel
import Foundation
import Observation

/// UI-030, UI-033: the view model of the Mixer tab. Strips are derived from the project on demand, so
/// they follow edits from anywhere (arrange view, undo/redo, the control socket) with no state of
/// their own to sync. It mutates only through commands (MODEL-003): continuous controls go through
/// one gesture per drag, and routing choices are left to the model to refuse (MODEL-030).
@Observable
@MainActor
final class MixerModel {
    @ObservationIgnored weak var window: ProjectWindowModel?

    /// UI-031: not observable on purpose; it changes every display frame.
    @ObservationIgnored let meters = MeterBank()

    /// The drag in progress (`ui.state`).
    private(set) var activeDrag: MixerParam?
    /// The store the drag's gesture was opened on, ended on that same store.
    @ObservationIgnored private var dragStore: ProjectStore?

    init() {
        meters.readMeter = { [weak self] channel in self?.window?.engine?.meter(channel) }
    }

    var isOpen: Bool { window?.bottomPane == .mixer }

    // MARK: Strips

    /// Tracks in order, then buses, then the master.
    var strips: [MixerStripModel] {
        guard let window else { return [] }
        let project = window.project
        let busNames = project.buses.map { ($0.id, $0.name) }
        var strips: [MixerStripModel] = []
        strips.reserveCapacity(project.tracks.count + project.buses.count + 1)
        for header in window.trackHeaders {
            guard let track = project.track(header.id) else { continue }
            strips.append(strip(track: track, header: header, buses: busNames))
        }
        for bus in project.buses {
            strips.append(strip(bus: bus, buses: busNames))
        }
        strips.append(strip(master: project.master))
        return strips
    }

    /// UI-052: the strips' controls, while the tab is showing (the panel rule of UI-040's controls).
    var controls: [UIControl] {
        isOpen ? strips.flatMap(\.ownControls) : []
    }

    private func strip(track: Track, header: TrackHeaderModel, buses: [(NodeIDValue, String)]) -> MixerStripModel {
        let values = MixerStripModel.Values(
            id: track.id, kind: track.kind == .midi ? .midi : .audio, name: track.name, controlPrefix: "mixer.track.\(track.id)",
            gain: track.strip.gain, pan: track.strip.pan, mute: track.strip.mute, solo: track.strip.solo,
            isSelected: header.isSelected, armed: track.armed, inputPair: track.inputPair, monitoring: track.monitoring,
            inputChoices: header.inputControls.compactMap { UInt32($0.id.split(separator: ".").last ?? "") },
            output: track.output, outputTitle: outputTitle(track.output, buses: buses),
            outputChoices: outputChoices(track.output, buses: buses),
            sends: sendValues(track.sends, buses: buses), sendTargets: sendTargets(buses: buses),
            inserts: track.inserts.map(Self.insert))
        return makeStrip(values, header: header, muteControl: header.muteControl, soloControl: header.soloControl)
    }

    private func strip(bus: Bus, buses: [(NodeIDValue, String)]) -> MixerStripModel {
        let prefix = "mixer.bus.\(bus.id)"
        let values = MixerStripModel.Values(
            id: bus.id, kind: .bus, name: bus.name, controlPrefix: prefix,
            gain: bus.strip.gain, pan: bus.strip.pan, mute: bus.strip.mute, solo: bus.strip.solo,
            isSelected: false, armed: false, inputPair: 0, monitoring: .off, inputChoices: [],
            output: bus.output, outputTitle: outputTitle(bus.output, buses: buses),
            outputChoices: outputChoices(bus.output, buses: buses),
            sends: sendValues(bus.sends, buses: buses), sendTargets: sendTargets(buses: buses),
            inserts: bus.inserts.map(Self.insert))
        return makeStrip(values, header: nil, muteControl: switchControl(values, .mute, "Mute"),
                         soloControl: switchControl(values, .solo, "Solo"))
    }

    private func strip(master: MasterChannel) -> MixerStripModel {
        let values = MixerStripModel.Values(
            id: master.id, kind: .master, name: "Master", controlPrefix: "mixer.master",
            gain: master.strip.gain, pan: master.strip.pan, mute: master.strip.mute, solo: false,
            isSelected: false, armed: false, inputPair: 0, monitoring: .off, inputChoices: [],
            output: nil, outputTitle: nil, outputChoices: [], sends: [], sendTargets: [], inserts: master.inserts.map(Self.insert))
        return makeStrip(values, header: nil, muteControl: switchControl(values, .mute, "Mute"), soloControl: nil)
    }

    private func outputTitle(_ output: OutputTarget, buses: [(NodeIDValue, String)]) -> String {
        switch output {
        case .master: "Master"
        case .bus(let id): buses.first { $0.0 == id }?.1 ?? "Bus \(id)"
        }
    }

    /// UI-033: every bus is offered, also ones that would close a cycle: refusing those is the
    /// model's job, and showing its message is the requirement.
    private func outputChoices(_ output: OutputTarget, buses: [(NodeIDValue, String)]) -> [MixerRouteChoice] {
        [MixerRouteChoice(id: window?.project.master.id ?? 0, name: "Master", isCurrent: output == .master)]
            + buses.map { MixerRouteChoice(id: $0.0, name: $0.1, isCurrent: output == .bus($0.0)) }
    }

    private func sendTargets(buses: [(NodeIDValue, String)]) -> [MixerRouteChoice] {
        buses.map { MixerRouteChoice(id: $0.0, name: $0.1, isCurrent: false) }
    }

    private func sendValues(_ sends: [Send], buses: [(NodeIDValue, String)]) -> [MixerSendValues] {
        sends.map { send in
            MixerSendValues(id: send.id, target: send.target, targetName: buses.first { $0.0 == send.target }?.1 ?? "Bus \(send.target)",
                            level: send.level, tap: send.tap)
        }
    }

    private static func insert(_ slot: DeviceSlot) -> MixerInsert {
        MixerInsert(id: slot.id, name: insertName(slot.kind), bypass: slot.bypass)
    }

    static func insertName(_ kind: DeviceSlot.Kind) -> String {
        switch kind {
        case .au(let plugin): plugin.name
        case .vst3(let plugin): plugin.name
        case .builtin(let node):
            switch node {
            case .eq: "EQ"
            case .compressor: "Compressor"
            case .delay: "Delay"
            case .reverb: "Reverb"
            case .sampler: "Sampler"
            default: node.rawValue
            }
        }
    }

    private func makeStrip(_ values: MixerStripModel.Values, header: TrackHeaderModel?, muteControl: UIControl,
                           soloControl: UIControl?) -> MixerStripModel {
        let id = values.id
        let prefix = values.controlPrefix
        return MixerStripModel(
            values: values, header: header, muteControl: muteControl, soloControl: soloControl,
            faderUp: .button("\(prefix).fader.up", "Raise \(values.name)", enabled: values.gain < ChannelStripState.maxGain) { [weak self] in
                self?.setGain(id, FaderTaper.nudged(gain: values.gain, by: FaderTaper.nudgeDB))
            },
            faderDown: .button("\(prefix).fader.down", "Lower \(values.name)", enabled: values.gain > 0) { [weak self] in
                self?.setGain(id, FaderTaper.nudged(gain: values.gain, by: -FaderTaper.nudgeDB))
            },
            faderReset: .button("\(prefix).fader.reset", "Reset \(values.name) to 0 dB", enabled: values.gain != 1) { [weak self] in
                self?.setGain(id, 1)
            },
            panLeft: .button("\(prefix).pan.left", "Pan \(values.name) Left", enabled: values.pan > -1) { [weak self] in
                self?.setPan(id, max(values.pan - PanTaper.nudge, -1))
            },
            panRight: .button("\(prefix).pan.right", "Pan \(values.name) Right", enabled: values.pan < 1) { [weak self] in
                self?.setPan(id, min(values.pan + PanTaper.nudge, 1))
            },
            panCenter: .button("\(prefix).pan.center", "Center \(values.name)", enabled: values.pan != 0) { [weak self] in
                self?.setPan(id, 0)
            },
            clipReset: .button("\(prefix).clip.reset", "Clear Clip Indicator of \(values.name)") { [weak self] in
                self?.meters.clearClip(of: id)
            },
            outputControls: outputControls(values),
            sends: values.sends.map { sendModel($0, values: values) },
            sendAddControls: values.sendTargets.map { target in
                .button("\(prefix).send.add.\(target.id)", "Add Send to \(target.name)") { [weak self] in
                    self?.performRouting(AddSend(channelID: id, busID: target.id))
                }
            })
    }

    /// `<prefix>.output.master|bus.<id>`: a toggle per destination, on for the current one, like the
    /// input menu of a track header.
    private func outputControls(_ values: MixerStripModel.Values) -> [UIControl] {
        guard let output = values.output else { return [] }
        let id = values.id
        let prefix = values.controlPrefix
        var controls: [UIControl] = [
            .toggle("\(prefix).output.master", "Output to Master", isOn: output == .master) { [weak self] in
                guard output != .master else { return }
                self?.performRouting(SetTrackOutput(channelID: id, output: .master))
            },
        ]
        controls += values.outputChoices.dropFirst().map { bus in
            .toggle("\(prefix).output.bus.\(bus.id)", "Output to \(bus.name)", isOn: bus.isCurrent) { [weak self] in
                guard !bus.isCurrent else { return }
                self?.performRouting(SetTrackOutput(channelID: id, output: .bus(bus.id)))
            }
        }
        return controls
    }

    private func sendModel(_ send: MixerSendValues, values: MixerStripModel.Values) -> MixerSendModel {
        let prefix = "\(values.controlPrefix).send.\(send.id)"
        return MixerSendModel(
            values: send,
            levelUp: .button("\(prefix).level.up", "Raise Send to \(send.targetName)", enabled: send.level < Send.maxLevel) { [weak self] in
                self?.setSendLevel(send.id, min(FaderTaper.nudged(gain: send.level, by: FaderTaper.nudgeDB), Send.maxLevel))
            },
            levelDown: .button("\(prefix).level.down", "Lower Send to \(send.targetName)", enabled: send.level > 0) { [weak self] in
                self?.setSendLevel(send.id, FaderTaper.nudged(gain: send.level, by: -FaderTaper.nudgeDB))
            },
            levelReset: .button("\(prefix).level.reset", "Reset Send to \(send.targetName) to 0 dB", enabled: send.level != 1) { [weak self] in
                self?.setSendLevel(send.id, 1)
            },
            tapPre: .toggle("\(prefix).tap.pre", "Pre-Fader Send to \(send.targetName)", isOn: send.tap == .preFader) { [weak self] in
                self?.window?.perform(SetSendTap(sendID: send.id, tap: send.tap == .preFader ? .postFader : .preFader))
            },
            remove: .button("\(prefix).remove", "Remove Send to \(send.targetName)") { [weak self] in
                self?.window?.perform(RemoveSend(sendID: send.id))
            })
    }

    /// A bus's or the master's mute/solo (a track's are the header's).
    private func switchControl(_ values: MixerStripModel.Values, _ param: ParamTarget.StripParam, _ title: String) -> UIControl {
        let on = param == .solo ? values.solo : values.mute
        return .toggle("\(values.controlPrefix).\(param.rawValue)", "\(title) \(values.name)", isOn: on) { [weak self] in
            self?.window?.setStrip(values.id, param, on: !on)
        }
    }

    // MARK: Actions

    private func setGain(_ channel: NodeIDValue, _ gain: Float) {
        window?.perform(SetParam(target: .strip(channel: channel, param: .gain), value: min(max(gain, 0), ChannelStripState.maxGain)))
    }

    private func setPan(_ channel: NodeIDValue, _ pan: Float) {
        window?.perform(SetParam(target: .strip(channel: channel, param: .pan), value: pan))
    }

    private func setSendLevel(_ send: ModelID, _ level: Float) {
        window?.perform(SetSendLevel(sendID: send, level: level))
    }

    /// UI-033: a routing command. A choice the model refuses (MODEL-030) changes nothing and shows
    /// the model's message, with the channels' names so the cycle can be read.
    private func performRouting(_ command: any Command) {
        guard let window else { return }
        do {
            try window.store.perform(command)
        } catch {
            window.toasts.post(.error, .error, title: "\(command.label) failed", message: message(for: error))
        }
    }

    private func message(for error: DAWError) -> String {
        guard case .routingCycle(let path) = error, let window else { return error.description }
        let project = window.project
        let names = path.map { id in
            project.track(id)?.name ?? project.buses.first { $0.id == id }?.name ?? (id == project.master.id ? "Master" : "\(id)")
        }
        return "\(error.description) (\(names.joined(separator: " → ")))"
    }

    // MARK: Gestures (MODEL-003)

    /// Starts a drag of `param`: every `updateDrag` until `endDrag` is one undo step.
    func beginDrag(_ param: MixerParam) {
        guard let store = window?.store else { return }
        endDrag()
        store.beginGesture(param.label)
        dragStore = store
        activeDrag = param
    }

    /// One step of the drag; `position` is the control's, 0…1. A step the model refuses (the
    /// channel went away mid-drag) is skipped.
    func updateDrag(_ param: MixerParam, position: Double) {
        guard activeDrag == param, let store = dragStore else { return }
        try? store.perform(command(param, position: position))
    }

    /// Ends the drag: one undo entry, none if it changed nothing.
    func endDrag() {
        dragStore?.endGesture()
        dragStore = nil
        if activeDrag != nil { activeDrag = nil }
    }

    /// A double-click on the control: 0 dB or centre, one undo step.
    func reset(_ param: MixerParam) {
        endDrag()
        switch param {
        case .gain(let channel): setGain(channel, 1)
        case .pan(let channel): setPan(channel, 0)
        case .sendLevel(let send): setSendLevel(send, 1)
        }
    }

    private func command(_ param: MixerParam, position: Double) -> any Command {
        switch param {
        case .gain(let channel):
            SetParam(target: .strip(channel: channel, param: .gain), value: FaderTaper.gain(position: position))
        case .pan(let channel):
            SetParam(target: .strip(channel: channel, param: .pan), value: PanTaper.pan(position: position))
        case .sendLevel(let send):
            SetSendLevel(sendID: send, level: min(FaderTaper.gain(position: position), Send.maxLevel))
        }
    }

    /// The window's project changed under it: a drag is over and old meters don't apply.
    func documentReplaced() {
        endDrag()
        meters.reset()
    }
}
