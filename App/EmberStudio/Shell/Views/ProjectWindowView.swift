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
                ArrangeArea(model: model, controls: controls)
                    .frame(minWidth: 320, maxWidth: .infinity)
                if model.showsInspector {
                    InspectorPane(model: model)
                        .frame(minWidth: 160, idealWidth: 200, maxWidth: 280)
                }
            }
            if let pane = model.bottomPane {
                Divider()
                if pane == .pianoRoll {
                    // UI-020: the piano roll needs room for its keyboard and velocity lane.
                    PianoRollPane(model: model.pianoRoll, controls: controls)
                        .frame(height: 300)
                } else {
                    PanePlaceholder(title: pane.title, detail: "")
                        .frame(height: 140)
                }
            }
            Divider()
            BottomTabs(controls: controls)
        }
        .overlay(alignment: .top) {
            // UI-040: the audio settings, over the arrange area.
            if model.audioPrefs.isOpen {
                AudioPreferencesPanel(model: model.audioPrefs, controls: controls)
                    .padding(.top, 48)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ToastStack(center: model.toasts)
                .padding(12)
        }
        // Opaque: cacheDisplay (UI-051) doesn't paint the window background behind the view.
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 480)
    }
}

/// 12 *Layout*: transport · position (bars | time) · tempo/signature · record/loop/metronome ·
/// CPU/xruns, then undo/redo, zoom and the pane toggles. Every button is a view-model control
/// (UI-052), and the shortcuts (UI-002) run the same ones.
private struct ToolbarRow: View {
    let model: ProjectWindowModel
    let controls: [String: UIControl]

    var body: some View {
        HStack(spacing: 8) {
            if let play = controls["transport.play"] { ControlButton(control: play, systemImage: "play.fill") }
            if let stop = controls["transport.stop"] { ControlButton(control: stop, systemImage: "stop.fill") }
            // The default toggle look (filled when on, like loop): a red tint renders on and off
            // almost alike in the dark appearance.
            if let record = controls["transport.record"] { ControlToggle(control: record, face: "●") }
            if let loop = controls["transport.loop"] { ControlToggle(control: loop, face: "⟲") }
            if let metronome = controls["transport.metronome"] { ControlToggle(control: metronome, face: "♩") }
            Divider().frame(height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.positionBBT)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("transport.position")
                Text(model.positionTime)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transport.time")
            }
            .frame(minWidth: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(format: "%.2f BPM", model.tempo))
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("transport.tempo")
                Text(model.signature)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transport.signature")
            }
            Spacer()
            // DW-183: a session-rate change re-converting the project's audio (IO-033).
            if let reload = model.audioPrefs.reloadText {
                ReloadProgress(text: reload, fraction: model.audioPrefs.reload?.fraction ?? 0, id: "toolbar.reload")
            }
            Text(String(format: "CPU %.0f%% · xruns %llu", model.telemetry.dspLoadPercent, model.telemetry.xruns))
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.telemetry.xruns > 0 ? Color.orange : Color.secondary)
                .accessibilityIdentifier("engine.load")
            if let undo = controls["edit.undo"] { ControlButton(control: undo, systemImage: "arrow.uturn.backward") }
            if let redo = controls["edit.redo"] { ControlButton(control: redo, systemImage: "arrow.uturn.forward") }
            if let out = controls["zoom.out"] { ControlButton(control: out, systemImage: "minus.magnifyingglass") }
            if let zoomIn = controls["zoom.in"] { ControlButton(control: zoomIn, systemImage: "plus.magnifyingglass") }
            if let browser = controls["pane.browser"] { ControlToggle(control: browser) }
            if let inspector = controls["pane.inspector"] { ControlToggle(control: inspector) }
            if let settings = controls["prefs.audio"] { ControlToggle(control: settings, face: "Audio") }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// The arrange area (12 *Layout*): a bar with the snap menu and clip actions, then track headers
/// beside the timeline canvas (UI-010). The canvas scrolls both ways itself; the headers follow its
/// vertical scroll.
private struct ArrangeArea: View {
    let model: ProjectWindowModel
    let controls: [String: UIControl]

