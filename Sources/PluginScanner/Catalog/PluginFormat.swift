/// Plugin format, encoded with the same values as `PluginDescriptorPOD::format`
/// (10-plugin-hosting Interfaces: au=0, vst3=1).
public enum PluginFormat: UInt8, Codable, Hashable, Sendable {
    case au = 0
    case vst3 = 1
}
