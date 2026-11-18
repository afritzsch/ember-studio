import CxxStdlib
import DAWEngine
@testable import DAWModel
import Foundation
import Testing

// DW-240 (T-098): `TelemetryPOD` → `EngineTelemetry` is one function (`EngineClient.telemetry(from:)`),
// which `GoldenEngine` calls too. This test catches a field added to `EngineTelemetry` but not
// mapped there: every byte of the POD is set, so every mapped field reads non-zero.
@Suite("Telemetry conversion (DW-240)")
struct EngineTelemetryConversionTests {
    @Test("DW-240: EngineClient.telemetry(from:) maps every EngineTelemetry field from the TelemetryPOD")
    func everyFieldMapped() throws {
        var pod = daw.TelemetryPOD()
        // 0x01 in every byte: each integer is non-zero, each float/double a tiny non-zero value,
        // each bool true.
        withUnsafeMutableBytes(of: &pod) { _ = $0.initializeMemory(as: UInt8.self, repeating: 1) }
        let telemetry = EngineClient.telemetry(from: pod)
        let unmapped = Mirror(reflecting: telemetry).children.filter { child in
            switch child.value {
            case let v as Float: v == 0
            case let v as Double: v == 0
            case let v as Bool: !v
            case let v as UInt64: v == 0
            case let v as UInt32: v == 0
            case let v as Int64: v == 0
            case let v as Int32: v == 0
            case let v as Int: v == 0
            default: true  // a type this test doesn't know yet: extend the switch
            }
        }.map { $0.label ?? "?" }
        #expect(unmapped.isEmpty, "EngineTelemetry fields EngineClient.telemetry(from:) leaves at their default: \(unmapped)")
        #expect(Mirror(reflecting: telemetry).children.count >= 34)  // T-099 added clippedSamples, midiEventsDropped, bufferFrames
    }

    @Test("DW-240: GoldenEngine and EngineClient report the same telemetry fields through the shared conversion")
    func goldenEngineShares() throws {
        let golden = try GoldenEngine(sampleRate: 48_000, testNodes: [])
        let client = try EngineClient(.offline(sampleRate: 48_000))
        let a = golden.telemetry(), b = client.telemetry()
        #expect(a.sampleRate == 48_000 && b.sampleRate == 48_000 && a.rtViolations == 0)
        // Same field set by construction; spot-check a late field both sides carry.
        #expect(a.monitorInput == b.monitorInput && a.armedMidiTracks == b.armedMidiTracks)
    }
}
