import DAWModel
import Foundation
import Observation

/// A continuous device param control (`DeviceParamSliderView`). Drags on it coalesce into one undo
/// step and feed the automation recorder (DW-254), like the mixer's faders.
struct DeviceParamKey: Hashable, Sendable {
    var slot: NodeIDValue
    var index: Int

    var target: ParamTarget { .device(slot: slot, index: index) }
}

/// UI-032 (T-065): the Device Chain tab, one channel's devices (a MIDI track's instrument, then the
/// inserts in order) as cards with generic controls:
///   - **Generic UI** from `ParamInfo` for built-ins (06, with DW-196's steps: a switch is a toggle,
///     a labelled or stepped param a menu, anything else a slider) and, from the engine's
///     `pluginInfoJSON`, for hosted plugins (shown on request, and on its own for a plugin without an
///     editor of its own, DW-264).
///   - **Open Editor** for AU/VST3 (PLUG-017, through the window's `PluginEditorModel`).
///   - **Bypass** (`SetDeviceBypass`). In safe mode (PLUG-021) AU/VST3 slots show as bypassed by safe
///     mode and can't be toggled (DW-226); the document's own bypass is kept.
///   - **Reorder** by dragging a card onto another (`MoveDevice`), or `moveUp`/`moveDown`; **remove**
///     (`RemoveDevice`, `RemoveInstrument`); **add** from the device picker (`InsertDevice`).
///   - **Sidechain source** (`SetSidechain`) for the compressor and plugins: any track or bus; a
///     source that would close a cycle is refused by the model (MODEL-030) with a toast.
/// Everything is derived from the project on demand, like the mixer. Param drags are one undo entry
/// each and go through the automation recorder (`controlMoved`/`controlReleased`, DW-254).
@Observable
@MainActor
final class DeviceChainModel {
    @ObservationIgnored weak var window: ProjectWindowModel?

    /// The channel picked in the tab; nil follows the track selection.
    var pickedChannel: NodeIDValue?
    /// Plugins whose generic controls show (built-ins always show theirs).
    var genericShown: Set<NodeIDValue> = []
    /// Plugins the engine had no editor for (DW-264): their generic controls show instead.
    private(set) var noEditor: Set<NodeIDValue> = []
    /// The drag in progress (`ui.state`).
    private(set) var activeDrag: DeviceParamKey?
    @ObservationIgnored private var dragStore: ProjectStore?

    /// Bumped when a plugin's info (params, values) read from the engine changed.
    private(set) var pluginInfoRevision = 0
    @ObservationIgnored private var pluginInfos: [NodeIDValue: PluginInfo] = [:]
    @ObservationIgnored private var lastInfoRefresh = Date.distantPast
    @ObservationIgnored var now: () -> Date = { Date() }
    /// Where plugin info comes from: the window's engine (`pluginInfoJSON`), or a test's stand-in.
    @ObservationIgnored var readPluginInfo: (@MainActor (NodeIDValue) -> String)?
    /// How often an open tab re-reads its plugins' info (their own values move under their editors).
    static let infoRefreshInterval: TimeInterval = 0.5

    init() {}

    var isOpen: Bool { window?.bottomPane == .deviceChain }
    private var project: Project { window?.project ?? Project() }

    // MARK: Channel

    /// The channel shown: the picked one while it exists, else the first selected track, else the
    /// first track, else the master.
    var channelID: NodeIDValue {
        let project = project
        if let pickedChannel, project.inserts(of: pickedChannel) != nil { return pickedChannel }
        if let selected = window?.selectedTracks.sorted().first(where: { project.track($0) != nil }) { return selected }
        return project.tracks.first?.id ?? project.master.id
    }

    /// Every channel with a chain: tracks, buses, the master.
    var channelChoices: [(id: NodeIDValue, name: String)] {
        let project = project
        return project.tracks.map { ($0.id, $0.name) } + project.buses.map { ($0.id, $0.name) } + [(project.master.id, "Master")]
    }

    func channelName(_ id: NodeIDValue) -> String {
        channelChoices.first { $0.id == id }?.name ?? "\(id)"
    }

