import DAWEngineTestSupport
import Testing

// T-019: the TEST-004 test-only nodes (Tests/DAWEngineTestSupport/TestNodes.h) and their
// registration under real kinds, which the golden tests' engine uses (GoldenEngineSupport.h).
// The checks are C++ (TestNodeChecks.cpp) because they call DAW_RT process() inside an RtScope;
// each asserts 0 RT violations (CONV §5.3), except AllocatingNode's, which is in RtTrapTests.

@Suite("Test-only nodes (TEST-004)")
struct TestNodeTests {
    @Test("TEST-004: SineNode is level · sin(2πfn/rate) across odd blocks; reset restarts at phase 0")
    func sine() { expectPasses(daw.testing.testSineNode()) }

    @Test("TEST-004: ImpulseNode fires at first + k · period (once with period 0); reset restarts")
    func impulse() { expectPasses(daw.testing.testImpulseNode()) }

    @Test("TEST-004: FakeLatencyNode(n) delays by n and reports latencySamples() == n")
    func fakeLatency() { expectPasses(daw.testing.testFakeLatencyNode()) }

    @Test("TEST-004: NaNNode writes quiet NaN")
    func nan() { expectPasses(daw.testing.testNaNNode()) }

    @Test("TEST-004: registered under real kinds; clip-ful players stay real; a duplicate kind is rejected")
    func registration() { expectPasses(daw.testing.testNodeRegistration()) }
}

#if DEBUG  // the trap exists only in Debug (BUILD-005)
extension RtTrapTests {
    @Suite("AllocatingNode (TEST-004)")
    struct AllocatingNodeTests {
        @Test("TEST-004: the trap counts AllocatingNode's malloc and free in every block, not in empty ones")
        func countsEveryBlock() {
            #expect(daw.RtTrap.install())
            #expect(daw.testing.allocatingNodeViolations(3) == 6)
        }
    }
}
#endif
