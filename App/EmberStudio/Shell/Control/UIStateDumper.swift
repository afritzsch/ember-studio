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
///        "visibleTracks": [ids] (tracks with a row in view: own row, lane rows, take rows; DW-270),
///        "visibleRowCount": track + automation lane + take rows in view (DW-270),
///        "tracks": [{"id", "name", "kind", "mute", "solo", "selected", "armed", "inputPair", "monitoring",
///                    "monitoringLatency": {"samples", "ms"} | null (T-054, REC-021; null for MIDI tracks),
///                    "midiInput": {"source": "all" | "<unique ID>", "channel": 0…16, "name", "connected"} | null
///                                 (T-093; null for audio tracks)}],
///        "transport": {"playing", "recording", "tick"},
///        "toolbar": {"position", "time", "tempo", "signature", "loop": {"enabled", "start", "end"} | null,
///                    "metronome", "dspLoadPercent", "xruns", "tempoAtBar1", "signatureAtBar1" (DW-180)},
///        "keyBindings": [{"keys": "⇧⌘T", "control": "track.add.midi"}],
///        "toasts": [{"id", "kind", "severity", "title", "message", "action"?, "count"?}],
///        "controls": [{"id", "kind", "label", "isOn"?, "enabled"}],
///        "arrange": {"snap", "pixelsPerBeat", "size", "visibleTicks", "visibleRows", "clipCount",
///                    "visibleClips": [{"id", "track", "kind", "start", "length", "selected", "rect",
///                                      audio: "assetID", "gain", "fadeIn", "fadeOut", "waveformLevel" | null;
///                                      midi: "notes"}],
///                    "selection", "marquee", "gesture", "playhead": {"tick", "x"}},
///        "pianoRoll": {…}, "audioPreferences": {…}, "mixer": {…}, "export": {…},
///        "engine": {"live", "mode"} | null, "feedbackWarning": {…} | null,
///        "safeMode": {"on", "plugins": [{"slot", "format", "identifier", "name"}], "enabled": [same]}}],
///      "liveWindow": id | null, "crashRecovery": {…} | null}
@MainActor
enum UIStateDumper {
    static func dump(_ app: AppModel) -> JSONValue {
        [
            "mainWindow": app.mainWindowID.map { .int(Int64($0)) } ?? .null,
            "windows": .array(app.windows.map { dump($0, isMain: $0.id == app.mainWindowID) }),
            // DW-156 (T-090): the window holding the app's live engine (null with --engine offline).
            "liveWindow": app.liveWindow.map { .int(Int64($0.id)) } ?? .null,
            // UI-043 (T-083): the crash-recovery dialog while it is presented.
            "crashRecovery": app.crashRecovery.map(dump) ?? .null,
        ]
    }

    /// UI-043 (T-083): the crash-recovery dialog.
    ///
    ///     {"presented", "opening", "title", "message", "choice": "openSafe"|"openNormally"|"dontOpen"|null,
    ///      "sessions": [{"pid", "launched"}],
    ///      "projects": [{"id", "name", "path"|null, "canOpen", "recoveryAvailable", "recover",
    ///                    "plugins": [{"slot", "format", "identifier", "name"}]}],
    ///      "failures": [{"name", "error"}], "controls": [ids]}
    static func dump(_ crash: CrashRecoveryModel) -> JSONValue {
        let iso = ISO8601DateFormatter()
        return [
            "presented": .bool(crash.isPresented), "opening": .bool(crash.isOpening),
            "title": .string(crash.title), "message": .string(crash.message),
            "choice": crash.choice.map { .string($0.rawValue) } ?? .null,
            "sessions": .array(crash.sessions.map {
                ["pid": .int(Int64($0.processID)), "launched": .string(iso.string(from: $0.launched))]
            }),
            "projects": .array(crash.entries.map { entry in
                [
                    "id": .int(Int64(entry.id)), "name": .string(entry.name), "path": entry.path.map(JSONValue.string) ?? .null,
                    "canOpen": .bool(entry.canOpen), "recoveryAvailable": .bool(entry.recoveryAvailable),
                    "recover": .bool(entry.recover), "plugins": plugins(entry.plugins),
                ]
            }),
            "failures": .array(crash.failures.map { ["name": .string($0.name), "error": .string($0.error)] }),
            "controls": .array(crash.controls.map { .string($0.id) }),
        ]
    }

