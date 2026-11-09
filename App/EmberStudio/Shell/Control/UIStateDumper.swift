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
///        "tracks": [{"id", "name", "kind", "mute", "solo", "selected", "armed", "inputPair", "monitoring"}],
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
///                    "selection", "marquee", "gesture", "playhead": {"tick", "x"}},
///        "pianoRoll": {…}, "audioPreferences": {…}, "mixer": {…}}]}
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
                    // T-055 (REC-001, REC-020): arm, input pair, monitoring.
                    "armed": .bool(track.armed), "inputPair": .int(Int64(track.inputPair)),
                    "monitoring": .string(track.monitoring.rawValue),
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
            "pianoRoll": dump(window.pianoRoll),
            "audioPreferences": dump(window.audioPrefs),
            "mixer": dump(window.mixer),
        ]
    }

    /// UI-030/031/033 (T-076): the Mixer tab: each strip's values, routing, sends, inserts, meter and
    /// the ids of its controls (a track's mute, solo, arm, monitor and input are its header's,
    /// `track.<id>.…`). 12 *Mixer details*. `gainDB`, `levelDB` are null for silence; a strip's
    /// `meter` is null until the engine reports one.
    ///
    ///     {"open", "gesture", "strips": [{id, kind (audio|midi|bus|master), name, controlPrefix,
    ///      selected, gain, gainDB, faderPosition, pan, panLabel, mute, solo, armed?, inputPair?, monitoring?,
    ///      output: {kind, id?, name} | null, outputChoices: [{id, name, current}],
    ///      sends: [{id, target, targetName, level, levelDB, tap, levelPosition, controls}],
    ///      sendTargets: [{id, name}], inserts: [{id, name, bypass}],
    ///      meter: {peak, rms, peakDB, rmsDB, holdDB, clipped} | null, controls: [ids]}]}
    static func dump(_ mixer: MixerModel) -> JSONValue {
        [
            "open": .bool(mixer.isOpen),
            "gesture": mixer.activeDrag.map { .string($0.label) } ?? .null,
            "strips": .array(mixer.strips.map { dump($0, meters: mixer.meters) }),
        ]
    }

    private static func dump(_ strip: MixerStripModel, meters: MeterBank) -> JSONValue {
        var json: [String: JSONValue] = [
            "id": .int(Int64(bitPattern: strip.id)), "kind": .string(strip.kind.rawValue), "name": .string(strip.name),
            "controlPrefix": .string(strip.controlPrefix), "selected": .bool(strip.isSelected),
            "gain": .double(Double(strip.gain)), "gainDB": gainDB(strip.gain), "gainLabel": .string(FaderTaper.label(gain: strip.gain)),
            "faderPosition": .double(strip.faderPosition), "pan": .double(Double(strip.pan)),
            "panLabel": .string(PanTaper.label(pan: strip.pan)), "mute": .bool(strip.mute), "solo": .bool(strip.solo),
            "output": strip.output.map { output in
                switch output {
                case .master: ["kind": "master", "name": .string(strip.outputTitle ?? "")]
                case .bus(let id): ["kind": "bus", "id": .int(Int64(bitPattern: id)), "name": .string(strip.outputTitle ?? "")]
                }
            } ?? .null,
            "outputChoices": .array(strip.outputChoices.map { choice in
                ["id": .int(Int64(bitPattern: choice.id)), "name": .string(choice.name), "current": .bool(choice.isCurrent)]
            }),
            "sends": .array(strip.sends.map { send in
                [
                    "id": .int(Int64(bitPattern: send.id)), "target": .int(Int64(bitPattern: send.values.target)),
                    "targetName": .string(send.values.targetName), "level": .double(Double(send.values.level)),
                    "levelDB": gainDB(send.values.level), "levelPosition": .double(send.levelPosition),
                    "tap": .string(send.values.tap.rawValue), "controls": .array(send.controls.map { .string($0.id) }),
                ]
            }),
            "sendTargets": .array(strip.sendTargets.map { ["id": .int(Int64(bitPattern: $0.id)), "name": .string($0.name)] }),
            "inserts": .array(strip.inserts.map { ["id": .int(Int64(bitPattern: $0.id)), "name": .string($0.name), "bypass": .bool($0.bypass)] }),
            "meter": meter(meters.readMeter(strip.id), meters.state(of: strip.id)),
            "controls": .array(strip.allControlIDs.map { .string($0) }),
        ]
        if strip.header != nil {
            json["armed"] = .bool(strip.armed)
            json["inputPair"] = .int(Int64(strip.inputPair))
            json["monitoring"] = .string(strip.monitoring.rawValue)
        }
        return .object(json)
    }

    private static func gainDB(_ gain: Float) -> JSONValue {
        gain > 0 ? .double(20 * log10(Double(gain))) : .null
    }

    /// The engine's reading now; peak bar, hold line and clip latch from the last display frame.
    private static func meter(_ reading: MeterReading?, _ state: MeterBallistics?) -> JSONValue {
        guard reading != nil || state != nil else { return .null }
        return [
            "peak": reading.map { .double(Double($0.peak)) } ?? .null,
            "rms": reading.map { .double(Double($0.rms)) } ?? .null,
            "peakDB": state.map { .double($0.peakDB) } ?? .null,
            "rmsDB": state.map { .double($0.rmsDB) } ?? .null,
            "holdDB": state.map { .double($0.holdDB) } ?? .null,
            "clipped": .bool(state?.clipped ?? false),
        ]
    }

    /// UI-040, DW-183 (T-055): the audio settings and where a session-rate re-conversion is.
    ///
    ///     {"open", "driver": "fake" | "coreAudio" | null, "devices": [{id, name, inputChannels,
    ///      outputChannels, nominalSampleRate, isDefaultOutput}], "outputDevice", "inputDevice"
    ///      (0: system default), "runningDeviceID", "deviceRunning", "sampleRate" (the project's),
    ///      "engineSampleRate", "bufferFrames", "inputChannels", "inputChannelChoices",
    ///      "latency": {deviceSamples, graphSamples, totalSamples, totalMs},
    ///      "reload": {phase, previousSampleRate, sampleRate, done, total, failed} | null,
    ///      "assetsReloadPending", "error"}
    static func dump(_ prefs: AudioPreferencesModel) -> JSONValue {
        let config = prefs.config
        let telemetry = prefs.telemetry
        let latency = prefs.latency
        return [
            "open": .bool(prefs.isOpen),
            "driver": prefs.driver.map { .string($0.rawValue) } ?? .null,
            "devices": .array(prefs.devices.map { device in
                [
                    "id": .int(Int64(device.id)), "name": .string(device.name),
                    "inputChannels": .int(Int64(device.inputChannels)), "outputChannels": .int(Int64(device.outputChannels)),
                    "nominalSampleRate": .double(device.nominalSampleRate), "isDefaultOutput": .bool(device.isDefaultOutput),
                ]
            }),
            "outputDevice": config.map { .int(Int64($0.outputDevice)) } ?? .null,
            "inputDevice": config.map { .int(Int64($0.inputDevice)) } ?? .null,
            "runningDeviceID": .int(Int64(telemetry.outputDeviceID)),
            "deviceRunning": .bool(telemetry.deviceRunning),
            "sampleRate": .double(prefs.sessionSampleRate),
            "engineSampleRate": .double(telemetry.sampleRate),
            "bufferFrames": config.map { .int(Int64($0.bufferFrames)) } ?? .null,
            "inputChannels": config.map { .int(Int64($0.inputChannels)) } ?? .null,
            "inputChannelChoices": .array(prefs.inputChannelChoices.map { .int(Int64($0)) }),
            "latency": [
                "deviceSamples": .int(Int64(latency.deviceSamples)), "graphSamples": .int(Int64(latency.graphSamples)),
                "totalSamples": .int(Int64(latency.totalSamples)), "totalMs": .double(latency.totalMs),
            ],
            "reload": prefs.reload.map { r in
                [
                    "phase": .string(r.phase.rawValue), "previousSampleRate": .double(r.previousSampleRate),
                    "sampleRate": .double(r.sampleRate), "done": .int(Int64(r.done)), "total": .int(Int64(r.total)),
                    "failed": .int(Int64(r.failed)),
                ]
            } ?? .null,
            "assetsReloadPending": .int(Int64(telemetry.assetsReloadPending)),
            "error": prefs.lastError.map { .string($0) } ?? .null,
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

    /// UI-020/021 (T-043): the piano roll: the open clip and its track, tool, snap, quantize and
    /// audition settings, zoom and scroll, what is visible (pitches, ticks, notes with their view
    /// rects and velocity stems), selection, marquee, the gesture in progress, the pitches being
    /// auditioned, and the track's post-fader meter (so an audition can be heard through `ui.state`).
    ///
    ///     {"open", "clip", "track", "trackName", "clipStart", "clipLength", "noteCount", "tool", "snap",
    ///      "quantize": {"grid", "strength"}, "audition", "pixelsPerBeat", "keyHeight", "scroll": {x, y},
    ///      "size", "focused", "visiblePitches": {low, high} | null, "visibleTicks": {from, to},
    ///      "visibleNotes": [{id, start, length, pitch, velocity, selected, rect, velocityY}],
    ///      "selection", "marquee", "gesture", "sounding": [pitch], "auditionTrack",
    ///      "trackMeter": {peak, rms} | null, "playhead": {tick, x}}
    static func dump(_ roll: PianoRollModel) -> JSONValue {
        let g = roll.geometry
        let clip = roll.clip
        let visible = g.visibleTicks
        let meter = roll.trackID.flatMap { roll.window?.engine?.meter($0) }
        let playhead = roll.playheadTick()
        return [
            "open": .bool(clip != nil),
            "clip": clip.map { .int(Int64(bitPattern: $0.id)) } ?? .null,
            "track": roll.trackID.map { .int(Int64(bitPattern: $0)) } ?? .null,
            "trackName": roll.track.map { .string($0.name) } ?? .null,
            "clipStart": clip.map { .int($0.start.raw) } ?? .null,
            "clipLength": clip.map { .int($0.length.raw) } ?? .null,
            "noteCount": .int(Int64(roll.notes.count)),
            "tool": .string(roll.tool.rawValue),
            "snap": .string(roll.snap.rawValue),
            "quantize": ["grid": .string(roll.quantizeGrid.rawValue), "strength": .double(roll.quantizeStrength)],
            "audition": .bool(roll.auditionNotes),
            "pixelsPerBeat": .double(roll.pixelsPerBeat),
            "keyHeight": .double(roll.keyHeight),
            "scroll": ["x": .double(roll.scrollX), "y": .double(roll.scrollY)],
            "size": ["width": .double(g.size.width), "height": .double(g.size.height)],
            "focused": .bool(roll.hasKeyFocus),
            "visiblePitches": g.visiblePitches.map { ["low": .int(Int64($0.lowerBound)), "high": .int(Int64($0.upperBound))] } ?? .null,
            "visibleTicks": ["from": .int(visible.from), "to": .int(visible.to)],
            "visibleNotes": .array(roll.visibleNotes.map { note -> JSONValue in
                let r = g.rect(note)
                return [
                    "id": .int(Int64(bitPattern: note.id)), "start": .int(note.start.raw), "length": .int(note.length.raw),
                    "pitch": .int(Int64(note.pitch)), "velocity": .int(Int64(note.velocity)),
                    "selected": .bool(roll.selection.contains(note.id)),
                    "rect": ["x": .double(r.minX), "y": .double(r.minY), "width": .double(r.width), "height": .double(r.height)],
                    "velocityY": .double(g.velocityY(note.velocity)),
                ]
            }),
            "selection": ids(roll.selectedNotes.map(\.id).sorted()),
            "marquee": roll.marquee.map { ["x": .double($0.minX), "y": .double($0.minY), "width": .double($0.width),
                                           "height": .double($0.height)] } ?? .null,
            "gesture": roll.activeGesture.map { .string($0) } ?? .null,
            "sounding": .array(roll.sounding.map { .int(Int64($0)) }),
            "auditionTrack": roll.auditionTrack.map { .int(Int64(bitPattern: $0)) } ?? .null,
            "trackMeter": meter.map { ["peak": .double(Double($0.peak)), "rms": .double(Double($0.rms))] } ?? .null,
            "playhead": ["tick": .int(playhead.raw), "x": .double(g.x(playhead.raw))],
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
