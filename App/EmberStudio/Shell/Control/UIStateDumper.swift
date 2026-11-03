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
///        "toolbar": {"position", "time", "tempo", "signature", "loop": {"enabled", "start", "end"} | null,
///                    "metronome", "dspLoadPercent", "xruns"},
///        "keyBindings": [{"keys": "⇧⌘T", "control": "track.add.midi"}],
///        "toasts": [{"id", "kind", "severity", "title", "message", "action"?, "count"?}],
///        "controls": [{"id", "kind", "label", "isOn"?, "enabled"}],
///        "arrange": {"snap", "pixelsPerBeat", "size", "visibleTicks", "visibleRows", "clipCount",
///                    "visibleClips": [{"id", "track", "kind", "start", "length", "selected", "rect",
///                                      audio: "assetID", "gain", "fadeIn", "fadeOut", "waveformLevel" | null;
///                                      midi: "notes"}],
///                    "selection", "marquee", "gesture", "playhead": {"tick", "x"}}}]}
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
            "toolbar": toolbar(window),
            "keyBindings": .array(KeyBindings.all.map { ["keys": .string($0.chord.description), "control": .string($0.controlID)] }),
            "toasts": .array(window.toasts.toasts.map(dump)),
            "controls": .array(window.controls.map(dump)),
            "arrange": dump(window.arrange),
        ]
    }

    /// 12 *Layout*: what the toolbar reads out (UI-002's transport state is in `transport`/`controls`).
    static func toolbar(_ window: ProjectWindowModel) -> JSONValue {
        [
            "position": .string(window.positionBBT),
            "time": .string(window.positionTime),
            "tempo": .double(window.tempo),
            "signature": .string(window.signature),
            "loop": window.project.loop.map { loop in
                ["enabled": .bool(loop.isEnabled), "start": .int(loop.start.raw), "end": .int(loop.end.raw)]
            } ?? .null,
            "metronome": .bool(window.metronomeEnabled),
            "dspLoadPercent": .double(Double(window.telemetry.dspLoadPercent)),
            "xruns": .int(Int64(clamping: window.telemetry.xruns)),
        ]
    }

    /// UI-010..014: the arrange canvas: snap, zoom, what is visible (through the interval index) and
    /// how each visible clip is drawn, the gesture in progress and the playhead.
    static func dump(_ arrange: ArrangeModel) -> JSONValue {
        let g = arrange.geometry
        let visible = g.visibleTicks
        let rows = g.visibleRows(of: arrange.tracks.count)
        let selection = arrange.selection
        let playhead = arrange.playheadTick()
        return [
            "snap": .string(arrange.snap.rawValue),
            "pixelsPerBeat": .double(g.pixelsPerBeat),
            "size": ["width": .double(g.size.width), "height": .double(g.size.height)],
            "visibleTicks": ["from": .int(visible.from.raw), "to": .int(visible.to.raw)],
            "visibleRows": ["from": .int(Int64(rows.lowerBound)), "to": .int(Int64(rows.upperBound))],
            "clipCount": .int(Int64(arrange.index.clipCount)),
            "visibleClips": .array(arrange.visibleClips.map { entry in
                let rect = g.rect(start: entry.clip.start, length: entry.clip.length, row: entry.row)
                var json: [String: JSONValue] = [
                    "id": .int(Int64(bitPattern: entry.id)), "track": .int(Int64(bitPattern: entry.trackID)),
                    "start": .int(entry.start), "length": .int(entry.clip.length.raw), "selected": .bool(selection.contains(entry.id)),
                    "rect": ["x": .double(rect.minX), "y": .double(rect.minY), "width": .double(rect.width), "height": .double(rect.height)],
                ]
                switch entry.clip {
                case .audio(let audio):
                    json["kind"] = "audio"
                    json["assetID"] = .int(Int64(bitPattern: audio.assetID))
                    json["gain"] = .double(Double(audio.gain))
                    json["fadeIn"] = .int(audio.fadeIn.raw)
                    json["fadeOut"] = .int(audio.fadeOut.raw)
                    json["waveformLevel"] = arrange.waveformLevel(audio).map { .int(Int64($0)) } ?? .null
                case .midi(let midi):
                    json["kind"] = "midi"
                    json["notes"] = .int(Int64(midi.notes.count))
                }
                return .object(json)
            }),
            "selection": ids(selection.sorted()),
            "marquee": arrange.marquee.map { ["x": .double($0.minX), "y": .double($0.minY), "width": .double($0.width),
                                              "height": .double($0.height)] } ?? .null,
            "gesture": arrange.activeGesture.map { .string($0) } ?? .null,
            "playhead": ["tick": .int(playhead.raw), "x": .double(g.x(playhead))],
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
