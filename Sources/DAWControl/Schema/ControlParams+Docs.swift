// CTL-021: property descriptions for the tool input schemas, from the params' doc comments in
// ControlParams.swift (Swift can't read those at run time). A missing entry only loses the text.

extension ProjectNewParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] { ["sampleRate": "Session rate in Hz. Default 48000"] }
}

extension ProjectOpenParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["path": "The Name.dawproject folder", "recover": "Open the autosave instead if it is newer (MODEL-045). Default false",
         "safeMode": "PLUG-021: host-bypass every AU/VST3 slot for this session; the document is unchanged. Default false"]
    }
}

extension ProjectSaveParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] { ["path": "Default: where the project was opened from or last saved"] }
}

extension ProjectGetParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["path": "RFC 6901 JSON Pointer into the project JSON, e.g. /tracks/0/name. Default: everything"]
    }
}

extension CommandApplyParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["command": "{\"type\": …, …fields}; daw_command_schema lists the types and their fields"]
    }
}

extension CommandBatchParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        [
            "commands": "Commands as for command.apply, applied in order",
            "atomic": "True: all or nothing, one undo entry. False (default): one undo entry each, stopping at the first failure",
        ]
    }
}

extension CommandSchemaParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] { ["type": "Just this command type. Default: all"] }
}

extension TransportWaitParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["untilTick": "Wait until the playhead is at or past this tick. Default: until playback stops"]
    }
}

extension TransportLocateParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] { ["tick": "960 ticks per quarter note"] }
}

extension TransportSetMetronomeParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        [
            "enabled": "Click while playing. Left out: unchanged",
            "level": "Linear amplitude of a beat click, 0…3.98 (+12 dB); default 0.25 (−12 dBFS). Left out: unchanged",
            "accent": "Linear gain of the downbeat over level, 0…3.98; default 2 (+6 dB). Left out: unchanged",
        ]
    }
}

extension AssetImportParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] { ["path": "Audio file; relative paths resolve against the server's working directory"] }
}

extension RenderOfflineParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        [
            "from": "Start tick (960 per quarter note)",
            "to": "End tick, exclusive",
            "path": "Output file; relative paths resolve against the server's working directory",
            "format": "Default wav",
            "sampleFormat": "Default float32; int24/int16 are TPDF-dithered unless dither is false (IO-035)",
            "tail": "Keep rendering past `to` until the output is quiet (IO-012). Default true",
            "blockSize": "1…4096. Default 512",
            "loop": "Follow the transport's loop: render the range's length of playback from `from`, wrapping at the loop end. Default false (straight through, loop off)",
            "includeMetronome": "Include the project metronome's click (when it is on, transport.setMetronome). Default false: exports leave the click out",
            "dither": "TPDF dither for int16/int24 (IO-035). Default true for those; ignored for float32",
        ]
    }
}

extension RenderCancelParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["id": "The render.offline request's JSON-RPC id (as in its progress notifications). Default: the running render"]
    }
}

extension EngineMetersParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["nodes": "Model IDs of tracks, buses, the master or compressor device slots. Default: every strip, then every built-in compressor"]
    }
}

extension EnginePreviewNoteParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        [
            "track": "A MIDI track with an instrument",
            "pitch": "MIDI note 0…127",
            "velocity": "1…127. Default 100",
            "durationMs": "How long the note is held, 1…60000. Default 500; the call returns at once",
        ]
    }
}

extension AudioAnalyzeParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        [
            "range": "File frames [start, end). Default: all",
            "fftSize": "Power of two, 64…65536. Default 4096",
            "bands": "Log-spaced spectrum bands from 20 Hz to Nyquist. Default 32",
            "silenceThresholdDb": "A sample counts as sound above this level. Default -120 dBFS",
        ]
    }
}

extension AudioCompareParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        [
            "toleranceDb": "pass = nullResidualDb ≤ toleranceDb. Default -100 (TEST-002)",
            "maxOffset": "The cross-correlation searches offsets up to this many frames. Default: one second",
        ]
    }
}

extension EngineEventsParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["since": "Only events with a larger seq; pass the previous result's next. Default 0"]
    }
}

extension TestFixtureParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["name": "<name>.jsonl in the fixture folders (Tests/GoldenTests/fixtures); letters, digits, _ and -"]
    }
}

extension EngineParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        [
            "mode": "offline (default, deterministic) or realtime (a device driver renders; needed for device.*, transport.wait)",
            "driver": "Realtime only. Default fake (made-up devices driven by device.simulate); coreAudio plays through real hardware",
            "outputDevice": "Realtime only: a device id from device.list. Default 0, the default output",
            "bufferFrames": "Realtime only, 32…2048. Default 256",
        ]
    }
}

extension DeviceSetParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        [
            "outputDevice": "A device id from device.list. Default 0, the default output",
            "inputDevice": "Default 0, the default input",
            "sampleRate": "Default 0: keep the session rate if the device runs it; another rate becomes the session rate (DW-079)",
            "bufferFrames": "32…2048. Default: unchanged",
        ]
    }
}

extension MidiInjectParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["events": "In order. Each: {status: 0x80…0xEF, data1?, data2?, sample? (transport sample it is struck at), framesFromNow?, source? (T-093: a CoreMIDI unique ID it arrives from, for tracks' MIDI input filters; left out, only tracks hearing all sources get it)}"]
    }
}

extension DeviceSimulateParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        [
            "kind": "Fake driver only. deviceLost: the device goes away (the engine falls back to the default, D-26)",
            "deviceID": "Default 0: the running device",
            "sampleRate": "sampleRateChanged: a rate the device supports",
        ]
    }
}

extension UIPerformParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        [
            "accessibilityId": "A control id from ui.state (windows[].controls), e.g. track.<id>.mute",
            "action": "click|press (buttons, toggles), toggle|on|off (toggles); swipe: a take row, with start and end; setText: a text field (transport.tempo, transport.signature), with text; drop: a browser item (browser.item.<id>), with tick and optional track",
            "start": "UI-016, action swipe: first tick of the range the take plays (clamped to the take and its folder)",
            "end": "UI-016, action swipe: tick after the range",
            "text": "DW-297, action setText: what to type into the field (committed as with Return), e.g. \"128\" or \"7/8\"",
            "track": "UI-063, action drop on a browser item (browser.item.<id>): the track ID to drop it on; absent: the empty area under the tracks (a new track)",
            "tick": "UI-063, action drop: where the clip starts, snapped to the arrange grid as a drop is (set snap.off for an exact tick)",
        ]
    }
}

// T-098 (DW-016, DW-289)

extension PluginsScanParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["timeoutSeconds": "Each plugin's scan time limit in seconds (default 30; a plugin over it is blocked). Headless and attach mode (DW-299)"]
    }
}

extension PluginsRetryParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["id": "A blocked plugin's identifier from plugins.blocked. Default: every blocked plugin",
         "timeoutSeconds": "The retried scans' limit in seconds. Default 120 when a retried plugin timed out, else 30"]
    }
}

extension PluginsUnblockParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["id": "A blocked plugin's identifier from plugins.blocked. Default: every blocked plugin"]
    }
}

extension EngineParamDisplayParams: JSONSchemaDocumented {
    public static var jsonSchemaDocs: [String: String] {
        ["node": "The device slot's model ID (engine.pluginInfo's slot)",
         "param": "The param's index in engine.pluginInfo's params",
         "value": "VST3: normalized 0…1; AU: in the param's min…max. Default: its current value"]
    }
}
