import DAWEngineTestSupport
import Testing

// T-009: OfflineDriver (Sources/DAWEngine/io). The checks are C++
// (Tests/DAWEngineTestSupport/OfflineChecks.cpp) because they own Engines and render graphs of
// DAW_RT test nodes. Every clean render asserts the driver's own RT trap count is 0 (CONV §5.3).

@Suite("IO-010: OfflineDriver")
struct OfflineDriverTests {
    @Test("IO-010: tick range → frames, fixed block size, progress; file and sink match the graph")
    func rendersRange() { expectPasses(daw.testing.offlineRendersRange()) }

    @Test("IO-010: the range follows tempo changes; the file takes the map's rate")
    func tempoMapRange() { expectPasses(daw.testing.offlineTempoMapRange()) }

    @Test("IO-010, TIME-004/008: plays the range through the transport (loop off, timeline reset once), then restores it")
    func followsTransport() { expectPasses(daw.testing.offlineFollowsTransport()) }

    @Test("T-036, TIME-005: followLoop wraps at the loop end mid-block (and through a loop shorter than a block); loop off is bit-identical")
    func followsLoop() { expectPasses(daw.testing.offlineFollowsLoop()) }

    @Test("IO-010: fails and removes the file when the transport doesn't follow ExportSpec.tempo")
    func transportMismatch() { expectPasses(daw.testing.offlineTransportMismatch()) }

    @Test("IO-010: invalid arguments fail before rendering; an empty range writes an empty file")
    func errors() { expectPasses(daw.testing.offlineErrors()) }

    @Test("IO-010: a simple 60 s project renders in < 10 s")
    func performance() {
        let perf = daw.testing.offlinePerformance60s()
        #expect(perf.ok, "\(String(perf.error))")
        #expect(perf.renderSeconds < 10)
        #expect(perf.rtViolations == 0)
        let speed = perf.audioSeconds / perf.renderSeconds
        print("IO-010: rendered \(perf.audioSeconds) s of audio in \(perf.renderSeconds) s (\(speed)× realtime)")
    }
}

@Suite("IO-011: offline determinism")
struct OfflineDeterminismTests {
    @Test("IO-011: two runs give identical bytes (16-bit dithered file, float file, sink)")
    func deterministic() { expectPasses(daw.testing.offlineDeterministic()) }

    @Test("IO-011, TIME-008: two renders on one engine, playback in between, are bit-identical")
    func repeatableOnOneEngine() { expectPasses(daw.testing.offlineRepeatableOnOneEngine()) }
}

@Suite("IO-012: offline tail")
struct OfflineTailTests {
    @Test("IO-012: a decaying tail ends after the output stays below the threshold for the quiet time")
    func quiet() { expectPasses(daw.testing.offlineTailQuiet()) }

    @Test("IO-012: quiet frames count only after the range end; a loud frame restarts the count")
    func quietRunResets() { expectPasses(daw.testing.offlineTailQuietRunResets()) }

    @Test("IO-012: an endless tone stops at the maximum tail length; no tail stops at the range end")
    func maxLength() { expectPasses(daw.testing.offlineTailMaxLength()) }
}

@Suite("IO-013: RT trap offline")
struct OfflineRtTrapTests {
    @Test("IO-013: nodes run inside the RT trap's scope offline; a clean render counts 0")
    func inRtScope() { expectPasses(daw.testing.offlineRunsInRtScope()) }
}

#if DEBUG  // the trap exists only in Debug (BUILD-005)
// Deliberate violations belong to the serialized RtTrapTests suite (14-testing, "C++ unit tests").
extension RtTrapTests {
    @Suite("IO-013: offline render counts violations")
    struct OfflineViolationTests {
        @Test("IO-013: an allocating node rendered offline is counted by the render thread's own count")
        func allocatingNodeCounted() {
            #expect(daw.RtTrap.install())
            let counts = daw.testing.offlineCountsAllocatingNode()
            #expect(counts.ok)
            #expect(counts.blocks > 0)
            // One malloc and one free per block, at least.
            #expect(counts.violations >= 2 * counts.blocks)
            #expect(counts.cleanViolations == 0)
        }
    }
}
#endif
