import DAWModel
import Foundation

// CTL-021, CTL-024: schemas for the wire types the probe can't see through. Tagged unions decide
// their case with a private enum and string enums that aren't CaseIterable don't list their cases,
// so both are stated here. A new tagged union or non-CaseIterable enum in a command or params type
// needs an entry; `SchemaTests` fails for any registered command whose schema is incomplete.
// Every enum value listed here is checked to decode by `SchemaTests`.

extension JSONValue: JSONSchemaDescribing {
    /// Any JSON.
    public static var jsonSchema: JSONValue { [:] }
}

extension AnyCommand: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue {
        [
            "type": "object",
            "required": ["type"],
            "properties": ["type": ["type": "string", "description": "A command type from daw_command_schema"]],
            "description": "A Command {type, …} (MODEL-006)",
        ]
    }

    public static var jsonSchemaExample: JSONValue? {
        ["type": .string(CompositeCommand.type), "label": "", "commands": []]
    }
}

extension OutputTarget: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue {
        JSONSchema.taggedUnion(tag: "kind", [
            ("master", JSONSchema.object([:])),
            ("bus", JSONSchema.object(["id": JSONSchema.of(NodeIDValue.self)])),
        ], description: "Where a track or bus sends its main output")
    }
}

extension ParamTarget: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue {
        JSONSchema.taggedUnion(tag: "kind", [
            ("strip", JSONSchema.object(["channel": JSONSchema.of(NodeIDValue.self), "param": JSONSchema.of(StripParam.self)])),
            ("sendLevel", JSONSchema.object(["send": JSONSchema.of(ModelID.self)])),
            ("device", JSONSchema.object(["slot": JSONSchema.of(NodeIDValue.self), "index": JSONSchema.of(Int.self)])),
        ], description: "A strip control of a track, bus or the master, a send level, or a device param")
    }
}

extension ParamTarget.StripParam: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue {
        JSONSchema.stringEnum(["gain", "pan", "mute", "solo", "phase"],
                              description: "gain: linear 0…+12 dB; pan: −1…1; mute, solo, phase: on at ≥ 0.5")
    }
}

extension SignalTap: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue { JSONSchema.stringEnum(["preFader", "postFader"]) }
}

extension Track.Kind: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue { JSONSchema.stringEnum(["audio", "midi"]) }
}

extension Track.Monitoring: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue { JSONSchema.stringEnum(["off", "auto", "on"]) }
}

extension Clip: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue {
        JSONSchema.taggedUnion(tag: "kind", [
            ("audio", JSONSchema.of(AudioClip.self)),
            ("midi", JSONSchema.of(MidiClip.self)),
        ])
    }
}

extension DeviceSlot.Kind: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue {
        JSONSchema.taggedUnion(tag: "format", [
            ("builtin", JSONSchema.object(["node": JSONSchema.of(NodeKind.self)])),
            ("au", JSONSchema.of(AUDescriptor.self)),
            ("vst3", JSONSchema.of(VST3Descriptor.self)),
        ])
    }
}

extension ExportSpec.FileType: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue { JSONSchema.stringEnum(["wav", "caf", "aiff"]) }
}

extension ExportSpec.SampleFormat: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue { JSONSchema.stringEnum(["float32", "int24", "int16"]) }
}

extension DeviceDriverKind: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue {
        JSONSchema.stringEnum(["fake", "coreAudio"], description: "fake: two made-up devices (1 \"Fake Device A\", 2 \"Fake Device B\", 44.1 kHz only)")
    }
}

extension DeviceEvent.Kind: JSONSchemaDescribing {
    public static var jsonSchema: JSONValue {
        JSONSchema.stringEnum(["deviceLost", "deviceRestored", "sampleRateChanged", "processorOverload"])
    }
}