    /// T-083: plugin slots as the running marker lists them.
    static func plugins(_ plugins: [CrashMarker.Plugin]) -> JSONValue {
        .array(plugins.map {
            ["slot": .int(Int64(bitPattern: $0.slotID)), "format": .string($0.format), "identifier": .string($0.identifier),
             "name": .string($0.name)]
        })
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
            "visibleRowCount": .int(Int64(window.visibleRowCount)),  // DW-270 (T-095)
            "tracks": .array(window.trackHeaders.map { track in
                [
                    "id": .int(Int64(bitPattern: track.id)), "name": .string(track.name), "kind": .string(track.kind.rawValue),
                    "mute": .bool(track.mute), "solo": .bool(track.solo), "selected": .bool(track.isSelected),
                    // T-055 (REC-001, REC-020): arm, input pair, monitoring.
                    "armed": .bool(track.armed), "inputPair": .int(Int64(track.inputPair)),
                    "monitoring": .string(track.monitoring.rawValue),
                    // T-054 (REC-021): software monitoring latency, audio tracks.
                    "monitoringLatency": track.monitoringLatency.map { latency -> JSONValue in
                        ["samples": .int(Int64(latency.samples)), "ms": .double(latency.milliseconds)]
                    } ?? .null,
                    // T-093 (DW-216): a MIDI track's input; channel 0 is omni.
                    "midiInput": track.midiInputMenu.map(midiInput) ?? .null,
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
            "export": dump(window.exportDialog),  // T-082
            "automation": dump(window.automation),  // T-075 (UI-015)
            "takes": dump(window.takes),  // T-081 (UI-016)
            "engine": engine(window),  // T-090 (DW-156)
            "feedbackWarning": dump(window.feedbackGuard),  // T-090 (DW-230)
            "pluginEditors": dump(window.pluginEditors),  // T-063 (PLUG-017)
            "deviceChain": dump(window.deviceChain),  // T-065 (UI-032)
            "pluginManager": dump(window.pluginPanel),  // T-065 (UI-041)
            // T-083 (PLUG-021, DW-226): safe mode, with the plugin slots it keeps from loading.
            "safeMode": ["on": .bool(store.isSafeMode), "plugins": plugins(window.safeModePlugins),
                         "enabled": plugins(window.safeModeEnabledPlugins)],  // DW-266 (T-095)
        ]
    }

    /// PLUG-017 (T-063): the window's open plugin editors, by slot.
    ///
    ///     [{"slot", "title", "kind": "au"|"auGeneric"|"vst3", "width", "height", "ready", "resizable",
    ///       "control": "<prefix>.insert.<slot>.editor" | "<prefix>.instrument.editor" | null}]
    static func dump(_ editors: PluginEditorModel) -> JSONValue {
        let controls = editors.window?.mixer.strips.flatMap(\.editorControls).map(\.id) ?? []
        return .array(editors.openSlots.compactMap { slot in
            guard let e = editors.editors[slot] else { return nil }
            let control = controls.first { $0.hasSuffix(".insert.\(slot).editor") }
                ?? editors.window?.project.tracks.first { $0.instrument?.id == slot }.map { "mixer.track.\($0.id).instrument.editor" }
            return [
                "slot": .int(Int64(bitPattern: slot)), "title": .string(e.title), "kind": .string(e.kind),
                "width": .double(e.width), "height": .double(e.height), "ready": .bool(e.ready), "resizable": .bool(e.resizable),
                "control": control.map(JSONValue.string) ?? .null,
            ]
        })
    }

    /// DW-156 (T-090): which engine the window's project has: the app's live one (front window
    /// only) or an offline one.
    ///
    ///     {"live": true, "mode": "realtime" | "offline"} | null (no engine)
    static func engine(_ window: ProjectWindowModel) -> JSONValue {
        guard let engine = window.engine else { return .null }
        let mode: String = if case .realtime = engine.mode { "realtime" } else { "offline" }
        return ["live": .bool(window.hasLiveEngine), "mode": .string(mode)]
    }

    /// UI-015, AUTO-006 (T-075): automation lanes and recording passes:
    /// `{expandedTracks: [ids], gesture, lanes: [{id, track, target, name, mode, row, rect, points:
    /// [{tick, value, curve}], controls: [ids]}] (shown lanes), allLanes: [{id, channel, target,
    /// mode, pointCount}], recording: [{lane, target, mode, from, lastTick, points, held}]}`.
    static func dump(_ automation: AutomationLanesModel) -> JSONValue {
        let g = automation.window?.arrange.geometry
        var all: [JSONValue] = []
        automation.window?.project.forEachAutomationLane { lane, channel in
            all.append(["id": .int(Int64(bitPattern: lane.id)), "channel": .int(Int64(bitPattern: channel)),
                        "target": target(lane.target), "mode": .string(lane.mode.rawValue),
                        "pointCount": .int(Int64(lane.points.count))])
        }
        let passes = (automation.recorder?.passes.values.sorted { $0.laneID < $1.laneID }) ?? []
        return [
            "expandedTracks": ids(automation.expanded.sorted()),
            "gesture": automation.activeGesture.map { .string($0) } ?? .null,
            "lanes": .array(automation.layout.lanes.map { row in
                let rect: JSONValue = g.map { g in
                    ["x": 0, "y": .double(g.rowY(row.row)), "width": .double(g.size.width), "height": .double(g.trackHeight)]
                } ?? .null
                return [
                    "id": .int(Int64(bitPattern: row.lane.id)), "track": .int(Int64(bitPattern: row.trackID)),
                    "target": target(row.lane.target), "name": .string(row.name), "mode": .string(row.lane.mode.rawValue),
                    "row": .int(Int64(row.row)), "rect": rect,
                    "points": .array(row.lane.points.map { point in
                        ["tick": .int(point.tick.raw), "value": .double(Double(point.value)), "curve": .string(curveName(point.curve))]
                    }),
                    "controls": .array(automation.laneControls(row).map { .string($0.id) }),
                ]
            }),
            "allLanes": .array(all),
            "recording": .array(passes.map { pass in
                ["lane": .int(Int64(bitPattern: pass.laneID)), "target": target(pass.target), "mode": .string(pass.mode.rawValue),
                 "from": .int(pass.from.raw), "lastTick": .int(pass.lastTick.raw), "points": .int(Int64(pass.points.count)),
                 "held": .bool(pass.held)]
            }),
        ]
    }

    /// UI-016 (T-081): take folders and their take rows:
    /// `{expandedFolders: [ids], gesture, swipe: {folder, take, start, end, started} | null,
    /// folders: [{id, track, trackName, start, end, expanded, row, rect, disclosure, comp: [{start,
    /// end, take}], takes: [{id, number, start, end, inComp, pieces: [{start, end, inComp}], band,
    /// rect (null while collapsed), swipe (the ui.perform id), controls}], controls}]}`. Rects are in
    /// canvas view points.
    static func dump(_ takes: TakeFoldersModel) -> JSONValue {
        guard let window = takes.window else { return .null }
        let g = window.arrange.geometry
        let rows = takes.rows(geometry: g)
        func rect(_ r: CGRect) -> JSONValue {
            ["x": .double(r.minX), "y": .double(r.minY), "width": .double(r.width), "height": .double(r.height)]
        }
        func id(_ v: ModelID) -> JSONValue { .int(Int64(bitPattern: v)) }
        let folders = takes.placements(geometry: g)
        let swipe: JSONValue = takes.swipe.map { s in
            ["folder": id(s.folderID), "take": id(s.takeID), "start": .int(s.range.start.raw), "end": .int(s.range.end.raw),
             "started": .bool(s.started)]
        } ?? .null
        return [
            "expandedFolders": ids(takes.expanded.filter { window.project.takeFolder($0) != nil }.sorted()),
            "gesture": takes.activeGesture.map { .string($0) } ?? .null,
            "swipe": swipe,
            "folders": .array(folders.map { p in
                let folder = p.folder
                let trackName = window.project.tracks[p.trackIndex].name
                return [
                    "id": id(folder.id), "track": id(p.trackID), "trackName": .string(trackName),
                    "start": .int(folder.start.raw), "end": .int(folder.end.raw), "expanded": .bool(takes.expanded.contains(folder.id)),
                    "row": .int(Int64(p.row)), "rect": rect(takes.folderRect(p, geometry: g)),
                    "disclosure": rect(takes.disclosureRect(p, geometry: g)),
                    "comp": .array(folder.comp.map { ["start": .int($0.start.raw), "end": .int($0.end.raw), "take": id($0.take)] }),
                    "takes": .array(folder.takes.enumerated().map { n, take in
                        let row = rows.first { $0.folderID == folder.id && $0.take.id == take.id }
                        let pieces = TakeFoldersModel.pieces(of: take, in: folder)
                        return [
                            "id": id(take.id), "number": .int(Int64(n + 1)), "start": .int(take.clip.start.raw),
                            "end": .int(take.clip.end.raw), "inComp": .bool(pieces.contains { $0.inComp }),
                            "pieces": .array(pieces.map { ["start": .int($0.start.raw), "end": .int($0.end.raw), "inComp": .bool($0.inComp)] }),
                            "band": row.map { .int(Int64($0.band)) } ?? .null,
                            "rect": row.map { rect(takes.takeRect($0, geometry: g)) } ?? .null,
                            "swipe": .string(TakeFoldersModel.swipeID(folder: folder.id, take: take.id)),
                            "controls": .array((takes.expanded.contains(folder.id) ? ["takeFolder.\(folder.id).take.\(take.id).select"] : []).map { .string($0) }),
                        ]
                    }),
                    "controls": .array(takes.folderControls(folder, trackName: trackName).map { .string($0.id) }),
                ]
            }),
        ]
    }

    private static func target(_ target: ParamTarget) -> JSONValue {
        switch target {
        case .strip(let channel, let param):
            ["kind": "strip", "channel": .int(Int64(bitPattern: channel)), "param": .string(param.rawValue)]
        case .sendLevel(let send):
            ["kind": "sendLevel", "send": .int(Int64(bitPattern: send))]
        case .device(let slot, let index):
            ["kind": "device", "slot": .int(Int64(bitPattern: slot)), "index": .int(Int64(index))]
        }
    }

    private static func curveName(_ curve: AutomationPoint.Curve) -> String {
        switch curve {
        case .linear: "linear"
        case .hold: "hold"
        case .exp: "exp"
        }
    }

    /// DW-230 (T-090): the monitoring feedback warning while it lasts.
    ///
    ///     {"tracks": [{id, name, monitoring, armed}], "input": {id, name}, "output": {id, name},
    ///      "toast": id | null} | null
    static func dump(_ feedback: FeedbackGuard) -> JSONValue {
        guard let risk = feedback.risk, let window = feedback.window else { return .null }
        let shown = feedback.toastID.flatMap { id in window.toasts.toasts.contains { $0.id == id } ? id : nil }
        return [
            "tracks": .array(risk.tracks.compactMap { id in
                window.project.track(id).map { track in
                    [
                        "id": .int(Int64(bitPattern: track.id)), "name": .string(track.name),
                        "monitoring": .string(track.monitoring.rawValue), "armed": .bool(track.armed),
                    ]
                }
            }),
            "input": ["id": .int(Int64(risk.input.id)), "name": .string(risk.input.name)],
            "output": ["id": .int(Int64(risk.output.id)), "name": .string(risk.output.name)],
            "toast": shown.map { .int(Int64($0)) } ?? .null,
        ]
    }

    /// UI-042 (T-082): the export dialog's settings, each range's span, the destination and the
    /// render in progress or last finished. 12 *Export dialog details*.
    ///
    ///     {"open", "range", "ranges": [{id, available, from?, to?, seconds?}], "fileType",
    ///      "sampleFormat", "dither", "normalize", "tail", "tailMaxSeconds", "includeMetronome",
    ///      "path", "destinationChosen", "running", "progress",
    ///      "lastResult": {path, sampleRate, frames, seconds, peak, normalizeGain, clippedSamples,
    ///                     rtViolations} | null, "error"}
    static func dump(_ export: ExportModel) -> JSONValue {
        [
            "open": .bool(export.isOpen),
            "range": .string(export.range.rawValue),
            "ranges": .array(ExportRange.allCases.map { range in
                var json: [String: JSONValue] = ["id": .string(range.rawValue), "available": .bool(export.isAvailable(range))]
                if let span = export.span(range) {
                    json["from"] = .int(span.from.raw)
                    json["to"] = .int(span.to.raw)
                    json["seconds"] = .double(export.seconds(span))
                }
                return .object(json)
            }),
            "fileType": .string(export.fileType.rawValue),
            "sampleFormat": .string(export.sampleFormat.rawValue),
            "dither": .bool(export.spec.dither),
            "normalize": .bool(export.normalize),
            "tail": .bool(export.tail),
            "tailMaxSeconds": .double(export.tailMaxSeconds),
            "includeMetronome": .bool(export.includeMetronome),
            "path": export.destination.map { .string($0.path) } ?? .null,
            "destinationChosen": .bool(export.destinationChosen),
            "running": .bool(export.isRunning),
            "progress": .double(export.progress),
            "lastResult": export.lastResult.map { done in
                [
                    "path": .string(done.path), "sampleRate": .double(done.render.sampleRate),
                    "frames": .int(done.render.framesWritten), "seconds": .double(done.render.durationSeconds),
                    "peak": .double(done.render.peak), "normalizeGain": .double(done.render.normalizeGain),
                    "clippedSamples": .int(Int64(clamping: done.render.clippedSamples)),
                    "rtViolations": .int(Int64(clamping: done.render.rtViolations)),
                ]
            } ?? .null,
            "error": export.lastError.map { .string($0) } ?? .null,
        ]
    }

    /// UI-030/031/033 (T-076): the Mixer tab: each strip's values, routing, sends, inserts, meter and
    /// the ids of its controls (a track's mute, solo, arm, monitor and input are its header's,
    /// `track.<id>.…`). 12 *Mixer details*. `gainDB`, `levelDB` are null for silence; a strip's
    /// `meter` is null until the engine reports one.
    ///
    ///     {"open", "gesture", "strips": [{id, kind (audio|midi|bus|master), name, controlPrefix,
    ///      selected, gain, gainDB, faderPosition, pan, panLabel, mute, solo, armed?, inputPair?, monitoring?,
    ///      midiInput? (T-093: a track strip's, as in `tracks`; null for audio),
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
        json["inserts"] = mixerInserts(strip)  // T-065 (DW-250): with safe mode, format, editor
        if strip.header != nil {
            json["armed"] = .bool(strip.armed)
            json["inputPair"] = .int(Int64(strip.inputPair))
            json["monitoring"] = .string(strip.monitoring.rawValue)
            json["midiInput"] = strip.header?.midiInputMenu.map(midiInput) ?? .null  // T-093
        }
        return .object(json)
    }

    /// T-093: `{"source", "channel", "name", "connected"}`.
    private static func midiInput(_ menu: TrackMidiInputMenu) -> JSONValue {
        [
            "source": .string(menu.input.source.description), "channel": .int(Int64(menu.input.channel)),
            "name": .string(menu.sourceName), "connected": .bool(menu.connected),
        ]
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
    ///      outputChannels, nominalSampleRate, isDefaultOutput, isDefaultInput, isBuiltIn,
    ///      outputIsHeadphones}], "outputDevice", "inputDevice"
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
                    // T-090 (DW-230)
                    "isDefaultInput": .bool(device.isDefaultInput), "isBuiltIn": .bool(device.isBuiltIn),
                    "outputIsHeadphones": .bool(device.outputIsHeadphones),
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
            // DW-180 (T-095): what the editable fields set (bar 1's values).
            "tempoAtBar1": .double(window.tempoAtBar1),
            "signatureAtBar1": .string("\(window.signatureAtBar1.numerator)/\(window.signatureAtBar1.denominator)"),
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
