import DAWModel
import SwiftUI

/// UI-043 (T-083): the crash-recovery dialog, a strip under the project window's toolbar like the
/// export dialog (inside the window, so `ui.snapshot` shows it, and in the layout, so the AppKit
/// canvases don't draw over it). Every answer is a view-model control (UI-052), drawn only with
/// `ControlButton`/`ControlToggle`, so `ui.perform` runs the same actions a click does.
struct CrashRecoveryPanel: View {
    let model: CrashRecoveryModel
    let controls: [String: UIControl]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(model.title).font(.headline)
            }
            Text(model.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("crashRecovery.message")
            ForEach(model.entries) { entry in
                EntryRow(entry: entry, recover: controls["crashRecovery.project.\(entry.id).recover"])
            }
            HStack(spacing: 12) {
                if model.isOpening {
                    ProgressView().controlSize(.small)
                    Text("Opening…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let dontOpen = controls["crashRecovery.dontOpen"] { ControlButton(control: dontOpen) }
                if let normal = controls["crashRecovery.openNormally"] { ControlButton(control: normal) }
                if let safe = controls["crashRecovery.openSafe"] {
                    ControlButton(control: safe).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .accessibilityIdentifier("crashRecovery.panel")
    }

    private struct EntryRow: View {
        let entry: CrashRecoveryModel.Entry
        let recover: UIControl?

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: entry.canOpen ? "folder" : "questionmark.folder")
                    Text(entry.name).fontWeight(.medium)
                    Text(entry.path ?? "never saved: nothing to reopen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let recover {
                        ControlToggle(control: recover, face: "Recover autosave", checkbox: true)
                    }
                }
                Text(entry.plugins.isEmpty
                     ? "No plugins"
                     : "Plugins: " + entry.plugins.map { "\($0.name) (\($0.format == "au" ? "AU" : "VST3"))" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
            .accessibilityIdentifier("crashRecovery.project.\(entry.id)")
        }
    }
}

/// PLUG-021, DW-226 (T-083): the banner a window in safe mode shows under its toolbar.
struct SafeModeBanner: View {
    let model: ProjectWindowModel
    let controls: [String: UIControl]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.yellow)
            Text(model.safeModeMessage)
                .font(.callout)
                .lineLimit(2)
                .accessibilityIdentifier("safeMode.banner")
            Spacer()
            if let enable = controls["safeMode.enablePlugins"] { ControlButton(control: enable) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }
}
