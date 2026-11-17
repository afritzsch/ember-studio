import Foundation
import os

/// PLUG-015 second half, DW-204 (T-063): turns a plugin's own parameter edits (its editor's knobs,
/// `pluginParamEdited` events) into the document's `SetParam`s, so `DeviceSlot.params` follows the
/// plugin and the edit can be undone.
///
/// - A gesture (`begin` … `end` of a param) is **one undo entry** (MODEL-003): the first `begin`
///   opens a store gesture labelled "Set Parameter", each `value` performs `SetParam` inside it, and
///   the last `end` closes it. Overlapping gestures of one plugin (an XY pad moving two params) share
///   that entry.
/// - Ungestured values (a menu, a preset: no `begin` of that param open) are collected and applied
///   as one entry per poll (`finishBatch`), or inside the open gesture if there is one.
/// - A value the document already holds is skipped: the engine's echo of the model's own value
///   never makes a second entry, and an edit that changes nothing makes none.
/// - Edits of a slot that isn't a hosted plugin in the project are dropped. Gestures of a slot that
///   left the project, or whose editor closed (`endGestures(slot:)`), end; an undo/redo ends the
///   store's gesture, and a later value of the same plugin gesture opens a new one.
@MainActor
public final class PluginEditRecorder {
    public struct Key: Hashable, Sendable {
        public var slot: NodeIDValue
        public var index: Int
    }

    public static let label = "Set Parameter"

    weak var store: ProjectStore?
    /// The params whose plugin gesture is open.
    public private(set) var openGestures: Set<Key> = []
    private var ownsStoreGesture = false
    private var ungestured: [Key: Float] = [:]
    private var ungesturedOrder: [Key] = []

    private static let log = Logger(subsystem: "dev.emberstudio", category: "model")

    public init() {}

    /// One `pluginParamEdited` event, in the order the engine reported it.
    public func handle(slot: NodeIDValue, edit: PluginParamEdit) {
        guard let store, Self.isPlugin(slot, in: store.project),
              (0...DeviceSlot.maxParamIndex).contains(edit.index)
        else { return }
        let key = Key(slot: slot, index: edit.index)
        switch edit.phase {
        case .begin:
            openGestures.insert(key)
            ensureGesture(store)
        case .value:
            if openGestures.contains(key) {
                ensureGesture(store)
                apply(key, edit.value, store)
            } else {
                if ungestured.updateValue(edit.value, forKey: key) == nil { ungesturedOrder.append(key) }
            }
        case .end:
            guard openGestures.remove(key) != nil else { return }
            if openGestures.isEmpty { closeGesture(store) }
        }
    }

    /// The end of one poll's events: ungestured values become one entry; gestures of slots that
    /// left the project end.
    public func finishBatch() {
        guard let store else {
            ungestured = [:]
            ungesturedOrder = []
            return
        }
        let gone = openGestures.filter { !Self.isPlugin($0.slot, in: store.project) }
        if !gone.isEmpty {
            openGestures.subtract(gone)
            if openGestures.isEmpty { closeGesture(store) }
        }
        let pending = ungesturedOrder.compactMap { key in ungestured[key].map { (key, $0) } }
            .filter { Self.isPlugin($0.0.slot, in: store.project) && !Self.holds(store.project, $0.0, $0.1) }
        ungestured = [:]
        ungesturedOrder = []
        guard !pending.isEmpty else { return }
        if ownsStoreGesture {
            ensureGesture(store)
            for (key, value) in pending { apply(key, value, store) }
        } else {
            store.beginGesture(Self.label)
            for (key, value) in pending { apply(key, value, store) }
            store.endGesture()
        }
    }

    /// Ends the open plugin gestures of `slot` (all with nil): its editor closed or the engine went.
    /// What they changed so far stays as one entry.
    public func endGestures(slot: NodeIDValue? = nil) {
        let ending = slot.map { s in openGestures.filter { $0.slot == s } } ?? openGestures
        guard !ending.isEmpty else { return }
        openGestures.subtract(ending)
        if openGestures.isEmpty, let store { closeGesture(store) }
    }

    // MARK: Private

    private func ensureGesture(_ store: ProjectStore) {
        if ownsStoreGesture && store.isGestureActive { return }
        store.beginGesture(Self.label)
        ownsStoreGesture = true
    }

    private func closeGesture(_ store: ProjectStore) {
        guard ownsStoreGesture else { return }
        ownsStoreGesture = false
        if store.isGestureActive { store.endGesture() }
    }

    private func apply(_ key: Key, _ value: Float, _ store: ProjectStore) {
        guard value.isFinite, !Self.holds(store.project, key, value) else { return }
        do {
            try store.perform(SetParam(target: .device(slot: key.slot, index: key.index), value: value))
        } catch {
            Self.log.error("plugin edit of slot \(key.slot) param \(key.index): \(error)")
        }
    }

    /// The document already has `value` for the param (the engine's echo, or no change).
    static func holds(_ project: Project, _ key: Key, _ value: Float) -> Bool {
        guard let slot = project.allDeviceSlots.first(where: { $0.id == key.slot }),
              let stored = slot.params.first(where: { $0.index == key.index })?.value
        else { return false }
        return abs(stored - value) <= 1e-6 * max(1, abs(value))
    }

    static func isPlugin(_ slot: NodeIDValue, in project: Project) -> Bool {
        project.allDeviceSlots.contains { $0.id == slot && $0.isPlugin }
    }
}
