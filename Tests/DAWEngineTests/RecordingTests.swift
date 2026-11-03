import DAWEngineTestSupport
import Testing

// T-052 (09 REC-001..005): audio recording in the engine. The checks are C++
// (Tests/DAWEngineTestSupport/RecordingChecks.cpp) because they call the recorder's DAW_RT
// captureBlock in RtScopes and reach the fake driver behind the facade; each asserts 0 RT
// violations (CONV §5.3).

@Suite("Recording (REC-001..005)")
struct RecordingTests {
    @Test("REC-001: a RecordFifo takes a block whole or not at all and holds ≥ 2 s at 96 kHz")
    func fifoKeepsBlocksWhole() { expectPasses(daw.testing.recordFifoKeepsBlocksWhole()) }

    @Test("REC-001, REC-003, REC-004: armed tracks record their input pair while playing and recording; finalize closes float CAFs at startSample = start − latency")
    func capturesArmedPairs() { expectPasses(daw.testing.recorderCapturesArmedPairs()) }

    @Test("REC-005: punch in/out writes only [in, out) of the timeline at any block split; the loop disables it")
    func punchesInAndOut() { expectPasses(daw.testing.recorderPunchesInAndOut()) }

    @Test("REC-002: a stalled writer makes the FIFO drop whole blocks without blocking; drops counted and filled with silence")
    func dropsWhenWriterStalls() { expectPasses(daw.testing.recorderDropsWhenWriterStalls()) }

    @Test("REC-003: loopback through a fake device with known latency: recorded clicks align within ±1 sample")
    func loopbackAligned() { expectPasses(daw.testing.facadeRecordsLoopbackAligned()) }

    @Test("REC-004, IO-021 (2), DW-119: device loss, stop, arm changes and setRecording(false) finalize takes; offline records nothing")
    func finalizesTakes() { expectPasses(daw.testing.facadeFinalizesTakes()) }
}
