import AppKit
import DAWModel
import SwiftUI

/// UI-032 (T-065): the Device Chain tab. A bar with the channel picker and the device picker, then
/// the channel's devices left to right as cards. Every button, toggle and menu item is a view-model
/// control (UI-052); param sliders are `MixerSliderView`s (one undo step per drag, double-click
/// resets); a card dragged onto another moves there (`MoveDevice`).
struct DeviceChainPane: View {
    let model: DeviceChainModel

    var body: some View {
        let devices = model.devices
        let controls = Dictionary(model.controls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Device Chain").font(.headline)
                Menu(model.channelName(model.channelID)) {
                    ForEach(model.channelChoices, id: \.id) { choice in
                        if let control = controls["deviceChain.channel.\(choice.id)"] {
                            ControlToggle(control: control, face: choice.name)
                        }
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("deviceChain.channel.menu")
                DevicePickerMenu(title: "+ Device", choices: model.choices, controls: controls, idPrefix: "deviceChain.add")
                    .accessibilityIdentifier("deviceChain.add.menu")
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if devices.isEmpty {
                Text("No devices on \(model.channelName(model.channelID)). Add one with “+ Device”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(devices) { card in
                            DeviceCardView(card: card, model: model)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityIdentifier("deviceChain.pane")
    }
}

/// DW-250 (T-065): the device picker, built-ins then AU and VST3 effects; shared with the mixer's
/// inserts list. `idPrefix` + `.<choice key>` is each item's control id.
struct DevicePickerMenu: View {
    let title: String
    let choices: [DeviceChoice]
    let controls: [String: UIControl]
    let idPrefix: String

    var body: some View {
        Menu(title) {
            ForEach([DeviceChoice.Group.builtin, .au, .vst3], id: \.self) { group in
                let items = choices.filter { $0.group == group }
                if !items.isEmpty {
                    Section(group.rawValue) {
                        ForEach(items) { choice in
                            if let control = controls["\(idPrefix).\(choice.key)"] {
                                ControlButton(control: control, face: choice.name)
                            }
                        }
                    }
                }
            }
        }
        .fixedSize()
    }
}

/// One device: title bar (bypass, editor, generic controls, move, remove), status, sidechain, then
/// its generic controls.
private struct DeviceCardView: View {
    let card: DeviceCardModel
    let model: DeviceChainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if card.safeModeBypassed {
                // PLUG-021, DW-226: the slot is bypassed by safe mode, whatever the document says.
                Label("Bypassed by safe mode", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("\(card.controlPrefix).safeMode")
            } else if card.loaded == false {
                Text(card.loadError.map { "Not loaded: \($0)" } ?? "Not loaded")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if card.acceptsSidechain { sidechain }
            Divider()
            if card.showsParams {
                params
            } else {
                Text(card.editorOpen ? "Editor open" : "Open the editor, or show the generic controls (⚙).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(width: 220, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .opacity(card.isBypassed ? 0.6 : 1)
        .dropDestination(for: String.self) { items, _ in
            guard card.position != nil, let dragged = items.first.flatMap(NodeIDValue.init) else { return false }
            model.move(dragged, onto: card.id)
            return true
        }
        .accessibilityIdentifier(card.controlPrefix)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(card.isInstrument ? "♪ \(card.name)" : card.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .help(card.name)
                    .draggable(String(card.id))
                Spacer(minLength: 0)
                Text(card.format == "builtin" ? "" : card.format.uppercased())
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: 3) {
            if let bypass = card.control("bypass") { ControlToggle(control: bypass, face: "⏻") }
            if let editor = card.control("editor") { ControlToggle(control: editor, face: "Edit") }
            if let generic = card.control("generic") { ControlToggle(control: generic, face: "⚙") }
            if let up = card.control("moveUp") { ControlButton(control: up, systemImage: "chevron.left").labelStyle(.iconOnly) }
            if let down = card.control("moveDown") { ControlButton(control: down, systemImage: "chevron.right").labelStyle(.iconOnly) }
            Spacer(minLength: 0)
            if let remove = card.control("remove") { ControlButton(control: remove, systemImage: "xmark").labelStyle(.iconOnly) }
        }
        .controlSize(.mini)
    }

    private var sidechain: some View {
        HStack(spacing: 4) {
            Text("Sidechain").font(.caption).foregroundStyle(.secondary)
            Menu(card.sidechain?.name ?? "None") {
                if let none = card.control("sidechain.none") { ControlToggle(control: none, face: "None") }
                ForEach(card.controls.filter { $0.id.hasPrefix("\(card.controlPrefix).sidechain.") && !$0.id.hasSuffix(".none") }) { control in
                    ControlToggle(control: control, face: control.label.components(separatedBy: " from ").last)
                }
            }
            .controlSize(.mini)
            .fixedSize()
            .accessibilityIdentifier("\(card.controlPrefix).sidechain.menu")
        }
    }

    private var params: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 5) {
                if card.params.isEmpty {
                    Text(card.isPlugin ? "No parameters reported" : "No parameters").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(card.params) { param in
                    DeviceParamRow(param: param, card: card, model: model)
                }
            }
        }
    }
}

/// One generic control: name and value, then a slider, toggle or menu (DW-196's steps).
private struct DeviceParamRow: View {
    let param: DeviceParamModel
    let card: DeviceCardModel
    let model: DeviceChainModel

    var body: some View {
        let prefix = "param.\(param.index)"
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(param.row.name)
                    .font(.system(size: 10))
                    .lineLimit(1)
                if param.automated {
                    Text("A").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange).help("Automated")
                }
                Spacer(minLength: 0)
                if param.style != "menu" {
                    Text(param.display)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(card.controlPrefix).\(prefix).value")
                }
            }
            switch param.style {
            case "toggle":
                if let toggle = card.control(prefix) {
                    ControlToggle(control: toggle, face: "", checkbox: true).controlSize(.mini)
                }
            case "menu":
                Menu(param.display) {
                    ForEach(card.controls.filter { $0.id.hasPrefix("\(card.controlPrefix).\(prefix).value.") }) { control in
                        ControlToggle(control: control, face: control.label.replacingOccurrences(of: "\(param.row.name) ", with: ""))
                    }
                }
                .controlSize(.mini)
                .fixedSize()
                .accessibilityIdentifier("\(card.controlPrefix).\(prefix).menu")
            default:
                DeviceParamSlider(position: param.position, key: DeviceParamKey(slot: param.slot, index: param.index), model: model)
                    .frame(height: 16)
                    .accessibilityIdentifier("\(card.controlPrefix).\(prefix)")
            }
        }
    }
}

/// A param's slider: `MixerSliderView`, driving the chain model's gesture (one undo step per drag,
/// through the automation recorder, DW-254); a double-click resets it.
private struct DeviceParamSlider: NSViewRepresentable {
    let position: Double
    let key: DeviceParamKey
    let model: DeviceChainModel

    func makeNSView(context: Context) -> MixerSliderView {
        MixerSliderView(axis: .horizontal)
    }

    func updateNSView(_ view: MixerSliderView, context: Context) {
        // Set on every update: SwiftUI may reuse the view for another param.
        let key = key
        view.onBegin = { [weak model] in model?.beginDrag(key) }
        view.onChange = { [weak model] position in model?.updateDrag(key, position: position) }
        view.onEnd = { [weak model] in model?.endDrag() }
        view.onReset = { [weak model] in model?.reset(key) }
        view.position = position
    }
}
