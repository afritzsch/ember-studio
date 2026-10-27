import AudioToolbox

/// PLUG-002: the `type:subtype:manufacturer` identifier of an audio unit. Each field is the
/// four-character code, or `0x` + 8 hex digits when the code isn't printable ASCII or contains
/// `:`, so the string always parses back.
public struct AudioUnitIdentifier: Hashable, Sendable, CustomStringConvertible {
    public var type: OSType
    public var subtype: OSType
    public var manufacturer: OSType

    public init(type: OSType, subtype: OSType, manufacturer: OSType) {
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
    }

    public init(_ description: AudioComponentDescription) {
        self.init(
            type: description.componentType, subtype: description.componentSubType,
            manufacturer: description.componentManufacturer)
    }

    public init?(_ string: String) {
        let fields = string.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
            let type = Self.code(fields[0]), let subtype = Self.code(fields[1]),
            let manufacturer = Self.code(fields[2])
        else { return nil }
        self.init(type: type, subtype: subtype, manufacturer: manufacturer)
    }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: type, componentSubType: subtype, componentManufacturer: manufacturer,
            componentFlags: 0, componentFlagsMask: 0)
    }

    public var description: String {
        [type, subtype, manufacturer].map(Self.string).joined(separator: ":")
    }

    public static func string(_ code: OSType) -> String {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: code >> (24 - 8 * $0)) }
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) && $0 != UInt8(ascii: ":") }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        let hex = String(code, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: 8 - hex.count) + hex
    }

    public static func code(_ field: Substring) -> OSType? {
        if field.count == 10, field.hasPrefix("0x") {
            return OSType(field.dropFirst(2), radix: 16)
        }
        let bytes = Array(field.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { $0 << 8 | OSType($1) }
    }
}
