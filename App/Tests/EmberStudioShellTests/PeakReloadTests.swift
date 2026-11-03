import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-011 + IO-033 (T-056 follow-up): a session-rate pass reports `assetsReloaded` with `reload`
// started / progress per asset / finished. The arrange drops its cached peaks once, on finished.

@MainActor
@Suite("Arrange peaks on a session-rate reload (UI-011, IO-033)")
struct PeakReloadTests {
    @Test("UI-011, IO-033: started and progress keep the peaks; finished (or no reload) drops them all once")
    func reloadInvalidatesOnFinished() throws {
        let (model, engine, asset) = try makeArrange()
        let a = model.arrange
        let clip = try model.addAudioClip(track: 0, start: 0, asset: asset)
        #expect(a.waveformLevel(try model.audio(clip)) == 0)
        let cached = a.peaks.count
        #expect(cached > 0)

        func deliver(_ phase: AssetsReload.Phase?, done: UInt32 = 0) {
            let reload = phase.map { AssetsReload(phase: $0, previousSampleRate: 48_000, sampleRate: 44_100, done: done, total: 1,
                                                  assetID: $0 == .progress ? asset : 0) }
            engine.post(EngineEvent(kind: .assetsReloaded, subject: phase == .progress ? asset : 0, count: UInt64(done), reload: reload))
            model.engineEventsArrived(engine.pollEvents())
        }

        let version = a.peaksVersion
        deliver(.started)
        deliver(.progress, done: 1)
        #expect(a.peaksVersion == version, "started/progress don't redraw")
        #expect(a.peaks.count == cached, "nor drop peaks")

        deliver(.finished, done: 1)
        #expect(a.peaksVersion == version + 1)
        #expect(a.peaks.count == 0, "finished drops every asset's peaks")
        #expect(a.waveformLevel(try model.audio(clip)) == 0, "and they are fetched again")

        // An event without `reload` (older engines, T-051) still counts as finished.
        #expect(a.peaks.count > 0)
        deliver(nil)
        #expect(a.peaksVersion == version + 2 && a.peaks.count == 0)

        // A batch with progress and finished invalidates once.
        _ = a.waveformLevel(try model.audio(clip))
        for phase in [AssetsReload.Phase.started, .progress, .finished] {
            engine.post(EngineEvent(kind: .assetsReloaded, reload: AssetsReload(phase: phase, previousSampleRate: 44_100,
                                                                              sampleRate: 48_000, done: 1, total: 1)))
        }
        model.engineEventsArrived(engine.pollEvents())
        #expect(a.peaksVersion == version + 3 && a.peaks.count == 0)
    }
}
