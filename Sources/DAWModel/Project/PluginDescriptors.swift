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