    /// Shows `channel`'s chain (and the tab), selecting a track's header too.
    func show(channel: NodeIDValue) {
        guard let window else { return }
        pickedChannel = channel
        if project.track(channel) != nil { window.selectedTracks = [channel] }
        window.bottomPane = .deviceChain
    }

    // MARK: Devices

    /// The shown channel's devices: a MIDI track's instrument first, then its inserts in order.
    var devices: [DeviceCardModel] {
        _ = pluginInfoRevision
        let project = project
        let channel = channelID
        var out: [DeviceCardModel] = []
        if let instrument = project.track(channel)?.instrument {
            out.append(card(instrument, channel: channel, position: nil, count: 0))
        }
        let inserts = project.inserts(of: channel) ?? []
        for (i, slot) in inserts.enumerated() {
            out.append(card(slot, channel: channel, position: i, count: inserts.count))
        }
        return out
    }

    /// The device picker's list (`deviceChain.add.<key>`).
    var choices: [DeviceChoice] {
        DeviceChoice.all(plugins: window?.pluginPanel.manager.usable ?? [])
    }

    private func card(_ slot: DeviceSlot, channel: NodeIDValue, position: Int?, count: Int) -> DeviceCardModel {
        let safeMode = window?.store.isSafeMode ?? false
        let info = slot.isPlugin ? pluginInfo(slot.id) : nil
        let forced = slot.isPlugin && safeMode
        var card = DeviceCardModel(
            id: slot.id, name: MixerModel.insertName(slot.kind), format: Self.format(slot.kind), isInstrument: position == nil,
            position: position, bypass: slot.bypass, safeModeBypassed: forced, isPlugin: slot.isPlugin,
            loaded: info?.loaded, loadError: info?.error,
            editorOpen: window?.pluginEditors.isOpen(slot.id) ?? false, noEditor: noEditor.contains(slot.id),
            showsParams: !slot.isPlugin || genericShown.contains(slot.id) || noEditor.contains(slot.id),
            acceptsSidechain: Self.acceptsSidechain(slot, info: info),
            sidechain: slot.sidechainSource.map { DeviceCardModel.Sidechain(source: $0.source, name: channelName($0.source)) },
            params: params(slot, info: info))
        card.controls = controls(card, slot: slot, channel: channel, count: count)
        return card
    }

    static func format(_ kind: DeviceSlot.Kind) -> String {
        switch kind {
        case .builtin: "builtin"
        case .au: "au"
        case .vst3: "vst3"
        }
    }

    /// MIX-008: the compressor has a sidechain input; plugins have one if the engine says so (a
    /// plugin not loaded yet is offered the picker; the source waits for it).
    static func acceptsSidechain(_ slot: DeviceSlot, info: PluginInfo?) -> Bool {
        switch slot.kind {
        case .builtin(let node): node == .compressor
        case .au, .vst3: info?.sidechain ?? true
        }
    }

    // MARK: Params

    /// The engine's ParamInfo (DW-236), else the built-in catalog (test engines publish none).
    private var catalog: ParamCatalog {
        if let catalog = window?.store.engineSync?.catalog, !catalog.infos.isEmpty { return catalog }
        return .builtin
    }

    /// The generic controls' rows: a built-in's ParamInfo, a plugin's `pluginInfoJSON` params.
    func params(_ slot: DeviceSlot, info: PluginInfo?) -> [DeviceParamModel] {
        let rows: [ParamDescriptor]
        var pluginValues: [Int: Float] = [:]
        switch slot.kind {
        case .builtin(let kind):
            rows = (catalog.infos[kind] ?? [:]).values.sorted { $0.index < $1.index }
        case .au, .vst3:
            guard let info else { return [] }
            rows = info.params.map { p in
                ParamDescriptor(index: p.index, id: p.id, name: p.name, min: p.min, max: p.max, default: p.min,
                                unit: p.unit, automatable: true)
            }
            for p in info.params { pluginValues[p.index] = p.value }
        }
        let automation = window?.automation
        return rows.map { row in
            let stored = slot.params.first { $0.index == row.index }?.value
            let own = stored ?? pluginValues[row.index] ?? row.default
            let target = ParamTarget.device(slot: slot.id, index: row.index)
            let value = automation?.displayed(target, own) ?? own
            let automated = window?.project.automationLane(for: target).map { $0.lane.mode != .off } ?? false
            return DeviceParamModel(slot: slot.id, row: row, value: value, isSet: stored != nil, automated: automated)
        }
    }

