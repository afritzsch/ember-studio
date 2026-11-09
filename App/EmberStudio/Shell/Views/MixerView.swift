import DAWModel
import SwiftUI

/// UI-030: the Mixer tab: a strip per track and bus (scrolling, lazily) and the master fixed at the
/// right. It reads `mixer.strips` once; each strip is an `Equatable` view of its own values, so a
/// change to one channel re-renders one strip. Meters never pass through here (UI-031).
struct MixerPane: View {
    let mixer: MixerModel

    var body: some View {
        let strips = mixer.strips
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(strips.filter { $0.kind != .master }) { strip in
                        MixerStripView(strip: strip, values: strip.values, mixer: mixer)
                            .equatable()
                    }
                }
            }
            if let master = strips.last, master.kind == .master {
                Divider()
                MixerStripView(strip: master, values: master.values, mixer: mixer)
                    .equatable()
            }
        }
        // UI-031: the meters' one display link, for as long as this tab is showing.
        .background(MeterClock(bank: mixer.meters))
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// A channel strip: name, inserts, sends, output, pan, fader and meter, and the switches. Every
/// button is a view-model control (UI-052); the faders are `MixerSliderView`s.
private struct MixerStripView: View, Equatable {
    let strip: MixerStripModel
    let values: MixerStripModel.Values
    let mixer: MixerModel

    nonisolated static func == (a: Self, b: Self) -> Bool { a.values == b.values }

    private static let width: CGFloat = 112

    var body: some View {
        VStack(spacing: 4) {
            title
            inserts
            sends
            output
            pan
            HStack(spacing: 4) {
                MixerSlider(axis: .vertical, position: strip.faderPosition, mark: FaderTaper.unityPosition,
                            param: .gain(strip.id), mixer: mixer)
                    .frame(width: 24)
                    .accessibilityIdentifier("\(strip.controlPrefix).fader")
                ChannelMeter(channel: strip.id, bank: mixer.meters)
                    .frame(width: 12)
                    .accessibilityIdentifier("\(strip.controlPrefix).meter")
                Text(FaderTaper.label(gain: strip.gain))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                    .accessibilityIdentifier("\(strip.controlPrefix).gain")
            }
            .frame(maxHeight: .infinity)
            switches
        }
        .controlSize(.mini)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(strip.isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .trailing) { Divider() }
    }

