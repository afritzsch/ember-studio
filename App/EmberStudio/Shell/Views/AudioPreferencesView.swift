import DAWModel
import SwiftUI

/// UI-040 (T-055): the audio settings, a strip under the project window's toolbar (inside the
/// window, so `ui.snapshot` shows it). Every choice is a view-model control (UI-052) in a menu, like the snap
/// menu, so `ui.perform` drives the same actions a click does.
struct AudioPreferencesPanel: View {
    let model: AudioPreferencesModel
    let controls: [String: UIControl]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text("Audio Settings").font(.headline)
                field("Driver") {
                    Text(driverText).foregroundStyle(.secondary).accessibilityIdentifier("prefs.audio.driver")
                }
                field("Output") {
                    menu(model.outputTitle, id: "prefs.audio.output.menu",
                         ids: ["prefs.audio.output.default"] + model.outputDevices.map { "prefs.audio.output.\($0.id)" },
                         face: { $0.label.replacingOccurrences(of: "Output: ", with: "") })
                }
                field("Input") {
                    menu(model.inputTitle, id: "prefs.audio.input.menu",
                         ids: ["prefs.audio.input.default"] + model.inputDevices.map { "prefs.audio.input.\($0.id)" },
                         face: { $0.label.replacingOccurrences(of: "Input: ", with: "") })
                }
                Spacer()
                if let refresh = controls["prefs.audio.refresh"] {
                    ControlButton(control: refresh, systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                if let close = controls["prefs.audio.close"] {
                    ControlButton(control: close, systemImage: "xmark").labelStyle(.iconOnly)
                }
            }
            HStack(spacing: 16) {
                field("Sample rate") {
                    // DW-183: the project's rate; changing it re-converts its audio (IO-033).
                    menu(AudioPreferencesModel.khz(model.sessionSampleRate), id: "prefs.audio.sampleRate.menu",
                         ids: AudioPreferencesModel.sampleRates.map { "prefs.audio.sampleRate.\(Int($0))" },
                         face: { $0.label.replacingOccurrences(of: "Sample Rate ", with: "") })
                }
                field("Buffer") {
                    menu(model.config.map { "\($0.bufferFrames) samples" } ?? "—", id: "prefs.audio.buffer.menu",
                         ids: AudioPreferencesModel.bufferSizes.map { "prefs.audio.buffer.\($0)" },
                         face: { $0.label.replacingOccurrences(of: "Buffer ", with: "") })
                }
                field("Input channels") {
                    menu(model.config.map { "\($0.inputChannels)" } ?? "—", id: "prefs.audio.inputChannels.menu",
                         ids: model.inputChannelChoices.map { "prefs.audio.inputChannels.\($0)" }, face: { $0.label })
                }
                field("Latency") {
                    Text(model.latencyText)
                        .font(.callout.monospacedDigit())
                        .accessibilityIdentifier("prefs.audio.latency")
                }
                Spacer()
                if let reload = model.reloadText {
                    ReloadProgress(text: reload, fraction: model.reload?.fraction ?? 0)
                }
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .accessibilityIdentifier("prefs.audio.error")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityIdentifier("prefs.audio.panel")
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            content()
        }
    }

    private var driverText: String {
        switch model.driver {
        case .coreAudio: "CoreAudio"
        case .fake: "Fake devices (testing)"
        case nil: "Offline (no device)"
        }
    }

    /// A menu of toggles: the one that is on is checked.
    private func menu(_ title: String, id: String, ids: [String], face: @escaping (UIControl) -> String) -> some View {
        Menu(title) {
            ForEach(ids, id: \.self) { controlID in
                if let control = controls[controlID] { ControlToggle(control: control, face: face(control)) }
            }
        }
        .fixedSize()
        .disabled(ids.allSatisfy { controls[$0]?.isEnabled != true })
        .accessibilityIdentifier(id)
    }
}

/// DW-183: a re-conversion pass's progress (IO-033), in the toolbar and the settings panel.
struct ReloadProgress: View {
    let text: String
    let fraction: Double
    var id = "prefs.audio.reload"

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: fraction).frame(width: 80)
            Text(text).font(.caption.monospacedDigit()).lineLimit(1)
        }
        .accessibilityIdentifier(id)
    }
}
