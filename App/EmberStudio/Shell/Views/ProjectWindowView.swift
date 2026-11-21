import DAWModel
import SwiftUI

/// The project window (12 *Layout*): toolbar, browser | arrange | inspector, bottom pane, toasts.
/// Thin over `ProjectWindowModel` (UI-003).
struct ProjectWindowView: View {
    @Bindable var model: ProjectWindowModel

    var body: some View {
        let controls = Dictionary(model.windowControls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(spacing: 0) {
            ToolbarRow(model: model, controls: controls)
            Divider()
            // UI-043 (T-083): the crash-recovery dialog at launch, and the safe-mode banner (PLUG-021).
            if let crash = model.crashRecovery, crash.isPresented {
                CrashRecoveryPanel(model: crash, controls: controls)
                Divider()
            }
            if model.store.isSafeMode {
                SafeModeBanner(model: model, controls: controls)
                Divider()
            }
            // UI-040: the audio settings, a strip under the toolbar. In the layout rather than an
            // overlay: the AppKit canvases (layer-backed, Metal) would draw over a SwiftUI overlay.
            if model.audioPrefs.isOpen {
                AudioPreferencesPanel(model: model.audioPrefs, controls: controls)
                Divider()
            }
            // UI-042 (T-082): the export dialog, a strip like the audio settings.
            if model.exportDialog.isOpen {
                ExportPanel(model: model.exportDialog, controls: controls)
                Divider()
            }
            // UI-041 (T-065): the plugin manager, a strip like the audio settings.
            if model.pluginPanel.isOpen {
                PluginManagerPanel(panel: model.pluginPanel, controls: controls)
                Divider()
            }
            HSplitView {
                if model.showsBrowser {
                    // UI-060 (T-124): sidebar and content list side by side.
                    BrowserPane(model: model.browser)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 280)
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
                } else if pane == .mixer {
                    // UI-030: strips need room for the fader between sends, pan and the buttons.
                    MixerPane(mixer: model.mixer)
                        .frame(height: 340)
                } else {
                    // UI-032 (T-065): device cards need room for a column of generic controls.
                    DeviceChainPane(model: model.deviceChain)
                        .frame(height: 300)
                }
            }
            Divider()
            BottomTabs(controls: controls)
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
            // DW-180 (T-095): editable; a commit sets bar 1's tempo / signature (one undo entry).
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    if let tempo = controls["transport.tempo"] { CommitTextField(control: tempo, width: 52) }
                    Text("BPM").font(.caption).foregroundStyle(.secondary).fixedSize()
                    Group {
                        if let down = controls["transport.tempo.down"] { ControlButton(control: down, systemImage: "minus") }
                        if let up = controls["transport.tempo.up"] { ControlButton(control: up, systemImage: "plus") }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .imageScale(.small)
                }
                HStack(spacing: 2) {
                    if let signature = controls["transport.signature"] { CommitTextField(control: signature, width: 40) }
                    Menu {
                        ForEach(ProjectWindowModel.signaturePresets.indices, id: \.self) { i in
                            let preset = ProjectWindowModel.signaturePresets[i]
                            if let item = controls["transport.signature.\(preset.numerator).\(preset.denominator)"] {
                                ControlToggle(control: item)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityIdentifier("transport.signature.menu")
                }
                .font(.caption)
            }
            .fixedSize()
            Spacer()
            // DW-183: a session-rate change re-converting the project's audio (IO-033).
            if let reload = model.audioPrefs.reloadText {
                ReloadProgress(text: reload, fraction: model.audioPrefs.reload?.fraction ?? 0, id: "toolbar.reload")
            }
            // UI-042 (T-082): a running export, also with its panel closed.
            if model.exportDialog.isRunning {
                ReloadProgress(text: model.exportDialog.progressText, fraction: model.exportDialog.progress, id: "toolbar.export")
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
            if let plugins = controls["prefs.plugins"] { ControlToggle(control: plugins, face: "Plugins") }  // T-065
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
                    .frame(width: 220)
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
/// the canvas's vertical scroll. UI-017 (T-122): a secondary click anywhere in the column shows
/// the track list menu (`TrackListMenuOverlay`).
private struct TrackHeaderColumn: View {
    let model: ProjectWindowModel

    var body: some View {
        let rename = model.renameControls.first
        GeometryReader { _ in
            VStack(spacing: 0) {
                Color.clear.frame(height: TimelineGeometry.rulerHeight)
                if model.trackHeaders.isEmpty {
                    Text("No tracks yet")
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
                ForEach(model.trackHeaders) { track in
                    // DW-271 (T-095): "A" and "+ Lane" sit in the header's first line, not over its second.
                    TrackHeaderRow(track: track, automation: AutomationTrackAccessory(model: model.automation, trackID: track.id),
                                   rename: rename?.id == "track.\(track.id).name" ? rename : nil,
                                   cancelRename: { model.cancelRenaming() })
                        .frame(height: ProjectWindowModel.trackHeight - 1)
                    Divider()
                    TakeRowHeaders(model: model.takes, trackID: track.id)  // UI-016 (T-081): take rows come first
                    AutomationLaneHeaders(model: model.automation, trackID: track.id)  // UI-015 (T-075)
                }
            }
            .offset(y: -model.scrollY)
        }
        .clipped()
        .overlay { TrackListMenuOverlay(model: model) }
    }
}

/// UI-017 (T-122): the track list menu over the header column, as an AppKit view so the menu is
/// an `NSMenu` and a two-finger tap works with the system's secondary-click setting. It takes
/// only secondary clicks (right-click, two-finger tap, ⌃-click); every other event passes through
/// to the headers under it.
private struct TrackListMenuOverlay: NSViewRepresentable {
    let model: ProjectWindowModel

    func makeNSView(context: Context) -> TrackListMenuView { TrackListMenuView(model: model) }
    func updateNSView(_ view: TrackListMenuView, context: Context) { view.model = model }
}

/// UI-017: see `TrackListMenuOverlay`. Its y is the canvas's (the column starts with the ruler's
/// height), so `ProjectWindowModel.trackListTarget(atY:)` finds the header under the click.
final class TrackListMenuView: NSView {
    var model: ProjectWindowModel

    init(model: ProjectWindowModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A secondary click: right button (a two-finger tap arrives as one), or ⌃ with the left.
    static func isSecondaryClick(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown, .rightMouseUp: true
        case .leftMouseDown, .leftMouseUp: event.modifierFlags.contains(.control)
        default: false
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, Self.isSecondaryClick(event) else { return nil }
        return super.hitTest(point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let trackID = model.trackListTarget(atY: convert(event.locationInWindow, from: nil).y)
        model.trackListMenuOpened(on: trackID)
        return TimelineCanvasView.trackListMenu(model, for: trackID)
    }

    /// ⌃-click, should AppKit hand it over as a plain press.
    override func mouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// UI-017 (T-122): the header's name while Rename… edits it: an AppKit field that takes focus when
/// it appears. Return or leaving the field commits (`rename`'s commit, one `RenameTrack`), Escape
/// cancels. The field carries the control's id (`track.<id>.name`, UI-052).
private struct TrackNameEditor: NSViewRepresentable {
    let control: UIControl
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(control: control, cancel: cancel) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingTextField(string: control.text ?? "")
        field.font = .preferredFont(forTextStyle: .headline)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(control.id)
        field.setAccessibilityLabel(control.label)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.control = control
        context.coordinator.cancel = cancel
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var control: UIControl
        var cancel: () -> Void
        private var done = false

        init(control: UIControl, cancel: @escaping () -> Void) {
            self.control = control
            self.cancel = cancel
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            done = true
            cancel()
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !done, let field = notification.object as? NSTextField else { return }
            done = true
            _ = control.commitText?(field.stringValue)
        }
    }
}

/// A text field that becomes first responder (all text selected) once it is in a window.
private final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
        }
    }
}

/// UI-010: the AppKit canvas in SwiftUI. The view model drives it; SwiftUI only places it.
private struct TimelineCanvas: NSViewRepresentable {
    let model: ArrangeModel

    func makeNSView(context: Context) -> TimelineCanvasView { TimelineCanvasView(model: model) }
    func updateNSView(_ view: TimelineCanvasView, context: Context) {}
}

/// A track header: its name, kind, mute and solo, then arm (REC-001), the input pair an audio
/// track records (DW-200: the device's pairs) and monitoring (REC-020). Every control is a view-model
/// control (UI-052); the menus hold toggles, like the snap menu.
private struct TrackHeaderRow: View {
    let track: TrackHeaderModel
    /// UI-015: the automation "A" toggle and "+ Lane" menu, in the first line (DW-271).
    let automation: AutomationTrackAccessory
    /// UI-017 (T-122): the name field's control while Rename… edits this header.
    var rename: UIControl? = nil
    var cancelRename: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let rename {
                    TrackNameEditor(control: rename, cancel: cancelRename)
                        .frame(minWidth: 60)
                } else {
                    ControlButton(control: track.selectControl, face: track.name)
                        .buttonStyle(.plain)
                        .font(.headline)
                        .lineLimit(1)
                }
                // DW-271 (T-095): the kind as an icon, so the name keeps room beside A, +, M and S.
                Image(systemName: track.kind == .midi ? "pianokeys" : "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(track.kind == .midi ? "MIDI track" : "Audio track")
                    .accessibilityLabel(track.kind == .midi ? "MIDI" : "Audio")
                    .accessibilityIdentifier("track.\(track.id).kind")
                Spacer(minLength: 2)
                // DW-271: small, like the second line's, so A, +, M and S fit beside the name.
                HStack(spacing: 3) {
                    automation
                    ControlToggle(control: track.muteControl, face: "M").fixedSize()
                    ControlToggle(control: track.soloControl, face: "S").fixedSize()
                }
                .controlSize(.small)
                .fixedSize()
            }
            HStack(spacing: 4) {
                // Hollow when disarmed: the red tint alone reads almost the same on and off.
                ControlToggle(control: track.armControl, face: track.armed ? "●" : "○")
                    .tint(.red)
                    .fixedSize()
                if !track.inputControls.isEmpty {
                    Menu(TrackHeaderModel.inputTitle(track.inputPair)) {
                        ForEach(track.inputControls) { control in
                            ControlToggle(control: control, face: control.label.replacingOccurrences(of: "Input ", with: ""))
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("track.\(track.id).input.menu")
                }
                if let midi = track.midiInputMenu {
                    // DW-271 (T-095): the picker gives way (its title truncates) so "Mon: …" stays
                    // inside the default header width.
                    TrackMidiInputPicker(menu: midi)  // T-093 (DW-216)
                        .frame(minWidth: 40)
                        .layoutPriority(-1)
                        .accessibilityIdentifier("track.\(track.id).midiInput.menu")
                }
                Menu("Mon: \(TrackHeaderModel.monitoringTitle(track.monitoring))") {
                    ForEach(track.monitorControls) { control in
                        ControlToggle(control: control, face: control.label.replacingOccurrences(of: "Monitoring ", with: ""))
                    }
                    // REC-021 (T-054): read-only, what software monitoring adds.
                    if let latency = track.monitoringLatency {
                        Divider()
                        Text(latency.title)
                            .accessibilityIdentifier("track.\(track.id).monitor.latency")
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("track.\(track.id).monitor.menu")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
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
