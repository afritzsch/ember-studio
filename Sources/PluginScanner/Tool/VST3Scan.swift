import Foundation
import PluginCatalog
import PluginScannerVST3

/// PLUG-003: one descriptor per `kVstAudioEffectClass` class in the bundle. A module that fails
/// to load, or a class that fails to instantiate, is reported as blocked.
func scanVST3(bundlePath: String) -> [PluginDescriptor] {
    let probe = daw.scan.probeVST3Module(std.string(bundlePath))
    let bundleVersion = SystemPluginDiscovery.vst3Candidate(bundle: URL(filePath: bundlePath)).version
    let bundleName = URL(filePath: bundlePath).deletingPathExtension().lastPathComponent
    guard probe.loaded else {
        return [PluginDescriptor(
            format: .vst3, identifier: bundlePath, name: bundleName, vendor: "",
            version: bundleVersion, isInstrument: false, hasSidechain: false, numParams: 0,
            status: .blocked, reason: "could not load module: \(String(probe.error))")]
    }
    return probe.classes.map { classProbe in
        let vendor = String(classProbe.vendor)
        let version = String(classProbe.version)
        return PluginDescriptor(
            format: .vst3,
            identifier: "\(bundlePath)#\(String(classProbe.classUID))",
            name: String(classProbe.name),
            vendor: vendor.isEmpty ? String(probe.factoryVendor) : vendor,
            version: version.isEmpty ? bundleVersion : version,
            isInstrument: classProbe.isInstrument,
            hasSidechain: classProbe.hasSidechain,
            numParams: classProbe.numParams,
            status: classProbe.ok ? .ok : .blocked,
            reason: classProbe.ok ? nil : String(classProbe.error))
    }
}