    var body: some View {
        VStack(spacing: 0) {
            ArrangeBar(model: model.arrange, controls: controls)
            Divider()
            HStack(spacing: 0) {
                TrackHeaderColumn(model: model)
                    .frame(width: 200)
                Divider()
                TimelineCanvas(model: model.arrange)
                    .accessibilityIdentifier("arrange.canvas")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ArrangeBar: View {
    let model: ArrangeModel
    let controls: [String: UIControl]

    var body: some View {
        HStack(spacing: 6) {
            Menu("Snap: \(model.snap.title)") {
                ForEach(SnapMode.allCases, id: \.self) { mode in
                    if let control = controls["snap.\(mode.rawValue)"] { ControlToggle(control: control, face: mode.title) }
                }
            }
            .fixedSize()
            .accessibilityIdentifier("snap.menu")
            Menu("Add Track") {
                if let audio = controls["track.add.audio"] { ControlButton(control: audio) }
                if let midi = controls["track.add.midi"] { ControlButton(control: midi) }
            }
            .fixedSize()
            .accessibilityIdentifier("track.add.menu")
            Text("⌘ while dragging: no snap").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let duplicate = controls["edit.duplicate"] { ControlButton(control: duplicate, systemImage: "plus.square.on.square") }
            if let split = controls["edit.split"] { ControlButton(control: split, systemImage: "scissors") }
            if let delete = controls["edit.delete"] { ControlButton(control: delete, systemImage: "trash") }
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// Track headers in rows of `trackHeight`, below a spacer as tall as the canvas's ruler, offset by
/// the canvas's vertical scroll.
private struct TrackHeaderColumn: View {
    let model: ProjectWindowModel

    var body: some View {
        GeometryReader { _ in
            VStack(spacing: 0) {
                Color.clear.frame(height: TimelineGeometry.rulerHeight)
                if model.trackHeaders.isEmpty {
                    Text("No tracks yet")
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
                ForEach(model.trackHeaders) { track in
                    TrackHeaderRow(track: track)
                        .frame(height: ProjectWindowModel.trackHeight - 1)
                    Divider()
                }
            }
            .offset(y: -model.scrollY)
        }
        .clipped()
    }
}

/// UI-010: the AppKit canvas in SwiftUI. The view model drives it; SwiftUI only places it.
private struct TimelineCanvas: NSViewRepresentable {
    let model: ArrangeModel

    func makeNSView(context: Context) -> TimelineCanvasView { TimelineCanvasView(model: model) }
    func updateNSView(_ view: TimelineCanvasView, context: Context) {}
}

private struct TrackHeaderRow: View {
    let track: TrackHeaderModel

    var body: some View {
        HStack(spacing: 6) {
            ControlButton(control: track.selectControl, face: track.name)
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

/// UI-020: the piano roll pane: a bar with the tool, snap, quantize and transpose controls (all
/// view-model controls, UI-052) over the AppKit canvas.
private struct PianoRollPane: View {
    let model: PianoRollModel
    let controls: [String: UIControl]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                if model.isOpen {
                    ForEach(PianoRollTool.allCases, id: \.self) { tool in
                        if let control = controls["pianoRoll.tool.\(tool.rawValue)"] { ControlToggle(control: control, face: tool.title) }
                    }
                    Menu("Snap: \(model.snap.title)") {
                        ForEach(SnapMode.allCases, id: \.self) { mode in
                            if let control = controls["pianoRoll.snap.\(mode.rawValue)"] { ControlToggle(control: control, face: mode.title) }
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("pianoRoll.snap.menu")
                    Divider().frame(height: 14)
                    if let quantize = controls["pianoRoll.quantize"] { ControlButton(control: quantize) }
                    Menu("Grid: \(model.quantizeGrid.title)") {
                        ForEach(SnapMode.allCases.filter { $0 != .off }, id: \.self) { mode in
                            if let control = controls["pianoRoll.quantize.grid.\(mode.rawValue)"] { ControlToggle(control: control, face: mode.title) }
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("pianoRoll.quantize.grid.menu")
                    Menu("Strength: \(Int((model.quantizeStrength * 100).rounded()))%") {
                        ForEach(PianoRollModel.strengthPresets, id: \.self) { percent in
                            if let control = controls["pianoRoll.quantize.strength.\(percent)"] {
                                ControlToggle(control: control, face: "\(percent)%")
                            }
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("pianoRoll.quantize.strength.menu")
                    Divider().frame(height: 14)
                    if let down = controls["pianoRoll.transpose.down"] { ControlButton(control: down, systemImage: "arrow.down") }
                    if let up = controls["pianoRoll.transpose.up"] { ControlButton(control: up, systemImage: "arrow.up") }
                    if let audition = controls["pianoRoll.audition"] { ControlToggle(control: audition, face: "Audition") }
                    Spacer()
                    if let delete = controls["pianoRoll.delete"] { ControlButton(control: delete, systemImage: "trash") }
                    if let close = controls["pianoRoll.close"] { ControlButton(control: close, systemImage: "xmark") }
                } else {
                    Spacer()
                    if let open = controls["pianoRoll.open"] { ControlButton(control: open) }
                }
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            PianoRollCanvas(model: model)
                .accessibilityIdentifier("pianoRoll.canvas")
        }
    }

    private var title: String {
        guard let clip = model.clip else { return "Piano Roll" }
        return "\(model.track?.name ?? "MIDI") · \(clip.notes.count) notes"
    }
}

/// UI-020: the AppKit piano roll in SwiftUI. The view model drives it; SwiftUI only places it.
private struct PianoRollCanvas: NSViewRepresentable {
    let model: PianoRollModel

    func makeNSView(context: Context) -> PianoRollView { PianoRollView(model: model) }
    func updateNSView(_ view: PianoRollView, context: Context) {}
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
