import Foundation

/// One plugin as reported by the scanner: the `PluginDescriptorPOD` fields plus scan status
/// (10-plugin-hosting Interfaces: "Scanner stdout JSON = array of PluginDescriptorPOD fields +
/// {status: ok|blocked, reason?}").
public struct PluginDescriptor: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case ok
        case blocked
    }

    public var format: PluginFormat
    /// AU: `type:subtype:manufacturer` (see `AudioUnitIdentifier`). VST3: `path#classUID`.
    public var identifier: String
    public var name: String
    public var vendor: String
    public var version: String
    public var isInstrument: Bool
    public var hasSidechain: Bool
    public var numParams: UInt32
    public var status: Status
    /// Why the plugin is blocked. Absent when `status == .ok`.
    public var reason: String?

    public init(
        format: PluginFormat, identifier: String, name: String, vendor: String, version: String,
        isInstrument: Bool, hasSidechain: Bool, numParams: UInt32,
        status: Status = .ok, reason: String? = nil
    ) {
        self.format = format
        self.identifier = identifier
        self.name = name
        self.vendor = vendor
        self.version = version
        self.isInstrument = isInstrument
        self.hasSidechain = hasSidechain
        self.numParams = numParams
        self.status = status
        self.reason = reason
    }

    /// PLUG-001: the entry recorded for a candidate the scanner could not report on.
    public static func blocked(_ candidate: PluginCandidate, reason: String) -> PluginDescriptor {
        PluginDescriptor(
            format: candidate.format, identifier: candidate.path, name: candidate.name, vendor: "",
            version: candidate.version, isInstrument: false, hasSidechain: false, numParams: 0,
            status: .blocked, reason: reason)
    }
}

/// The scanner's stdout format, shared by the scanner (encode) and the launcher (decode).
public enum ScannerOutput {
    public static func encode(_ descriptors: [PluginDescriptor]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(descriptors)
    }

    public static func decode(_ data: Data) throws -> [PluginDescriptor] {
        try JSONDecoder().decode([PluginDescriptor].self, from: data)
    }
}