    /// A plugin's info from the engine (cached; re-read at the window's poll while the tab shows).
    func pluginInfo(_ slot: NodeIDValue) -> PluginInfo? {
        if let cached = pluginInfos[slot] { return cached }
        guard let json = pluginInfoJSON(slot), let info = PluginInfo.parse(json) else { return nil }
        pluginInfos[slot] = info
        return info
    }

    /// At the window's poll: while the tab shows, its plugins' info is re-read every
    /// `infoRefreshInterval` (their own values change under their editors, a load finishes).
    func refresh() {
        guard isOpen, window != nil else { return }
        let time = now()
        guard time.timeIntervalSince(lastInfoRefresh) >= Self.infoRefreshInterval else { return }
        lastInfoRefresh = time
        var slots: [NodeIDValue] = []
        if let instrument = project.track(channelID)?.instrument, instrument.isPlugin { slots.append(instrument.id) }
        slots += (project.inserts(of: channelID) ?? []).filter(\.isPlugin).map(\.id)
        var changed = false
        for slot in slots {
            let info = pluginInfoJSON(slot).flatMap(PluginInfo.parse)
            if pluginInfos[slot] != info {
                pluginInfos[slot] = info
                changed = true
            }
        }
        if changed { pluginInfoRevision += 1 }
    }

    private func pluginInfoJSON(_ slot: NodeIDValue) -> String? {
        if let readPluginInfo { return readPluginInfo(slot) }
        return window?.engine?.pluginInfoJSON(slot: slot)
    }

    // MARK: Controls (UI-052)

    /// While the tab shows: the channel picker, the device picker and every card's controls.
    var controls: [UIControl] {
        guard isOpen else { return [] }
        let shown = channelID
        var controls: [UIControl] = channelChoices.map { choice in
            .toggle("deviceChain.channel.\(choice.id)", "Show Devices of \(choice.name)", isOn: choice.id == shown) { [weak self] in
                self?.show(channel: choice.id)
            }
        }
        controls += choices.map { choice in
            .button("deviceChain.add.\(choice.key)", "Add \(choice.name)") { [weak self] in
                self?.insert(choice.kind, on: shown)
            }
        }
        controls += devices.flatMap(\.controls)
        return controls
    }

    private func controls(_ card: DeviceCardModel, slot: DeviceSlot, channel: NodeIDValue, count: Int) -> [UIControl] {
        let id = card.id
        let prefix = "deviceChain.device.\(id)"
        let name = card.name
        var controls: [UIControl] = [
            .toggle("\(prefix).bypass", card.safeModeBypassed ? "\(name) Bypassed by Safe Mode" : "Bypass \(name)",
                    isOn: card.bypass || card.safeModeBypassed, enabled: !card.safeModeBypassed) { [weak self] in
                self?.window?.perform(SetDeviceBypass(slotID: id, bypass: !card.bypass))
            },
            .button("\(prefix).remove", "Remove \(name)") { [weak self] in
                guard let self, let window else { return }
                if card.isInstrument { window.perform(RemoveInstrument(trackID: channel)) } else { window.perform(RemoveDevice(slotID: id)) }
            },
        ]
        if let position = card.position {
            controls.append(.button("\(prefix).moveUp", "Move \(name) Up", enabled: position > 0) { [weak self] in
                self?.window?.perform(MoveDevice(slotID: id, index: position - 1))
            })
            controls.append(.button("\(prefix).moveDown", "Move \(name) Down", enabled: position < count - 1) { [weak self] in
                self?.window?.perform(MoveDevice(slotID: id, index: position + 1))
            })
        }
        if card.isPlugin {
            let editors = window?.pluginEditors
            controls.append(.toggle("\(prefix).editor", "\(name) Editor", isOn: card.editorOpen,
                                    enabled: editors?.canOpen(id) ?? false) { [weak self] in
                self?.toggleEditor(id)
            })
            controls.append(.toggle("\(prefix).generic", "Generic Controls of \(name)", isOn: card.showsParams) { [weak self] in
                self?.toggleGeneric(id, shown: card.showsParams)
            })
        }
        if card.acceptsSidechain {
            let current = card.sidechain?.source
            controls.append(.toggle("\(prefix).sidechain.none", "No Sidechain for \(name)", isOn: current == nil) { [weak self] in
                guard current != nil else { return }
                self?.setSidechain(id, nil)
            })
            for source in sidechainSources(excluding: channel) {
                controls.append(.toggle("\(prefix).sidechain.\(source.id)", "Sidechain \(name) from \(source.name)",
                                        isOn: current == source.id) { [weak self] in
                    guard current != source.id else { return }
                    self?.setSidechain(id, source.id)
                })
            }
        }
        if card.showsParams {
            for param in card.params {
                controls += paramControls(param, prefix: "\(prefix).param.\(param.index)")
            }
        }
        return controls
    }

