import DAWModel
import Foundation
import Observation

/// The panes of the bottom area (12 *Layout*).
enum BottomPane: String, CaseIterable, Codable, Sendable {
    case mixer, pianoRoll, deviceChain, compEditor

    var title: String {
        switch self {
        case .mixer: "Mixer"
        case .pianoRoll: "Piano Roll"
        case .deviceChain: "Device Chain"
        case .compEditor: "Comp Editor"
        }
    }
}

/// UI-003: a track header row, derived from the project. Mute and solo go through `SetParam`
/// (MODEL-005), so they are undoable and reach the engine through engine sync, never directly.
struct TrackHeaderModel: Identifiable {
    let id: NodeIDValue
    let name: String
    let kind: Track.Kind
    let mute: Bool
    let solo: Bool
    let isSelected: Bool
    /// `track.<id>.mute`, `track.<id>.solo`, `track.<id>.select` (UI-052).
    let muteControl: UIControl
    let soloControl: UIControl
    let selectControl: UIControl

    var controls: [UIControl] { [selectControl, muteControl, soloControl] }
}

/// UI-003: everything one project window shows, derived from its `ProjectStore` and engine. Views
/// read it and call its controls; it is testable without a window (`EmberStudioShellTests`).
@Observable
@MainActor
final class ProjectWindowModel: Identifiable {
    let id: Int
    private(set) var store: ProjectStore
    let toasts: ToastCenter

    // Panes (12 Layout)
    var showsBrowser = true
    var showsInspector = true
    var bottomPane: BottomPane? = .mixer

    // Selection
    var selectedTracks: Set<NodeIDValue> = []
    var selectedClips: Set<ModelID> = []

    // Zoom and scroll of the arrange area
    static let zoomRange = 4.0...512.0
    static let zoomStep = 1.25
    static let trackHeight = 64.0
    var pixelsPerBeat = 32.0
    var scrollX = 0.0
    var scrollY = 0.0
    /// The arrange area's height, from the view (or a test).
    var viewportHeight = 480.0

    /// The engine's transport as of the last poll.
    private(set) var transport = TransportState()
    /// The engine's telemetry as of the last poll (the toolbar's CPU and xrun readout).
    private(set) var telemetry = EngineTelemetry()

    /// Play/record states asked of the engine that its transport doesn't show yet: a realtime
    /// engine applies transport commands at its next block (TIME-004), so reading it right after
    /// would undo a quick second press (Space twice). Cleared when a poll shows them, or after
    /// `pendingPollLimit` polls (an engine that never applies them, e.g. no running device).
    private(set) var requestedPlaying: Bool?
    private(set) var requestedRecording: Bool?
    @ObservationIgnored private var pendingPolls = 0
    /// How a poll reads the engine's transport (tests stand in for a realtime engine's lag).
    @ObservationIgnored var readTransport: @MainActor (any EngineProtocol) -> TransportState = { $0.transport() }
    static let pendingPollLimit = 30

    /// Playing as far as the controls are concerned: what was last asked for, else the engine's state.
    var isPlaying: Bool { requestedPlaying ?? transport.playing }
    var isRecording: Bool { requestedRecording ?? transport.recording }

    /// UI-010..014: the arrange canvas (snap, gestures, waveforms, playhead).
    let arrange = ArrangeModel()

    init(id: Int, store: ProjectStore, toasts: ToastCenter = ToastCenter()) {
        self.id = id
        self.store = store
        self.toasts = toasts
        arrange.window = self
    }

    var project: Project { store.project }
    var engine: (any EngineProtocol)? { store.engineSync?.engine }
    var title: String { store.project.name + (store.isDirty ? " — Edited" : "") }

    /// The app's control socket swapped the document (`project.new`/`project.open` through the
    /// Dispatcher); the window now shows `store`. Selection and transport belong to the old one.
    func replace(store: ProjectStore) {
        guard store !== self.store else { return }
        arrange.finishDrag()
        self.store = store
        arrange.peaks.invalidate(nil)
        selectedTracks = []
        selectedClips = []
        transport = TransportState()
        telemetry = EngineTelemetry()
        requestedPlaying = nil
        requestedRecording = nil
        scrollY = 0
    }

    // MARK: Derived

    var trackHeaders: [TrackHeaderModel] {
        store.project.tracks.map { track in
            TrackHeaderModel(
                id: track.id, name: track.name, kind: track.kind, mute: track.strip.mute, solo: track.strip.solo,
                isSelected: selectedTracks.contains(track.id),
                muteControl: .toggle("track.\(track.id).mute", "Mute \(track.name)", isOn: track.strip.mute) { [weak self] in
                    self?.setStrip(track.id, .mute, on: !track.strip.mute)
                },
                soloControl: .toggle("track.\(track.id).solo", "Solo \(track.name)", isOn: track.strip.solo) { [weak self] in
                    self?.setStrip(track.id, .solo, on: !track.strip.solo)
                },
                selectControl: .button("track.\(track.id).select", "Select \(track.name)") { [weak self] in
                    self?.selectedTracks = [track.id]
                })
        }
    }

