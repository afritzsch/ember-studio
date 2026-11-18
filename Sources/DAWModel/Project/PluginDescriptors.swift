// Placeholders owned by 10-plugin-hosting: just enough to identify a plugin in a DeviceSlot.
// Fields follow `PluginDescriptorPOD` (10 Interfaces); hosting work may extend them.

/// An Audio Unit (v2 or v3).
public struct AUDescriptor: Hashable, Sendable, Codable {
    /// `type:subtype:manufacturer` (PLUG-002).
    public var identifier: String
    public var name: String
    public var vendor: String
    public var version: String

    public init(identifier: String, name: String, vendor: String = "", version: String = "") {
        self.identifier = identifier
        self.name = name
        self.vendor = vendor
        self.version = version
    }
}

/// A VST3 class in a bundle.
public struct VST3Descriptor: Hashable, Sendable, Codable {
    /// `path#classUID`.
    public var identifier: String
    public var name: String
    public var vendor: String
    public var version: String

    public init(identifier: String, name: String, vendor: String = "", version: String = "") {
        self.identifier = identifier
        self.name = name
        self.vendor = vendor
        self.version = version
    }
}

// DW-296 (T-102): `vendor` and `version` are optional in JSON, as `command.schema` describes them
// (and as the memberwise inits default them). A missing key reads "". Encoding is synthesized and
// unchanged, so files stay byte-identical; JSON that has both keys decodes as before.
private enum PluginDescriptorKeys: String, CodingKey { case identifier, name, vendor, version }

extension AUDescriptor {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PluginDescriptorKeys.self)
        self.init(
            identifier: try c.decode(String.self, forKey: .identifier),
            name: try c.decode(String.self, forKey: .name),
            vendor: try c.decodeIfPresent(String.self, forKey: .vendor) ?? "",
            version: try c.decodeIfPresent(String.self, forKey: .version) ?? "")
    }
}

extension VST3Descriptor {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PluginDescriptorKeys.self)
        self.init(
            identifier: try c.decode(String.self, forKey: .identifier),
            name: try c.decode(String.self, forKey: .name),
            vendor: try c.decodeIfPresent(String.self, forKey: .vendor) ?? "",
            version: try c.decodeIfPresent(String.self, forKey: .version) ?? "")
    }
}