    private var title: some View {
        HStack(spacing: 3) {
            if let select = strip.header?.selectControl {
                ControlButton(control: select, face: strip.name)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            } else {
                Text(strip.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(strip.kind.rawValue)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    /// UI-030: read-only until the insert-chain commands exist (DW-149).
    private var inserts: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(strip.inserts.prefix(Self.insertRows)) { insert in
                Text(insert.bypass ? "⊘ \(insert.name)" : insert.name)
                    .foregroundStyle(insert.bypass ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            if strip.inserts.count > Self.insertRows {
                Text("+\(strip.inserts.count - Self.insertRows) more").foregroundStyle(.tertiary)
            }
            if strip.inserts.isEmpty { Text("No inserts").foregroundStyle(.quaternary) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 38)
        .accessibilityIdentifier("\(strip.controlPrefix).inserts")
    }

    private static let insertRows = 3

    /// UI-030: each send's target, level and tap, then the add menu. A fixed height, so the faders
    /// line up across strips; the sends scroll inside it if there are many.
    private var sends: some View {
        VStack(spacing: 2) {
            if strip.sends.count > Self.sendRows {
                ScrollView(.vertical) { sendRows }
            } else {
                sendRows
            }
            Spacer(minLength: 0)
            if strip.kind != .master {
                Menu("+ Send") {
                    ForEach(strip.sendAddControls) { control in
                        ControlButton(control: control, face: control.label.replacingOccurrences(of: "Add Send to ", with: ""))
                    }
                }
                .disabled(strip.sendAddControls.isEmpty)
                .accessibilityIdentifier("\(strip.controlPrefix).send.add.menu")
            }
        }
        .frame(height: 76)
    }

    private static let sendRows = 2

    private var sendRows: some View {
        VStack(spacing: 2) {
            ForEach(strip.sends) { send in
                VStack(spacing: 0) {
                    HStack(spacing: 2) {
                        Text(send.values.targetName)
                            .font(.system(size: 9))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        ControlToggle(control: send.tapPre, face: "Pre")
                        ControlButton(control: send.remove, systemImage: "xmark")
                            .buttonStyle(.plain)
                    }
                    MixerSlider(axis: .horizontal, position: send.levelPosition, mark: FaderTaper.unityPosition,
                                param: .sendLevel(send.id), mixer: mixer)
                        .frame(height: 10)
                        .accessibilityIdentifier("\(strip.controlPrefix).send.\(send.id).level")
                }
            }
        }
    }

    /// UI-033: a menu of toggles, every destination offered; the model refuses a cycle (a toast) and
    /// the menu keeps showing the real output, because it shows the project.
    @ViewBuilder private var output: some View {
        if let title = strip.outputTitle {
            Menu(title) {
                ForEach(strip.outputControls) { control in
                    ControlToggle(control: control, face: control.label.replacingOccurrences(of: "Output to ", with: ""))
                }
            }
            .accessibilityIdentifier("\(strip.controlPrefix).output.menu")
        } else {
            Text("Main Out")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(height: 16)
        }
    }

    private var pan: some View {
        HStack(spacing: 3) {
            MixerSlider(axis: .horizontal, position: strip.panPosition, mark: 0.5, param: .pan(strip.id), mixer: mixer)
                .frame(height: 12)
                .accessibilityIdentifier("\(strip.controlPrefix).pan")
            Text(PanTaper.label(pan: strip.pan))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
        }
    }

    private var switches: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                ControlToggle(control: strip.muteControl, face: "M").fixedSize()
                if let solo = strip.soloControl { ControlToggle(control: solo, face: "S").fixedSize() }
                if let header = strip.header {
                    // DW-202: the header's own controls.
                    ControlToggle(control: header.armControl, face: header.armed ? "●" : "○")
                        .tint(.red)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            if let header = strip.header {
                HStack(spacing: 3) {
                    if !header.inputControls.isEmpty {
                        Menu(TrackHeaderModel.inputTitle(header.inputPair)) {
                            ForEach(header.inputControls) { control in
                                ControlToggle(control: control, face: control.label.replacingOccurrences(of: "Input ", with: ""))
                            }
                        }
                        .accessibilityIdentifier("\(strip.controlPrefix).input.menu")
                    }
                    Menu("Mon \(TrackHeaderModel.monitoringTitle(header.monitoring))") {
                        ForEach(header.monitorControls) { control in
                            ControlToggle(control: control, face: control.label.replacingOccurrences(of: "Monitoring ", with: ""))
                        }
                    }
                    .accessibilityIdentifier("\(strip.controlPrefix).monitor.menu")
                }
            }
        }
    }
}

/// UI-030: a `MixerSliderView` in SwiftUI. It reports to the model; SwiftUI only pushes the value back.
private struct MixerSlider: NSViewRepresentable {
    let axis: MixerSliderView.Axis
    let position: Double
    let mark: Double?
    let param: MixerParam
    let mixer: MixerModel

    func makeNSView(context: Context) -> MixerSliderView {
        let view = MixerSliderView(axis: axis)
        view.mark = mark
        view.onBegin = { [weak mixer] in mixer?.beginDrag(param) }
        view.onChange = { [weak mixer] position in mixer?.updateDrag(param, position: position) }
        view.onEnd = { [weak mixer] in mixer?.endDrag() }
        view.onReset = { [weak mixer] in mixer?.reset(param) }
        return view
    }

    func updateNSView(_ view: MixerSliderView, context: Context) {
        view.position = position
    }
}

/// UI-031: a meter in SwiftUI. `MeterBank` draws it; SwiftUI only places it.
private struct ChannelMeter: NSViewRepresentable {
    let channel: NodeIDValue
    let bank: MeterBank

    func makeNSView(context: Context) -> ChannelMeterView { ChannelMeterView(channel: channel, bank: bank) }

    func updateNSView(_ view: ChannelMeterView, context: Context) {
        view.update(channel: channel)
    }
}

/// UI-031: the zero-size view that owns the meters' display link.
private struct MeterClock: NSViewRepresentable {
    let bank: MeterBank

    func makeNSView(context: Context) -> MeterClockView { MeterClockView(bank: bank) }
    func updateNSView(_ view: MeterClockView, context: Context) {}
}