    /// Tracks at least partly inside the arrange viewport (rows of `trackHeight`).
    var visibleTracks: [NodeIDValue] {
        let top = scrollY
        let bottom = scrollY + viewportHeight
        return store.project.tracks.enumerated().compactMap { index, track in
            let y = Double(index) * Self.trackHeight
            return y + Self.trackHeight > top && y < bottom ? track.id : nil
        }
    }

    // MARK: Toolbar (12 Layout)

    /// The loop region the transport follows (DW-123), if looping is on.
    var loopEnabled: Bool { store.project.loop?.isEnabled == true }

    /// The playhead in bars.beats.ticks at the signature in force there (TIME-002).
    var positionBBT: String {
        let bbt = store.project.tempoMap.tickToBBT(Tick(max(transport.tick.raw, 0)))
        return String(format: "%d.%d.%03d", bbt.bar, bbt.beat, bbt.tick)
    }

    /// The playhead as minutes:seconds.milliseconds, through the tempo map.
    var positionTime: String {
        let map = store.project.tempoMap
        let seconds = Double(map.tickToSample(Tick(max(transport.tick.raw, 0)))) / map.sampleRate
        let ms = Int((seconds * 1000).rounded(.down))
        return String(format: "%d:%02d.%03d", ms / 60_000, ms / 1000 % 60, ms % 1000)
    }

    /// The tempo at the playhead, in BPM.
    var tempo: Double { store.project.tempoMap.bpmAt(Tick(max(transport.tick.raw, 0))) }

    /// The time signature in force at the playhead, "4/4".
    var signature: String {
        let tick = max(transport.tick.raw, 0)
        let sig = store.project.tempoMap.timeSignatures.last { $0.tick.raw <= tick } ?? store.project.tempoMap.timeSignatures.first
        return sig.map { "\($0.numerator)/\($0.denominator)" } ?? "4/4"
    }

    /// UI-052: every control this window shows, in display order.
    var controls: [UIControl] {
        let hasEngine = engine != nil
        var controls: [UIControl] = [
            .button("transport.play", "Play", enabled: hasEngine && !isPlaying) { [weak self] in self?.play() },
            .button("transport.stop", "Stop", enabled: hasEngine) { [weak self] in self?.stop() },
            // UI-002: Space.
            .button("transport.playStop", isPlaying ? "Stop" : "Play", enabled: hasEngine) { [weak self] in
                self?.playStop()
            },
            // UI-002: R. Arms the transport's record state only; recording itself is M5 (09).
            .toggle("transport.record", "Record", isOn: isRecording, enabled: hasEngine) { [weak self] in
                self?.toggleRecord()
            },
            // UI-002: L. The project's loop (SetLoop), which engine sync gives the transport (DW-123).
            .toggle("transport.loop", "Loop", isOn: loopEnabled) { [weak self] in self?.toggleLoop() },
            // T-026: the metronome toggle (`transport.metronome`, SetMetronome) goes here.
            .button("edit.undo", store.undoLabel.map { "Undo \($0)" } ?? "Undo", enabled: store.canUndo) { [weak self] in
                self?.store.undo()
            },
            .button("edit.redo", store.redoLabel.map { "Redo \($0)" } ?? "Redo", enabled: store.canRedo) { [weak self] in
                self?.store.redo()
            },
            .button("zoom.in", "Zoom In", enabled: pixelsPerBeat < Self.zoomRange.upperBound) { [weak self] in self?.zoom(by: Self.zoomStep) },
            .button("zoom.out", "Zoom Out", enabled: pixelsPerBeat > Self.zoomRange.lowerBound) { [weak self] in
                self?.zoom(by: 1 / Self.zoomStep)
            },
            // UI-002: ⌘T, ⇧⌘T.
            .button("track.add.audio", "New Audio Track") { [weak self] in self?.addTrack(.audio) },
            .button("track.add.midi", "New MIDI Track") { [weak self] in self?.addTrack(.midi) },
            .toggle("pane.browser", "Browser", isOn: showsBrowser) { [weak self] in self?.showsBrowser.toggle() },
            .toggle("pane.inspector", "Inspector", isOn: showsInspector) { [weak self] in self?.showsInspector.toggle() },
        ]
        controls += BottomPane.allCases.map { pane in
            .toggle("pane.bottom.\(pane.rawValue)", pane.title, isOn: bottomPane == pane) { [weak self] in
                guard let self else { return }
                bottomPane = bottomPane == pane ? nil : pane
            }
        }
        controls += trackHeaders.flatMap(\.controls)
        controls += arrange.controls
        controls += toasts.controls
        return controls
    }

