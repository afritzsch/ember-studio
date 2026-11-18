import AppKit
import DAWModel
import Foundation
import Observation

/// PLUG-017 (T-063), UI-032's "Open Editor": a window's open plugin editors, one floating panel per
/// device slot. The editor's view is the engine's (`EngineProtocol.createPluginView`, an NSView the
/// engine owns: an AU's view controller or CoreAudioKit's generic view, a VST3 IPlugView); this
/// model decides when one is open and puts it in a panel (`PluginEditorPanels`).
///
/// An editor closes when its panel is closed, its slot leaves the project (RemoveDevice,
/// RemoveInstrument, an undo), its plugin crashes (`pluginCrashed`), safe mode is on (PLUG-021),
/// the window's project is replaced or the window closes. When the window's engine is handed over
/// (DW-156, live ↔ offline) the editors close with the old engine and reopen on the new one. An
/// editor whose plugin instance was replaced (a rate change) reopens on the new instance.
@Observable
@MainActor
final class PluginEditorModel {
    @ObservationIgnored weak var window: ProjectWindowModel?

    /// What `ui.state` reports of an open editor (the engine's `pluginViewJSON`).
    struct Editor: Equatable, Sendable {
        var slot: NodeIDValue
        var title: String
        /// "au", "auGeneric" (CoreAudioKit's generic view) or "vst3".
        var kind: String
        var width: Double
        var height: Double
        /// An AU's view controller has arrived (AU editors start at a placeholder size).
        var ready: Bool
        var resizable: Bool
    }

    /// Open editors by slot.
    private(set) var editors: [NodeIDValue: Editor] = [:]

    /// Where panels go. Tests may replace it; nil opens editors without panels.
    @ObservationIgnored var panels: PluginEditorPanels? = PluginEditorPanels()
    /// The editor view for a slot. Defaults to the window's engine; tests can stand in.
    @ObservationIgnored var makeView: (@MainActor (NodeIDValue) -> NSView?)?
    /// Slots to reopen once a handed-over engine is attached (DW-156).
    @ObservationIgnored private var reopenAfterHandover: [NodeIDValue] = []

    init() {
        panels?.onUserClose = { [weak self] slot in self?.close(slot) }
    }

    var openSlots: [NodeIDValue] { editors.keys.sorted() }
    func isOpen(_ slot: NodeIDValue) -> Bool { editors[slot] != nil }

    /// A slot of the window's project that hosts an AU or VST3 plugin, with an engine and safe mode off
    /// (or, DW-266, the slot enabled one by one in safe mode: its plugin is loaded).
    func canOpen(_ slot: NodeIDValue) -> Bool {
        guard let window, window.engine != nil || makeView != nil,
              !window.store.isSafeMode || window.store.safeModeEnabledSlots.contains(slot)
        else { return false }
        return Self.pluginSlot(slot, in: window.project) != nil
    }

    func toggle(_ slot: NodeIDValue) {
        if isOpen(slot) { close(slot) } else { open(slot) }
    }

    /// Opens (or brings forward) the slot's editor. A plugin without an editor, or one that isn't
    /// loaded, gets an error toast.
    func open(_ slot: NodeIDValue) {
        guard let window, canOpen(slot), let device = Self.pluginSlot(slot, in: window.project) else { return }
        if isOpen(slot) {
            panels?.bringForward(slot)
            return
        }
        guard let view = editorView(slot) else {
            window.toasts.post(.error, .error, title: "No editor for \(MixerModel.insertName(device.kind))",
                               message: "The plugin isn't loaded, or it has no editor of its own.")
            return
        }
        var editor = readEditor(slot) ?? Editor(slot: slot, title: MixerModel.insertName(device.kind), kind: "",
                                                width: view.frame.width, height: view.frame.height, ready: true, resizable: false)
        if editor.title.isEmpty { editor.title = MixerModel.insertName(device.kind) }
        editors[slot] = editor
        panels?.show(view, slot: slot, title: "\(editor.title) — \(window.project.name)", resizable: editor.resizable)
    }

    func close(_ slot: NodeIDValue) {
        guard editors.removeValue(forKey: slot) != nil else { return }
        panels?.hide(slot)
        window?.engine?.destroyPluginView(slot: slot)
        // DW-204: a gesture the editor left open (closed mid-drag) ends with it.
        window?.store.engineSync?.pluginEdits.endGestures(slot: slot)
    }

    func closeAll() {
        for slot in openSlots { close(slot) }
    }

    /// DW-156: the window's engine is about to go; its editors go with it and come back on the next.
    func engineWillChange() {
        reopenAfterHandover = openSlots
        closeAll()
    }

    func engineDidChange() {
        let slots = reopenAfterHandover
        reopenAfterHandover = []
        for slot in slots where canOpen(slot) { open(slot) }
    }

    /// `pluginCrashed`: that plugin's editor closes.
    func engineEventsArrived(_ events: [EngineEvent]) {
        for event in events where event.kind == .pluginCrashed && isOpen(event.subject) { close(event.subject) }
    }

    /// At the window's poll: editors of slots that are gone (or in safe mode) close, sizes and AU
    /// readiness follow the engine, and an editor showing a replaced instance reopens.
    func refresh() {
        guard !editors.isEmpty, let window else { return }
        for slot in openSlots {
            guard canOpen(slot) else {
                close(slot)
                continue
            }
            guard let json = window.engine?.pluginViewJSON(slot: slot), !json.isEmpty else { continue }
            guard let state = Self.parse(json, slot: slot) else {
                close(slot)  // the engine closed it
                continue
            }
            if state.stale {
                close(slot)
                open(slot)
                continue
            }
            if editors[slot] != state.editor {
                let resizableChanged = editors[slot]?.resizable != state.editor.resizable
                editors[slot] = state.editor
                if resizableChanged { panels?.setResizable(state.editor.resizable, slot: slot) }
            }
        }
    }

    // MARK: Private

    private func editorView(_ slot: NodeIDValue) -> NSView? {
        if let makeView { return makeView(slot) }
        guard let pointer = window?.engine?.createPluginView(slot: slot) else { return nil }
        return Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
    }

    private func readEditor(_ slot: NodeIDValue) -> Editor? {
        guard let json = window?.engine?.pluginViewJSON(slot: slot) else { return nil }
        return Self.parse(json, slot: slot)?.editor
    }

    static func pluginSlot(_ slot: NodeIDValue, in project: Project) -> DeviceSlot? {
        var found: DeviceSlot?
        project.forEachDeviceSlot { device, _ in
            if device.id == slot, device.isPlugin { found = device }
        }
        return found
    }

    /// `{"slot", "open": true, "ready", "kind", "title", "width", "height", "resizable", "stale"}`;
    /// nil when it says the editor isn't open.
    static func parse(_ json: String, slot: NodeIDValue) -> (editor: Editor, stale: Bool)? {
        struct ViewState: Decodable {
            var open: Bool
            var ready: Bool?
            var kind: String?
            var title: String?
            var width: Double?
            var height: Double?
            var resizable: Bool?
            var stale: Bool?
        }
        guard let state = try? JSONDecoder().decode(ViewState.self, from: Data(json.utf8)), state.open else { return nil }
        return (Editor(slot: slot, title: state.title ?? "", kind: state.kind ?? "", width: state.width ?? 0,
                       height: state.height ?? 0, ready: state.ready ?? false, resizable: state.resizable ?? false),
                state.stale ?? false)
    }
}
