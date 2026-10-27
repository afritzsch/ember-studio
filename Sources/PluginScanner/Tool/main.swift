// PLUG-001: out-of-process plugin scan helper. The app (via PluginCatalog.ScannerLauncher) runs
// it per plugin; if a plugin crashes or hangs, only this process goes down.
//
//   PluginScanner [--vst3 <bundle path>]... [--au <type:subtype:manufacturer>]...
//
// Prints a JSON array of descriptors (10-plugin-hosting Interfaces) to stdout and exits 0.
// Failures the scanner survives become `blocked` entries; usage errors exit 64.
import Foundation
import PluginCatalog

enum Request {
    case vst3(String)
    case au(String)
}

func parseArguments(_ arguments: ArraySlice<String>) -> [Request]? {
    var requests: [Request] = []
    var rest = arguments
    while let flag = rest.popFirst() {
        guard let value = rest.popFirst() else { return nil }
        switch flag {
        case "--vst3": requests.append(.vst3(value))
        case "--au": requests.append(.au(value))
        default: return nil
        }
    }
    return requests.isEmpty ? nil : requests
}

guard let requests = parseArguments(CommandLine.arguments.dropFirst()) else {
    FileHandle.standardError.write(
        Data("usage: PluginScanner [--vst3 <bundle>]... [--au <type:subtype:manufacturer>]...\n".utf8))
    exit(64)
}

let output = StdoutGuard()
var descriptors: [PluginDescriptor] = []
for request in requests {
    switch request {
    case .vst3(let path): descriptors += scanVST3(bundlePath: path)
    case .au(let identifier): descriptors.append(scanAudioUnit(identifier: identifier))
    }
}
do {
    output.write(try ScannerOutput.encode(descriptors))
} catch {
    FileHandle.standardError.write(Data("PluginScanner: could not encode output: \(error)\n".utf8))
    exit(70)
}
exit(0)
