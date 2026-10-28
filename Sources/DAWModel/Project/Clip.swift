/// A clip on a track's timeline. Positions are ticks (D-06).
public enum Clip: Hashable, Sendable {
    case audio(AudioClip)
    case midi(MidiClip)

    public var id: ModelID {
        switch self {
        case .audio(let clip): clip.id
        case .midi(let clip): clip.id
        }
    }

    public var start: Tick {
        get {
            switch self {
            case .audio(let clip): clip.start
            case .midi(let clip): clip.start
            }
        }
        set {
            switch self {
            case .audio(var clip):
                clip.start = newValue
                self = .audio(clip)
            case .midi(var clip):
                clip.start = newValue
                self = .midi(clip)
            }
        }
    }

    public var length: Tick {
        switch self {
        case .audio(let clip): clip.length
        case .midi(let clip): clip.length
        }
    }
}

// JSON: the clip's own fields plus "kind": "audio" | "midi".
extension Clip: Codable {
    private enum CodingKeys: String, CodingKey { case kind }
    private enum Kind: String, Codable { case audio, midi }

    public init(from decoder: any Decoder) throws {
        switch try decoder.container(keyedBy: CodingKeys.self).decode(Kind.self, forKey: .kind) {
        case .audio: self = .audio(try AudioClip(from: decoder))
        case .midi: self = .midi(try MidiClip(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .audio(let clip):
            try c.encode(Kind.audio, forKey: .kind)
            try clip.encode(to: encoder)
        case .midi(let clip):
            try c.encode(Kind.midi, forKey: .kind)
            try clip.encode(to: encoder)
        }
    }
}