    // MARK: Actions

    /// Performs `command` as one undo entry; a refusal becomes an error toast.
    func perform(_ command: any Command) {
        do {
            try store.perform(command)
        } catch {
            toasts.post(.error, .error, title: "\(command.label) failed", message: error.description)
        }
    }

    func setStrip(_ channel: NodeIDValue, _ param: ParamTarget.StripParam, on: Bool) {
        perform(SetParam(target: .strip(channel: channel, param: param), value: on ? 1 : 0))
    }

    func zoom(by factor: Double) {
        pixelsPerBeat = min(max(pixelsPerBeat * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    func play() {
        guard let engine else { return }
        engine.play()
        request(playing: true)
    }

    func stop() {
        guard let engine else { return }
        engine.stop()
        request(playing: false)
    }

    /// Space: stops if playing (or asked to play), else plays.
    func playStop() {
        if isPlaying { stop() } else { play() }
    }

    /// R: arms or disarms the transport's record state.
    func toggleRecord() {
        guard let engine else { return }
        let recording = !isRecording
        engine.setRecording(recording)
        request(recording: recording)
    }

    private func request(playing: Bool? = nil, recording: Bool? = nil) {
        if let playing { requestedPlaying = playing }
        if let recording { requestedRecording = recording }
        pendingPolls = 0
        pollTransport()
    }

    /// Bars a new loop spans when the project has none.
    static let defaultLoopBars = 4

    /// Turns the project's loop on or off (one undo entry, `SetLoop`). With no loop yet, it makes
    /// one: around the selected clips if any, else `defaultLoopBars` bars from the playhead's bar.
    func toggleLoop() {
        let project = store.project
        if let loop = project.loop {
            perform(SetLoop(loop: LoopRange(start: loop.start, end: loop.end, isEnabled: !loop.isEnabled)))
            return
        }
        let clips = project.tracks.flatMap(\.clips).filter { selectedClips.contains($0.id) }
        if let start = clips.map(\.start.raw).min(), let end = clips.map({ $0.start.raw + $0.length.raw }).max(), end > start {
            perform(SetLoop(start: Tick(start), end: Tick(end)))
        } else {
            let map = project.tempoMap
            let bar = map.tickToBBT(Tick(max(transport.tick.raw, 0))).bar
            perform(SetLoop(start: map.bbtToTick(BBT(bar: bar, beat: 1, tick: 0)),
                            end: map.bbtToTick(BBT(bar: bar + Self.defaultLoopBars, beat: 1, tick: 0))))
        }
    }

    /// ⌘T / ⇧⌘T: appends an empty track ("Audio 2", "MIDI 1", …) and selects it.
    func addTrack(_ kind: Track.Kind) {
        let prefix = kind == .midi ? "MIDI" : "Audio"
        let count = store.project.tracks.filter { $0.kind == kind }.count
        let before = Set(store.project.tracks.map(\.id))
        perform(AddTrack(name: "\(prefix) \(count + 1)", kind: kind))
        if let added = store.project.tracks.first(where: { !before.contains($0.id) }) { selectedTracks = [added.id] }
    }

    // MARK: Keyboard (UI-002)

    /// Runs the control bound to `chord`. True if it ran; false for an unbound chord, a disabled
    /// control or (when `isRepeat`) a binding that doesn't repeat, so the event goes on its way.
    @discardableResult
    func handleKey(_ chord: KeyChord, isRepeat: Bool = false) -> Bool {
        guard let binding = KeyBindings.binding(for: chord), !isRepeat || binding.repeats,
              let control = controls.first(where: { $0.id == binding.controlID }), control.isEnabled
        else { return false }
        control.action()
        return true
    }

    /// UI-004 toasts and UI-011 waveforms (newly loaded audio) from the engine's events.
    func engineEventsArrived(_ events: [EngineEvent]) {
        toasts.handle(events)
        arrange.engineEventsArrived(events)
    }

    func pollTransport() {
        // Only a change is assigned, so a stopped transport doesn't invalidate the views 30 times a second.
        let transport = engine.map(readTransport) ?? TransportState()
        if transport != self.transport { self.transport = transport }
        let telemetry = engine?.telemetry() ?? EngineTelemetry()
        if telemetry != self.telemetry { self.telemetry = telemetry }
        if requestedPlaying == transport.playing { requestedPlaying = nil }
        if requestedRecording == transport.recording { requestedRecording = nil }
        if requestedPlaying != nil || requestedRecording != nil {
            pendingPolls += 1
            if pendingPolls > Self.pendingPollLimit {
                requestedPlaying = nil
                requestedRecording = nil
            }
        }
    }
}
