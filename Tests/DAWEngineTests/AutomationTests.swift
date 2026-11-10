import DAWEngineTestSupport
import Testing

// T-074: automation (11). The checks are C++ (Tests/DAWEngineTestSupport/AutomationChecks.cpp)
// because they evaluate DAW_RT code inside an RtScope and drive the Engine; every check asserts
// 0 RT violations (CONV §5.3).

@Suite("Automation (AUTO)")
struct AutomationTests {
    @Test("AUTO-004: linear, hold and exponential curves; player cursor; ParamMapping linear/log/db")
    func curves() { expectPasses(daw.testing.automationCurves()) }

    @Test("AUTO-001, AUTO-008: lanes validated and compiled into players, mapped through ParamInfo; off/empty/unowned/non-automatable left out")
    func compile() { expectPasses(daw.testing.automationCompile()) }

    @Test("AUTO-002, AUTO-005: lane values written into slots before nodes run; read overrides SetParam; off ignored; stopped follows the playhead")
    func drivesSlots() { expectPasses(daw.testing.automationDrivesSlots()) }

    @Test("AUTO-003: a loop wrap inside a block jumps at the wrap frame (strip and gain node), no ramp across it")
    func loopWrapJump() { expectPasses(daw.testing.automationLoopWrapJump()) }
}