    /// A continuous param: `.up|down|reset` (one undo entry each, a twentieth of its range); a
    /// switch: a toggle; a stepped or labelled param: `.value.<k>` toggles (the current one on).
    private func paramControls(_ param: DeviceParamModel, prefix: String) -> [UIControl] {
        let key = DeviceParamKey(slot: param.slot, index: param.index)
        let row = param.row
        if row.isSwitch && row.labels == nil {
            let on = row.step(of: param.value) == 1
            return [.toggle(prefix, row.name, isOn: on) { [weak self] in
                self?.setDiscrete(key, row.value(ofStep: on ? 0 : 1))
            }]
        }
        if row.isDiscrete {
            let current = row.step(of: param.value)
            return row.choices.enumerated().map { k, choice in
                .toggle("\(prefix).value.\(k)", "\(row.name) \(choice.label)", isOn: k == current) { [weak self] in
                    guard k != current else { return }
                    self?.setDiscrete(key, choice.value)
                }
            }
        }
        let position = param.position
        return [
            .button("\(prefix).up", "Raise \(row.name)", enabled: position < 1) { [weak self] in
                self?.nudge(key, row: row, from: position, by: Self.nudgeStep)
            },
            .button("\(prefix).down", "Lower \(row.name)", enabled: position > 0) { [weak self] in
                self?.nudge(key, row: row, from: position, by: -Self.nudgeStep)
            },
            .button("\(prefix).reset", "Reset \(row.name)", enabled: param.isSet) { [weak self] in
                self?.reset(key)
            },
        ]
    }

    /// A nudge moves a param by this much of its (mapped) range.
    static let nudgeStep = 0.05

    // MARK: Actions

    func insert(_ kind: DeviceSlot.Kind, on channel: NodeIDValue, at index: Int? = nil) {
        window?.perform(InsertDevice(channel: channel, index: index, device: kind))
    }

    /// Drag-and-drop reorder: `slot` goes where `target` is (MoveDevice, one undo entry).
    func move(_ slot: NodeIDValue, onto target: NodeIDValue) {
        guard slot != target, let from = project.insertLocation(slot), let to = project.insertLocation(target),
              from.channel == to.channel else { return }
        window?.perform(MoveDevice(slotID: slot, index: to.index))
    }

    func toggleEditor(_ slot: NodeIDValue) {
        guard let editors = window?.pluginEditors else { return }
        let wasOpen = editors.isOpen(slot)
        editors.toggle(slot)
        // DW-264: a plugin without an editor (or one that isn't loaded) shows its generic controls.
        if !wasOpen && !editors.isOpen(slot) {
            noEditor.insert(slot)
            genericShown.insert(slot)
        }
    }

    func toggleGeneric(_ slot: NodeIDValue, shown: Bool) {
        if shown {
            genericShown.remove(slot)
            noEditor.remove(slot)
        } else {
            genericShown.insert(slot)
        }
    }

