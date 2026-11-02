import DAWModel
import SwiftUI

/// The project window (12 *Layout*): toolbar, browser | arrange | inspector, bottom pane, toasts.
/// Thin over `ProjectWindowModel` (UI-003); the arrange canvas, mixer and the other panes are
/// placeholders until their tasks (T-033, T-076, …) fill them in.
struct ProjectWindowView: View {
    @Bindable var model: ProjectWindowModel

    var body: some View {
        let controls = Dictionary(model.controls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(spacing: 0) {
            ToolbarRow(model: model, controls: controls)
            Divider()
            HSplitView {
                if model.showsBrowser {
                    PanePlaceholder(title: "Browser", detail: "Files and plugins")
                        .frame(minWidth: 140, idealWidth: 180, maxWidth: 260)
                }
                ArrangeArea(model: model)
                    .frame(minWidth: 320, maxWidth: .infinity)
                if model.showsInspector {
                    InspectorPane(model: model)
                        .frame(minWidth: 160, idealWidth: 200, maxWidth: 280)
                }
            }
            if let pane = model.bottomPane {
                Divider()
                PanePlaceholder(title: pane.title, detail: "")
                    .frame(height: 140)
            }
            Divider()
            BottomTabs(controls: controls)
        }
        .overlay(alignment: .bottomTrailing) {
            ToastStack(center: model.toasts)
                .padding(12)
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

private struct ToolbarRow: View {
    let model: ProjectWindowModel
    let controls: [String: UIControl]

    var body: some View {
        HStack(spacing: 8) {
            if let play = controls["transport.play"] { ControlButton(control: play, systemImage: "play.fill") }
            if let stop = controls["transport.stop"] { ControlButton(control: stop, systemImage: "stop.fill") }
            Text(Self.position(model.transport.tick))
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("transport.position")
            Spacer()
            if let undo = controls["edit.undo"] { ControlButton(control: undo, systemImage: "arrow.uturn.backward") }
            if let redo = controls["edit.redo"] { ControlButton(control: redo, systemImage: "arrow.uturn.forward") }
            if let out = controls["zoom.out"] { ControlButton(control: out, systemImage: "minus.magnifyingglass") }
            if let zoomIn = controls["zoom.in"] { ControlButton(control: zoomIn, systemImage: "plus.magnifyingglass") }
            if let browser = controls["pane.browser"] { ControlToggle(control: browser) }
            if let inspector = controls["pane.inspector"] { ControlToggle(control: inspector) }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Bars.beats.ticks at 4/4 (the tempo map's signature is T-034's).
    static func position(_ tick: Tick) -> String {
        let ppq: Int64 = 960
        let beat = max(tick.raw, 0) / ppq
        return String(format: "%d.%d.%03d", beat / 4 + 1, beat % 4 + 1, max(tick.raw, 0) % ppq)
    }
}

private struct ArrangeArea: View {
    let model: ProjectWindowModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.trackHeaders) { track in
                        TrackHeaderRow(track: track)
                            .frame(height: ProjectWindowModel.trackHeight)
                        Divider()
                    }
                    if model.trackHeaders.isEmpty {
                        Text("No tracks yet")
                            .foregroundStyle(.secondary)
                            .padding(24)
                    }
                }
            }
            .onAppear { model.viewportHeight = geometry.size.height }
            .onChange(of: geometry.size.height) { _, height in model.viewportHeight = height }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct TrackHeaderRow: View {
    let track: TrackHeaderModel

    var body: some View {
        HStack(spacing: 6) {
            ControlButton(control: track.selectControl)
                .buttonStyle(.plain)
                .font(.headline)
            Text(track.kind == .midi ? "MIDI" : "Audio")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            ControlToggle(control: track.muteControl, face: "M")
            ControlToggle(control: track.soloControl, face: "S")
        }
        .padding(.horizontal, 10)
        .background(track.isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

private struct InspectorPane: View {
    let model: ProjectWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inspector").font(.headline)
            if let id = model.selectedTracks.first, let track = model.project.tracks.first(where: { $0.id == id }) {
                Text(track.name)
                Text("Gain \(String(format: "%.2f", track.strip.gain)) · Pan \(String(format: "%.2f", track.strip.pan))")
                    .font(.caption)
            } else {
                Text("Nothing selected").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BottomTabs: View {
    let controls: [String: UIControl]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BottomPane.allCases, id: \.self) { pane in
                if let control = controls["pane.bottom.\(pane.rawValue)"] { ControlToggle(control: control) }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

private struct PanePlaceholder: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// UI-004: the window's toasts, newest at the bottom.
struct ToastStack: View {
    let center: ToastCenter

    var body: some View {
        let controls = Dictionary(center.controls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(center.toasts) { toast in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: toast.severity == .info ? "info.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(toast.severity == .error ? .red : toast.severity == .warning ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(toast.title).font(.headline)
                        if !toast.message.isEmpty { Text(toast.message).font(.caption).lineLimit(4) }
                    }
                    if let action = controls["toast.\(toast.id).action"] { ControlButton(control: action) }
                    if let dismiss = controls["toast.\(toast.id).dismiss"] {
                        ControlButton(control: dismiss, systemImage: "xmark").labelStyle(.iconOnly).buttonStyle(.plain)
                    }
                }
                .padding(10)
                .frame(maxWidth: 360, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("toast.\(toast.id)")
            }
        }
    }
}
