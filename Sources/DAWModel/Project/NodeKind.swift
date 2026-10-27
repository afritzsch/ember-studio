/// Mirrors `daw::NodeKind` in `GraphDescription.h` (05-mixer-routing-pdc Interfaces): same cases,
/// same names. The model uses it for built-in device slots; GraphDescriptionBuilder (MODEL-020)
/// maps it to the C++ enum.
public enum NodeKind: String, Hashable, Sendable, Codable, CaseIterable {
    case audioClipPlayer, midiClipPlayer, sampler, channelStrip, gain, eq, compressor
    case delay, reverb, metronome, auPlugin, vst3Plugin, master, bus
}