    /// UI-033 / MODEL-030: a source that would close a cycle is refused with the model's message.
    func setSidechain(_ slot: NodeIDValue, _ source: NodeIDValue?) {
        guard let window else { return }
        let command = SetSidechain(slotID: slot, source: source.map { SidechainRef(source: $0) })
        do {
            try window.store.perform(command)
        } catch {
            window.toasts.post(.error, .error, title: "\(command.label) failed", message: error.description)
        }
    }

    /// Tracks and buses other than the channel itself.
    func sidechainSources(excluding channel: NodeIDValue) -> [(id: NodeIDValue, name: String)] {
        let project = project
        return (project.tracks.map { ($0.id, $0.name) } + project.buses.map { ($0.id, $0.name) }).filter { $0.0 != channel }
    }

    /// A switch or menu choice: one undo entry, through the recorder like a one-step drag (DW-254).
    func setDiscrete(_ key: DeviceParamKey, _ value: Float) {
        guard let store = window?.store else { return }
        endDrag()
        store.beginGesture("Set Parameter")
        if window?.automation.controlMoved(key.target, value: value) != true {
            try? store.perform(SetParam(target: key.target, value: value))
        }
        store.endGesture()
        window?.automation.controlReleased(key.target)
    }

    private func nudge(_ key: DeviceParamKey, row: ParamDescriptor, from position: Double, by step: Double) {
        let value = row.mapping.denormalize(Float(min(max(position + step, 0), 1)))
        window?.perform(SetParam(target: key.target, value: value))
    }

    /// A double-click or `.reset`: back to the default (a built-in's ParamInfo default; a plugin's
    /// param becomes "not set", so the plugin keeps its own value). One undo entry.
    func reset(_ key: DeviceParamKey) {
        endDrag()
        guard let slot = project.deviceSlot(key.slot), slot.params.contains(where: { $0.index == key.index }) else { return }
        window?.perform(SetParam(target: key.target, value: slot.isPlugin ? nil : defaultValue(key)))
    }

    private func defaultValue(_ key: DeviceParamKey) -> Float? {
        guard let slot = project.deviceSlot(key.slot), case .builtin(let kind) = slot.kind else { return nil }
        return catalog.info(kind, key.index)?.default
    }

    // MARK: Gestures (MODEL-003, DW-254)

    /// Starts a drag of `key`: every `updateDrag` until `endDrag` is one undo step.
    func beginDrag(_ key: DeviceParamKey) {
        guard let store = window?.store else { return }
        endDrag()
        store.beginGesture("Set Parameter")
        dragStore = store
        activeDrag = key
    }

    /// One step of the drag; `position` is the control's, 0…1 of the param's mapped range.
    func updateDrag(_ key: DeviceParamKey, position: Double) {
        guard activeDrag == key, let store = dragStore, let row = row(key) else { return }
        let value = row.mapping.denormalize(Float(min(max(position, 0), 1)))
        // AUTO-006/007 (DW-254): recording automation takes the movement, as on the mixer's faders.
        if window?.automation.controlMoved(key.target, value: value) == true { return }
        try? store.perform(SetParam(target: key.target, value: value))
    }

    func endDrag() {
        dragStore?.endGesture()
        dragStore = nil
        if let key = activeDrag { window?.automation.controlReleased(key.target) }
        if activeDrag != nil { activeDrag = nil }
    }

    /// The row a key's control maps through (built-in ParamInfo or the plugin's info).
    func row(_ key: DeviceParamKey) -> ParamDescriptor? {
        guard let slot = project.deviceSlot(key.slot) else { return nil }
        return params(slot, info: slot.isPlugin ? pluginInfo(slot.id) : nil).first { $0.index == key.index }?.row
    }

    /// The window's project changed under it.
    func documentReplaced() {
        endDrag()
        pickedChannel = nil
        genericShown = []
        noEditor = []
        pluginInfos = [:]
        pluginInfoRevision += 1
    }

