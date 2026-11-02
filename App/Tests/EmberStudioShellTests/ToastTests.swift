import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-004: toasts for engine events, coalescing and expiry (injected clock).

@MainActor
@Suite("Toasts (UI-004)")
struct ToastTests {
    private func center() -> (ToastCenter, TestClock) {
        let clock = TestClock()
        let center = ToastCenter(now: { clock.now })
        center.deviceName = { $0 == 2 ? "Fake Device B" : nil }
        return (center, clock)
    }

    @Test("UI-004: deviceChanged by reason (D-26: lost → fallback; rate change; default moved; available; start failed)")
    func deviceChanged() {
        let (c, _) = center()
        c.handle(EngineEvent(kind: .deviceChanged, device: DeviceChange(
            reason: .deviceLost, previousDeviceID: 1, deviceID: 2, previousSampleRate: 48_000, sampleRate: 44_100)))
        #expect(c.toasts.last?.title == "Audio device lost" && c.toasts.last?.severity == .warning)
        #expect(c.toasts.last?.message.contains("Now using Fake Device B") == true)
        #expect(c.toasts.last?.message.contains("Session rate is now 44.1 kHz") == true)

        c.handle(EngineEvent(kind: .deviceChanged, device: DeviceChange(
            reason: .sampleRateChanged, previousDeviceID: 1, deviceID: 1, previousSampleRate: 48_000, sampleRate: 96_000)))
        #expect(c.toasts.last?.title == "Sample rate changed" && c.toasts.last?.message.contains("48 kHz to 96 kHz") == true)
        c.handle(EngineEvent(kind: .deviceChanged, device: DeviceChange(reason: .defaultOutputChanged, deviceID: 2)))
        #expect(c.toasts.last?.title == "Output device changed" && c.toasts.last?.severity == .info)
        c.handle(EngineEvent(kind: .deviceChanged, device: DeviceChange(reason: .deviceAvailable, deviceID: 7)))
        #expect(c.toasts.last?.message.contains("device 7") == true, "unknown names show the ID")
        c.handle(EngineEvent(kind: .deviceChanged, error: .engine(code: .io, detail: "no device"),
                             device: DeviceChange(reason: .startFailed)))
        #expect(c.toasts.last?.title == "No audio device running" && c.toasts.last?.severity == .error)
        #expect(c.toasts.allSatisfy { $0.kind == .deviceChanged })
    }

    @Test("UI-004: overloads coalesce into one toast with the running count")
    func overload() {
        let (c, clock) = center()
        c.handle(EngineEvent(kind: .overload, count: 1))
        clock.advance(5)
        c.handle(EngineEvent(kind: .overload, count: 4))
        #expect(c.toasts.count == 1 && c.toasts[0].count == 4 && c.toasts[0].message.contains("4 dropouts"))
        clock.advance(7)
        c.expire()
        #expect(c.toasts.count == 1, "the second overload extended it")
        clock.advance(2)
        c.expire()
        #expect(c.toasts.isEmpty)
    }

    @Test("UI-004: plugin crash, failed asset load, rejected graph, assets not reloaded, recording drops; quiet events stay quiet")
    func otherEvents() {
        let (c, _) = center()
        c.handle([
            EngineEvent(kind: .pluginCrashed, subject: 9),
            EngineEvent(kind: .assetLoadFailed, subject: 3, error: .fileIO(path: "/x.wav", detail: "gone")),
            EngineEvent(kind: .graphRejected, subject: 5, error: .routingCycle(path: [1, 2, 1])),
            EngineEvent(kind: .assetsReloaded),
            EngineEvent(kind: .assetsReloaded, error: .notImplemented("resample on rate change")),
            EngineEvent(kind: .recordingFinalized),
            EngineEvent(kind: .recordingFinalized, error: .engine(code: .io, detail: "dropped 3 blocks")),
            EngineEvent(kind: .assetLoaded, subject: 3),
            EngineEvent(kind: .jobFinished, job: 1),
        ])
        #expect(c.toasts.map(\.kind) == [.pluginCrashed, .assetLoadFailed, .graphRejected, .assetsReloaded, .recordingDropped])
        #expect(c.toasts[0].severity == .error && c.toasts[0].expiresAt == nil, "errors stay until dismissed")
        #expect(c.toasts[1].message.contains("Asset 3"))
    }

    @Test("UI-004: info expires after 4 s, warnings after 8 s; dismiss; capacity drops the oldest")
    func expiry() {
        let (c, clock) = center()
        let info = c.post(.info, .info, title: "i")
        let warning = c.post(.info, .warning, title: "w")
        let error = c.post(.error, .error, title: "e")
        clock.advance(4)
        c.expire()
        #expect(c.toasts.map(\.id) == [warning, error])
        clock.advance(4)
        c.expire()
        #expect(c.toasts.map(\.id) == [error])
        c.dismiss(error)
        #expect(c.toasts.isEmpty && info < warning)
        for n in 0..<(ToastCenter.capacity + 2) { c.post(.info, .info, title: "\(n)") }
        #expect(c.toasts.count == ToastCenter.capacity && c.toasts.first?.title == "2")
    }

    @Test("UI-004, DW-144: recovery available is sticky with a Recover action; the load report becomes toasts")
    func recoveryAndLoadReport() throws {
        let (c, clock) = center()
        var recovered = 0
        let id = c.postRecoveryAvailable(project: "Song") { recovered += 1 }
        clock.advance(3600)
        c.expire()
        #expect(c.toasts.map(\.kind) == [.recoveryAvailable])
        #expect(c.controls.map(\.id) == ["toast.\(id).dismiss", "toast.\(id).action"])
        try #require(c.controls.last).action()
        #expect(recovered == 1 && c.toasts.isEmpty)

        c.post(loadReport: ProjectLoadReport(offlineAssets: [4, 5], repairs: ["clips of track 2 re-sorted"]), project: "Song")
        #expect(c.toasts.map(\.kind) == [.offlineAssets, .repairs])
        #expect(c.toasts[0].title == "2 audio files offline")
        c.post(loadReport: ProjectLoadReport(), project: "Song")
        #expect(c.toasts.count == 2, "a clean report says nothing")
    }
}
