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

    init(id: Int, store: ProjectStore, toasts: ToastCenter = ToastCenter()) {
        self.id = id
        self.store = store
        self.toasts = toasts
    }

    var project: Project { store.project }
    var engine: (any EngineProtocol)? { store.engineSync?.engine }
    var title: String { store.project.name + (store.isDirty ? " — Edited" : "") }

    /// The app's control socket swapped the document (`project.new`/`project.open` through the
    /// Dispatcher); the window now shows `store`. Selection and transport belong to the old one.
    func replace(store: ProjectStore) {
        guard store !== self.store else { return }
        self.store = store
        selectedTracks = []
        selectedClips = []
        transport = TransportState()
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

    /// UI-052: every control this window shows, in display order.
    var controls: [UIControl] {
        var controls: [UIControl] = [
            .button("transport.play", "Play", enabled: engine != nil && !transport.playing) { [weak self] in self?.play() },
            .button("transport.stop", "Stop", enabled: engine != nil) { [weak self] in self?.stop() },
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
        engine?.play()
        pollTransport()
    }

    func stop() {
        engine?.stop()
        pollTransport()
    }

    func pollTransport() {
        transport = engine?.transport() ?? TransportState()
    }
}
