import DAWEngineTestSupport
import Testing

// T-011: the device driver (Sources/DAWEngine/io). The checks are C++
// (Tests/DAWEngineTestSupport/DeviceDriverChecks.cpp) because they own Engines, render DAW_RT test
// nodes, use threads and RtScope, and fake os_workgroup. Every RT path runs inside an RtScope that
// must count 0 (CONV §5.3).
//
// Device-independent suites run everywhere. The CoreAudio suite needs a default output device and
// is skipped without one (headless CI) or with DAW_SKIP_DEVICE_TESTS=1.

@Suite("IO-003/004: driver configuration")
struct DriverConfigTests {
    @Test("IO-003: rate (nominal default, fallback, explicit), buffer 32…2048 clamped to the device, channels")
    func resolves() { expectPasses(daw.testing.driverConfigResolves()) }

    @Test("IO-004: a separate input device only when it shares the output's clock")
    func inputChoice() { expectPasses(daw.testing.inputDeviceChoice()) }
}

@Suite("IO-005: device latency")
struct DeviceLatencyTests {
    @Test("IO-005: device + safety offset + buffer + stream; published to telemetry and the transport (DW-049, DW-059)")
    func mathAndPublish() { expectPasses(daw.testing.deviceLatencyMathAndPublish()) }
}

@Suite("IO-001: device IO cycle")
struct DeviceRendererTests {
    @Test("IO-001: cycles render in blocks of at most the buffer size, contiguous, extra channels silent, 0 RT violations")
    func blocks() { expectPasses(daw.testing.deviceRendererBlocks()) }
}

@Suite("IO-004: input FIFO")
struct InputFifoTests {
    @Test("IO-004: order across the wrap, underrun, backlog drop, overflow, channel mismatch")
    func basics() { expectPasses(daw.testing.inputFifoBasics()) }

    @Test("IO-004: producer and consumer threads, every frame in order, 0 RT violations on both")
    func twoThreads() { expectPasses(daw.testing.inputFifoTwoThreads()) }
}

@Suite("IO-002: workgroup join")
struct WorkgroupJoinTests {
    @Test("IO-002: join on the first cycle and on a new IO thread, leave on stop, EALREADY/errors, release, 0 RT violations")
    func bookkeeping() { expectPasses(daw.testing.workgroupBookkeeping()) }
}

/// Prints what a device run saw: the IO-002 acceptance is the os_workgroup result in the test log.
private func log(_ name: String, _ r: daw.testing.DeviceRunReport) {
    print("""
        \(name): device "\(String(r.device))" \(r.sampleRate) Hz, \(r.bufferFrames) frames; \
        \(r.cycles) cycles, \(r.blocks) blocks, \(r.framesProcessed) frames rendered; \
        IO-002 os_workgroup_join returned \(r.joinResult) (\(String(r.workgroupState)), after stop \
        \(String(r.stateAfterStop))); IO-005 latency in \(r.inputLatency) out \(r.outputLatency) \
        samples; rtViolations \(r.rtViolations), xruns \(r.xruns); separate input \(r.separateInput) \
        (FIFO underruns \(r.fifoUnderruns), dropped \(r.fifoDropped))
        """)
}

@Suite("IO-001..005: CoreAudioDriver on a real device", .serialized,
       .enabled(if: daw.testing.hasDefaultOutputDevice(), "no default output device"))
struct CoreAudioDriverTests {
    @Test("IO-001/002/003/005: plays a sine through the default output; workgroup joined; latency published; stop and restart")
    func playsSine() {
        let report = daw.testing.coreAudioPlaysSine()
        if report.skipped { return }
        log("CoreAudioDriver", report)
        expectPasses(report.checks)
    }

    @Test("IO-001/004/005: input from the same device (opt-in: DAW_DEVICE_INPUT_TESTS=1, needs microphone access)")
    func duplexInput() {
        let report = daw.testing.coreAudioDuplexInput()
        if report.skipped { return }
        log("CoreAudioDriver duplex", report)
        expectPasses(report.checks)
    }

    @Test("IO-004/005: default input and output; separate devices on one clock go through the input FIFO (opt-in like the above)")
    func defaultInput() {
        let report = daw.testing.coreAudioDefaultInput()
        if report.skipped { return }
        log("CoreAudioDriver default input", report)
        expectPasses(report.checks)
    }
}
