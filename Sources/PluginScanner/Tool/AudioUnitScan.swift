import AVFoundation
import PluginCatalog

/// PLUG-002: instantiates the AU to read its buses and parameters. AUv2 components load into
/// this process; AUv3 extensions load out of process by default, which is fine for a scan.
@MainActor
func scanAudioUnit(identifier: String) -> PluginDescriptor {
    func blocked(_ reason: String, name: String = identifier) -> PluginDescriptor {
        PluginDescriptor(
            format: .au, identifier: identifier, name: name, vendor: "", version: "",
            isInstrument: false, hasSidechain: false, numParams: 0, status: .blocked, reason: reason)
    }
    guard let id = AudioUnitIdentifier(identifier) else {
        return blocked("malformed AU identifier")
    }
    guard let component = AVAudioUnitComponentManager.shared()
        .components(matching: id.componentDescription).first
    else {
        return blocked("component is not registered")
    }

    let audioUnit: AUAudioUnit
    switch instantiate(id.componentDescription) {
    case .success(let unit): audioUnit = unit
    case .failure(let error):
        return blocked("could not instantiate: \(error.localizedDescription)", name: component.name)
    }
    return PluginDescriptor(
        format: .au,
        identifier: identifier,
        name: component.name,
        vendor: component.manufacturerName,
        version: component.versionString,
        isInstrument: id.type == kAudioUnitType_MusicDevice,
        // PLUG-014: an input bus beyond the main one is the sidechain.
        hasSidechain: audioUnit.inputBusses.count > 1,
        numParams: UInt32(audioUnit.parameterTree?.allParameters.count ?? 0))
}

/// `AUAudioUnit.instantiate` completes asynchronously, possibly on the main queue, so the main
/// run loop keeps turning while waiting. The launcher's timeout bounds the wait.
@MainActor
private func instantiate(_ description: AudioComponentDescription) -> Result<AUAudioUnit, Error> {
    final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<AUAudioUnit, Error>?
        func set(_ result: Result<AUAudioUnit, Error>) { lock.withLock { value = result } }
        func get() -> Result<AUAudioUnit, Error>? { lock.withLock { value } }
    }
    let slot = Slot()
    AUAudioUnit.instantiate(with: description, options: []) { unit, error in
        slot.set(unit.map { .success($0) } ?? .failure(error ?? CocoaError(.featureUnsupported)))
    }
    while true {
        if let result = slot.get() { return result }
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
}
