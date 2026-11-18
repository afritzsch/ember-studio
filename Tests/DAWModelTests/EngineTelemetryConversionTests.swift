import CxxStdlib
import DAWEngine
@testable import DAWModel
import Foundation
import Testing

// DW-240 (T-098): `TelemetryPOD` → `EngineTelemetry` is one function (`EngineClient.telemetry(_:)`),
// which `GoldenEngine` calls too. This test catches a field added to `EngineTelemetry` but not
// mapped there: every byte of the POD is set, so every mapped field reads non-zero.
@Suite("Telemetry conversion (DW-240)")
struct EngineTelemetryConversionTests {
    @Test("DW-240: EngineClient.telemetry(_:) maps every EngineTelemetry field from the TelemetryPOD")
    func everyFieldMapped() throws {
        var pod = daw.TelemetryPOD()
        // 0x01 in every byte: each integer is non-zero, each float/double a tiny non-zero value,
        // each bool true.
        withUnsafeMutableBytes(of: &pod) { $0.initializeMemory(as: UInt8.self, repeating: 1) }
        let telemetry = EngineClient.telemetry(pod)
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
        #expect(unmapped.isEmpty, "EngineTelemetry fields EngineClient.telemetry(_:) leaves at their default: \(unmapped)")
        #expect(Mirror(reflecting: telemetry).children.count >= 31)
    }

    @Test("DW-240: a live engine's telemetry goes through the shared conversion")
    func liveEngine() throws {
        let engine = try EngineClient(.offline(sampleRate: 48_000))
        let telemetry = engine.telemetry()
        #expect(telemetry.sampleRate == 48_000 && telemetry.rtViolations == 0)
    }
}
