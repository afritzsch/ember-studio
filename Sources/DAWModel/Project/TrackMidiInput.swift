/// T-093 (DW-216, REC-011): what a MIDI track hears from the MIDI inputs (docs/autobuild/
/// DECISIONS.md "T-093 model shape"). The default, all sources on every channel, is T-053's
/// routing, so files from before T-093 (which have no `midiInput`) behave as they did.
///
/// JSON: `{"source": "all" | "<CoreMIDI unique ID>", "channel": 0 | 1…16}` (0 = omni).
extension Track {
    public struct MidiInput: Hashable, Sendable, Codable {
        /// A MIDI source, by its CoreMIDI unique ID (`MidiInputInfo.uniqueID`), or all of them. A
        /// source that isn't connected keeps the selection and delivers nothing.
        public enum Source: Hashable, Sendable, Codable, CustomStringConvertible {
            case all
            case device(Int32)

            /// The wire form: "all", or the unique ID in decimal.
            public var description: String {
                switch self {
                case .all: "all"
                case .device(let id): String(id)
                }
            }

            public init?(_ text: String) {
                if text == "all" {
                    self = .all
                } else if let id = Int32(text) {
                    self = .device(id)
                } else {
                    return nil
                }
            }

            public init(from decoder: any Decoder) throws {
                let text = try decoder.singleValueContainer().decode(String.self)
                guard let source = Source(text) else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath,
                        debugDescription: "MIDI input source \"\(text)\" is neither \"all\" nor a CoreMIDI unique ID"))
                }
                self = source
            }

            public func encode(to encoder: any Encoder) throws {
                var c = encoder.singleValueContainer()
                try c.encode(description)
            }
        }

        /// The highest channel; 0 is omni.
        public static let maxChannel: UInt8 = 16
        /// All sources, every channel.
        public static let `default` = MidiInput(source: .all, channel: 0)

        public var source: Source
        /// 0 = omni (every channel), 1…16 one channel. Applies to channel-voice messages; no system
        /// message reaches a track (the engine routes channel voice only).
        public var channel: UInt8

        public init(source: Source = .all, channel: UInt8 = 0) {
            self.source = source
            self.channel = channel
        }

        public var isDefault: Bool { self == .default }

        func validate(_ track: NodeIDValue) throws(DAWError) {
            guard channel <= Self.maxChannel else {
                throw .invariant("MIDI input channel \(channel) of track \(track) is outside 0…\(Self.maxChannel)")
            }
        }
    }
}
