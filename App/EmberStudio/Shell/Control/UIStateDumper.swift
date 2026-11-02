import DAWControl
import DAWModel
import Foundation

/// UI-050: the view-model tree as JSON, for `ui.state` (CTL-002). It reads the view models, not the
/// views, so what it reports is what the views are drawn from.
///
///     {"mainWindow": 1, "windows": [{
///        "id": 1, "title": "Untitled", "isMain": true,
///        "project": {"id", "name", "path", "dirty", "tracks": n},
///        "panes": {"browser": true, "inspector": true, "bottom": "mixer" | null},
///        "selection": {"tracks": [ids], "clips": [ids]},
///        "zoom": {"pixelsPerBeat": 32}, "scroll": {"x": 0, "y": 0, "viewportHeight": 480},
///        "visibleTracks": [ids],
///        "tracks": [{"id", "name", "kind", "mute", "solo", "selected"}],
///        "transport": {"playing", "recording", "tick"},
///        "toasts": [{"id", "kind", "severity", "title", "message", "action"?, "count"?}],
///        "controls": [{"id", "kind", "label", "isOn"?, "enabled"}]}]}
@MainActor
enum UIStateDumper {
    static func dump(_ app: AppModel) -> JSONValue {
        [
            "mainWindow": app.mainWindowID.map { .int(Int64($0)) } ?? .null,
            "windows": .array(app.windows.map { dump($0, isMain: $0.id == app.mainWindowID) }),
        ]
    }

    static func dump(_ window: ProjectWindowModel, isMain: Bool) -> JSONValue {
        let store = window.store
        return [
            "id": .int(Int64(window.id)),
            "title": .string(window.title),
            "isMain": .bool(isMain),
            "project": [
                "id": .string(store.project.id.uuidString),
                "name": .string(store.project.name),
                "path": store.folderURL.map { .string($0.path) } ?? .null,
                "dirty": .bool(store.isDirty),
                "tracks": .int(Int64(store.project.tracks.count)),
            ],
            "panes": [
                "browser": .bool(window.showsBrowser),
                "inspector": .bool(window.showsInspector),
                "bottom": window.bottomPane.map { .string($0.rawValue) } ?? .null,
            ],
            "selection": [
                "tracks": ids(window.selectedTracks.sorted()),
                "clips": ids(window.selectedClips.sorted()),
            ],
            "zoom": ["pixelsPerBeat": .double(window.pixelsPerBeat)],
            "scroll": [
                "x": .double(window.scrollX), "y": .double(window.scrollY), "viewportHeight": .double(window.viewportHeight),
            ],
            "visibleTracks": ids(window.visibleTracks),
            "tracks": .array(window.trackHeaders.map { track in
                [
                    "id": .int(Int64(bitPattern: track.id)), "name": .string(track.name), "kind": .string(track.kind.rawValue),
                    "mute": .bool(track.mute), "solo": .bool(track.solo), "selected": .bool(track.isSelected),
                ]
            }),
            "transport": [
                "playing": .bool(window.transport.playing),
                "recording": .bool(window.transport.recording),
                "tick": .int(window.transport.tick.raw),
            ],
            "toasts": .array(window.toasts.toasts.map(dump)),
            "controls": .array(window.controls.map(dump)),
        ]
    }

    static func dump(_ toast: Toast) -> JSONValue {
        var json: [String: JSONValue] = [
            "id": .int(Int64(toast.id)), "kind": .string(toast.kind.rawValue), "severity": .string(toast.severity.rawValue),
            "title": .string(toast.title), "message": .string(toast.message),
        ]
        if let action = toast.action { json["action"] = .string(action.label) }
        if let count = toast.count { json["count"] = .int(Int64(clamping: count)) }
        return .object(json)
    }

    static func dump(_ control: UIControl) -> JSONValue {
        var json: [String: JSONValue] = [
            "id": .string(control.id), "kind": .string(control.kind.rawValue), "label": .string(control.label),
            "enabled": .bool(control.isEnabled),
        ]
        if let isOn = control.isOn { json["isOn"] = .bool(isOn) }
        return .object(json)
    }

    private static func ids(_ values: [UInt64]) -> JSONValue {
        .array(values.map { .int(Int64(bitPattern: $0)) })
    }
}
