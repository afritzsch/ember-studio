import Foundation
import DAWEngineTestSupport
import Testing

// T-061: Audio Unit hosting (10 PLUG-010, 012..016, AU halves). The checks are C++
// (Tests/DAWEngineTestSupport/AUPluginChecks.cpp) because they need the Engine/GraphBuilder rig,
// daw.compile, RtScope and the plugin host. Plugins: Apple's AUDelay and AUSampler, and a test-only
// AUv3 registered in-process (FakeAudioUnit.mm: aux input bus, settable latency, MIDI impulses).
// Serialized: the fake's latency knob acts on every live fake in the process.

@Suite("AU hosting (PLUG-010, 012..016)", .serialized)
struct AUPluginTests {
    @Test("PLUG-010: AU identifiers and the auPlugin configJSON parse and round-trip")
    func identifierAndConfig() { expectPasses(daw.testing.auIdentifierAndConfig()) }

    @Test("PLUG-010/015: AUDelay renders an echo 0.25 s later; param slots become render-thread events; 0 RT violations")
    func delayThroughGraph() { expectPasses(daw.testing.auDelayThroughGraph()) }

    @Test("PLUG-010: MIDI reaches the AU at exact frame offsets (fake AU, AUSampler); 0 RT violations")
    func midiFrameOffsets() { expectPasses(daw.testing.auMidiFrameOffsets()) }

    @Test("PLUG-014: the aux input bus is fed from the node's sidechain port, silence without one")
    func sidechain() { expectPasses(daw.testing.auSidechain()) }

    @Test("PLUG-013/MIX-024: an AU latency change (KVO) rebuilds the graph and PDC keeps paths aligned")
    func latencyChange() { expectPasses(daw.testing.auLatencyChange()) }

    @Test("PLUG-016: fullState round trip through the facade, off the RT thread; survives a rate change")
    func stateRoundTrip() { expectPasses(daw.testing.auStateRoundTrip()) }

    @Test("PLUG-010/012: a missing AU renders as absent and is reported; slots keep their AU; parked AUs are adopted")
    func failureAndAdoption() { expectPasses(daw.testing.auFailureAndAdoption()) }
}

// DW-214: destroying AUs right after rendering parameter events. Before the fix this crashed in
// Apple's AUAudioUnitV2Bridge parameter listener (SIGSEGV at 0x331) within ~100 iterations under
// load, taking the whole test process down. The opt-in probe (DAW_AU_STRESS=<iterations>) also
// prints the parameter-tree lag and how many immediate reads are stale.
@Suite("AU teardown (DW-214)", .serialized)
struct AUTeardownStressTests {
    @Test("DW-214: 150 AUDelay/AUSampler instances destroyed right after parameter events; no crash, every bridge released")
    func regression() { expectPasses(daw.testing.auTeardownRegression(150)) }

    @Test("DW-214: V2 AUs initialized and uninitialized on two threads at once (daw.compile vs daw.reclaim); no crash")
    func concurrentLifecycle() { expectPasses(daw.testing.auConcurrentLifecycle(40)) }

    @Test("DW-214 probe (opt-in): parameter-tree lag and a long teardown stress")
    func stress() {
        guard let n = ProcessInfo.processInfo.environment["DAW_AU_STRESS"].flatMap(UInt32.init) else { return }
        let lag = daw.testing.auParamTreeLagMicros(200)
        print("DW-214 tree lag worst µs:", lag)
        let done = daw.testing.auTeardownStress(n, 8)
        print("DW-214 teardown iterations:", done)
        #expect(done == n)
        expectPasses(daw.testing.auTeardownRegression(0))  // waits for the deferred releases
    }
}
