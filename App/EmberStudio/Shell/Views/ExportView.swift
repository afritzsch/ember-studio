import DAWModel
import SwiftUI

/// UI-042 (T-082): the export dialog, a strip under the project window's toolbar like the audio
/// settings (inside the window, so `ui.snapshot` shows it, and in the layout, so the AppKit canvases
/// don't draw over it). Every choice is a view-model control (UI-052) in a menu or a toggle, so
/// `ui.perform` drives the same actions a click does.
struct ExportPanel: View {
    let model: ExportModel
    let controls: [String: UIControl]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text("Export").font(.headline)
                field("Range") {
                    menu(model.range.title, id: "export.range.menu", ids: ExportRange.allCases.map { "export.range.\($0.rawValue)" },
                         face: { $0.label.replacingOccurrences(of: "Range: ", with: "") })
                }
                Text(rangeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("export.range.span")
                field("File") {
                    menu(ExportModel.title(model.fileType), id: "export.format.menu",
                         ids: ["wav", "aiff", "caf"].map { "export.format.\($0)" },
                         face: { $0.label.replacingOccurrences(of: "File Type: ", with: "") })
                }
                field("Format") {
                    menu(ExportModel.title(model.sampleFormat), id: "export.sampleFormat.menu",
                         ids: ["int16", "int24", "float32"].map { "export.sampleFormat.\($0)" },
                         face: { $0.label.replacingOccurrences(of: "Sample Format: ", with: "") })
                }
                if let dither = controls["export.dither"] { ControlToggle(control: dither) }
                if let normalize = controls["export.normalize"] { ControlToggle(control: normalize, face: "Normalize") }
                Spacer()
                if let close = controls["export.close"] {
                    ControlButton(control: close, systemImage: "xmark").labelStyle(.iconOnly)
                }
            }
            HStack(spacing: 16) {
                if let tail = controls["export.tail"] { ControlToggle(control: tail, face: "Tail") }
                menu("up to \(ExportModel.tailTitle(model.tailMaxSeconds))", id: "export.tailMax.menu",
                     ids: ExportModel.tailMaxChoices.map { "export.tailMax.\(Int($0))" },
                     face: { $0.label.replacingOccurrences(of: "Tail up to ", with: "") })
                if let metronome = controls["export.metronome"] { ControlToggle(control: metronome) }
                field("To") {
                    Text(model.destination?.path ?? "—")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 360, alignment: .leading)
                        .help(model.destination?.path ?? "")
                        .accessibilityIdentifier("export.destination")
                }
                if let choose = controls["export.choose"] { ControlButton(control: choose, face: "Choose…") }
                Spacer()
                if model.isRunning {
                    HStack(spacing: 6) {
                        ProgressView(value: model.progress).frame(width: 100)
                        Text(model.progressText).font(.caption.monospacedDigit())
                    }
                    .accessibilityIdentifier("export.progress")
                } else if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .accessibilityIdentifier("export.error")
                }
                if let start = controls["export.start"] {
                    ControlButton(control: start).keyboardShortcut(.defaultAction)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityIdentifier("export.panel")
    }

    /// "8.0 s", or why the range has nothing to render.
    private var rangeText: String {
        guard let span = model.span(model.range) else {
            return model.range == .selection ? "No clips selected" : "No loop region"
        }
        return String(format: "%.1f s", model.seconds(span))
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            content()
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