    /// DW-156: another engine; plugin info is read again from it.
    func engineChanged() {
        endDrag()
        pluginInfos = [:]
        pluginInfoRevision += 1
    }
}

extension Project {
    /// The instrument or insert slot `id`, anywhere in the project.
    func deviceSlot(_ id: NodeIDValue) -> DeviceSlot? {
        var found: DeviceSlot?
        forEachDeviceSlot { slot, _ in
            if slot.id == id { found = slot }
        }
        return found
    }
}

/// UI-032: one device of the chain, what its card shows.
@MainActor
struct DeviceCardModel: Identifiable {
    struct Sidechain: Equatable {
        var source: NodeIDValue
        var name: String
    }

    let id: NodeIDValue
    let name: String
    /// `builtin`, `au`, `vst3`.
    let format: String
    let isInstrument: Bool
    /// Index in the insert chain; nil for the instrument.
    let position: Int?
    /// The document's bypass.
    let bypass: Bool
    /// PLUG-021, DW-226: an AU/VST3 slot in safe mode, bypassed whatever the document says.
    let safeModeBypassed: Bool
    let isPlugin: Bool
    /// Plugins: whether the engine loaded it (nil: no engine or no info yet), and why not.
    let loaded: Bool?
    let loadError: String?
    let editorOpen: Bool
    /// DW-264: the engine had no editor for it.
    let noEditor: Bool
    /// The generic controls show (always for built-ins).
    let showsParams: Bool
    let acceptsSidechain: Bool
    let sidechain: Sidechain?
    let params: [DeviceParamModel]
    var controls: [UIControl] = []

    var isBypassed: Bool { bypass || safeModeBypassed }
    var controlPrefix: String { "deviceChain.device.\(id)" }

    func control(_ suffix: String) -> UIControl? {
        let id = "\(controlPrefix).\(suffix)"
        return controls.first { $0.id == id }
    }
}

/// UI-032: one generic control of a device: its ParamInfo row and value.
struct DeviceParamModel: Identifiable, Equatable {
    let slot: NodeIDValue
    let row: ParamDescriptor
    /// Native units; the lane's value at the playhead while automation drives it (AUTO-007).
    let value: Float
    /// The document stores a value (else a built-in's default or a plugin's own value shows).
    let isSet: Bool
    let automated: Bool

    var id: Int { row.index }
    var index: Int { row.index }
    /// 0…1 along the control (the param's mapping, AUTO-008).
    var position: Double { Double(min(max(row.mapping.normalize(value), 0), 1)) }
    var display: String { row.display(value) }
    /// `slider`, `toggle` or `menu`.
    var style: String {
        if row.isSwitch && row.labels == nil { return "toggle" }
        return row.isDiscrete ? "menu" : "slider"
    }
}

/// PLUG-010/015: what the engine says of a hosted plugin (`pluginInfoJSON`).
struct PluginInfo: Equatable, Sendable {
    struct Param: Equatable, Sendable, Decodable {
        var index: Int
        var id: String
        var name: String
        var unit: String
        var min: Float
        var max: Float
        var value: Float

        private enum CodingKeys: String, CodingKey { case index, id, name, unit, min, max, value }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = try c.decode(Int.self, forKey: .index)
            id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? "\(index)"
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Param \(index)"
            unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
            min = try c.decodeIfPresent(Float.self, forKey: .min) ?? 0
            max = try c.decodeIfPresent(Float.self, forKey: .max) ?? 1
            value = try c.decodeIfPresent(Float.self, forKey: .value) ?? min
        }
    }

    var loaded: Bool
    var error: String?
    var name: String?
    var sidechain: Bool?
    var params: [Param]

    static func parse(_ json: String) -> PluginInfo? {
        struct Raw: Decodable {
            var loaded: Bool?
            var error: String?
            var name: String?
            var sidechain: Bool?
            var params: [Param]?
        }
        guard !json.isEmpty, let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { return nil }
        return PluginInfo(loaded: raw.loaded ?? false, error: raw.error, name: raw.name, sidechain: raw.sidechain,
                          params: raw.params ?? [])
    }
}
