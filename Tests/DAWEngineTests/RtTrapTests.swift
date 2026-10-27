// RT safety trap (02-engine-core ENG-030..033). The trap exists only in Debug (BUILD-005), and so
// do these tests. They call daw::RtTrap directly; the deliberate violations and every RtScope live
// in Tests/DAWEngineTestSupport (RtTrapTestSupport.h).
#if DEBUG
import AudioToolbox
import DAWEngineTestSupport
import Darwin
import Testing

private typealias Probe = daw.testing.RtProbe

extension daw.testing.ScopeCounts {
    /// (allocations, deallocations, locks)
    var counts: (UInt64, UInt64, UInt64) { (allocations, deallocations, locks) }
}

/// The process-wide counts by kind (ENG-032: what telemetry reports).
private struct GlobalCounts {
    let allocations = daw.RtTrap.violationCount(.allocation)
    let deallocations = daw.RtTrap.violationCount(.deallocation)
    let locks = daw.RtTrap.violationCount(.lock)

    /// What was counted, by kind, since `start` was taken.
    func since(_ start: GlobalCounts) -> (UInt64, UInt64, UInt64) {
        (allocations - start.allocations, deallocations - start.deallocations, locks - start.locks)
    }
}

/// Kind and symbolized frames of the first violation since the last reset.
private func firstViolation() -> (kind: daw.RtViolationKind, frames: [String])? {
    guard let report = daw.RtTrap.firstViolation().value else { return nil }
    return (report.kind, report.frames.map { String($0) })
}

// The only suite that provokes violations on purpose, and the only one that reads or resets the
// process-wide state (violationCount, firstViolation, resetViolations), so it runs serialized.
// Exact counts come from each RtScope's own count (DW-019), which no other thread can change; the
// process-wide count is asserted only where it is the subject (ENG-032, ENG-033). A later test
// that needs the process-wide state joins this suite by nesting in `extension RtTrapTests`.
@Suite("RT trap (ENG-030..033)", .serialized)
struct RtTrapTests {
    @Test("BUILD-005: the trap is compiled in for the engine, the test support and the Swift importer")
    func compiledInEverywhere() {
        // If DAWEngineTests' -Xcc -DDAW_RT_TRAP=1 went missing, Swift would see the inline Release
        // no-ops in RtTrap.h and every count here would pass as 0.
        #expect(daw.testing.rtTrapCompiledIn())
        #expect(daw.testing.rtTrapCompiledInHeader())
        #expect(daw.RtTrap.install())
        #expect(daw.RtTrap.installed())
    }

    @Test("ENG-030: inRealtimeContext is set only inside RtScope, and scopes nest")
    func realtimeContextFlag() {
        #expect(daw.RtTrap.install())
        #expect(!daw.RtTrap.inRealtimeContext())
        // before: off, outer: on, nested: on, after nested: still on, after outer: off.
        #expect(daw.testing.nestedScopeFlags() == 0b01110)
        #expect(!daw.RtTrap.inRealtimeContext())
    }

    @Test("ENG-031: each allocating or locking probe inside RtScope is counted", arguments: [
        // (probe, allocations, deallocations, locks)
        (Probe.malloc, 1, 1, 0),
        (.calloc, 1, 1, 0),
        (.realloc, 2, 1, 0),  // malloc + realloc, then free
        (.posixMemalign, 1, 1, 0),
        (.newDelete, 1, 1, 0),
        (.pthreadMutex, 0, 0, 1),
        (.stdMutex, 0, 0, 1),
        (.unfairLock, 0, 0, 1),
    ] as [(Probe, UInt64, UInt64, UInt64)])
    fileprivate func countsExactly(probe: Probe, allocations: UInt64, deallocations: UInt64, locks: UInt64) {
        #expect(daw.RtTrap.install())
        let counted = daw.testing.runProbeInScope(probe)
        #expect(counted.ok)
        #expect(counted.counts == (allocations, deallocations, locks))
    }

    @Test("ENG-031: std::vector growth, std::string and std::function inside RtScope are counted",
          arguments: [Probe.vectorGrowth, .string, .function])
    fileprivate func countsContainerAllocations(probe: Probe) {
        #expect(daw.RtTrap.install())
        let counted = daw.testing.runProbeInScope(probe)
        #expect(counted.ok)
        #expect(counted.allocations >= 1)
        #expect(counted.deallocations >= 1)
    }

    @Test("ENG-031: a clean probe inside RtScope counts nothing")
    func cleanCodeCountsNothing() {
        #expect(daw.RtTrap.install())
        daw.RtTrap.resetViolations()
        let counted = daw.testing.runProbeInScope(.clean)
        #expect(counted.ok)
        #expect(counted.counts == (0, 0, 0))
        #expect(firstViolation() == nil)
    }

    @Test("ENG-031: violations on a dedicated RT thread are counted; spawning it isn't")
    func countsOnAnotherThread() {
        #expect(daw.RtTrap.install())
        let global = GlobalCounts()
        let counted = daw.testing.runProbeOnRtThread(.malloc)
        #expect(counted.ok)
        #expect(counted.counts == (1, 1, 0))
        #expect(GlobalCounts().since(global) == (1, 1, 0))
    }

    @Test("ENG-032: the first violation's backtrace is captured and symbolized off-thread")
    func firstViolationBacktrace() throws {
        #expect(daw.RtTrap.install())
        daw.RtTrap.resetViolations()
        #expect(daw.testing.runProbeOnRtThread(.pthreadMutex).ok)
        #expect(daw.testing.runProbeInScope(.malloc).ok)
        #expect(daw.RtTrap.violationCount() == 3)
        let first = try #require(firstViolation())
        #expect(first.kind == .lock, "later violations must not overwrite the first")
        #expect(first.frames.contains { $0.contains("runProbe") },
                "backtrace should reach the offending code:\n\(first.frames.joined(separator: "\n"))")

        daw.RtTrap.resetViolations()
        #expect(firstViolation() == nil, "reset re-arms capture")
        #expect(daw.testing.runProbeInScope(.newDelete).ok)
        #expect(try #require(firstViolation()).kind == .allocation)
    }

    @Test("ENG-032, DW-019: the process-wide count sees every thread; an RtScope sees only its own")
    func scopeCountsAreIsolated() {
        #expect(daw.RtTrap.install())
        let global = GlobalCounts()
        let scopes = daw.testing.cleanScopeBesideViolatingScope(.malloc, 100)
        #expect(scopes.clean.ok && scopes.violating.ok)
        #expect(scopes.clean.counts == (0, 0, 0), "another thread's violations leaked into this scope")
        #expect(scopes.violating.counts == (100, 100, 0))
        #expect(GlobalCounts().since(global) == (100, 100, 0))
    }

    @Test("DW-019: per-thread counts only grow; resetViolations() leaves them alone")
    func resetKeepsThreadCounts() {
        #expect(daw.RtTrap.install())
        // A synchronous test body stays on one thread, so these all read the same thread's count.
        let before = daw.RtTrap.threadViolationCount()
        #expect(daw.testing.runProbeInScope(.newDelete).ok)
        #expect(daw.RtTrap.threadViolationCount() == before + 2)
        #expect(daw.RtTrap.threadViolationCount(.allocation) >= 1)
        daw.RtTrap.resetViolations()
        #expect(daw.RtTrap.violationCount() == 0)
        #expect(daw.RtTrap.threadViolationCount() == before + 2)
    }

    @Test("ENG-032: violations don't abort by default")
    func doesNotAbortByDefault() {
        setenv("DAW_RT_TRAP_ABORT", "0", 1)
        #expect(daw.RtTrap.install())
        var total: (UInt64, UInt64, UInt64) = (0, 0, 0)
        for _ in 0..<10 {
            let counted = daw.testing.runProbeInScope(.malloc)
            #expect(counted.ok)
            total = (total.0 + counted.allocations, total.1 + counted.deallocations, total.2 + counted.locks)
        }
        unsetenv("DAW_RT_TRAP_ABORT")
        #expect(total == (10, 10, 0))
    }

    @Test("ENG-032: DAW_RT_TRAP_ABORT=1 aborts on the first violation")
    func abortsWhenRequested() async {
        await #expect(processExitsWith: .signal(SIGABRT)) {
            setenv("DAW_RT_TRAP_ABORT", "1", 1)
            _ = daw.RtTrap.install()
            _ = daw.testing.runProbeInScope(.malloc)
        }
        await #expect(processExitsWith: .success) {
            setenv("DAW_RT_TRAP_ABORT", "1", 1)
            _ = daw.RtTrap.install()
            _ = daw.testing.runProbe(.malloc)  // outside the scope
        }
    }

    @Test("ENG-033: work outside RtScope isn't counted, on this thread or beside an RT thread")
    func outsideScopeIsAllowed() {
        #expect(daw.RtTrap.install())
        let global = GlobalCounts()
        for raw in 0..<daw.testing.kRtProbeCount {
            let probe = Probe(rawValue: raw)!
            #expect(daw.testing.runProbe(probe), "probe \(raw)")
            let beside = daw.testing.runProbeBesideRtThread(probe)
            #expect(beside.ok, "probe \(raw)")
            #expect(beside.counts == (0, 0, 0), "probe \(raw)")
        }
        #expect(GlobalCounts().since(global) == (0, 0, 0))
        // kRtProbeCount covers every probe: the value after the last one isn't a probe.
        #expect(!daw.testing.runProbe(Probe(rawValue: daw.testing.kRtProbeCount)!))
    }

    @Test("ENG-033: CoreAudio device start/stop outside the render scope isn't counted")
    func coreAudioStartIsAllowed() {
        #expect(daw.RtTrap.install())
        // Process-wide, since CoreAudio works on its own threads too.
        let global = GlobalCounts()
        startAndStopDefaultOutput()
        #expect(GlobalCounts().since(global) == (0, 0, 0))

        // The same work inside the scope is counted, so the scope is what excludes it.
        let scoped = daw.testing.runInRtScope({ _ in startAndStopDefaultOutput() }, nil)
        #expect(scoped.allocations > 0)
    }
}

/// Opens, starts, runs briefly and closes the default output unit with a silent render callback.
/// Machines without an output device fail somewhere along the way; that's fine, the point is
/// that whatever CoreAudio does internally isn't counted.
private func startAndStopDefaultOutput() {
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_DefaultOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0,
        componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else { return }
    var unit: AudioUnit?
    guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return }
    defer { AudioComponentInstanceDispose(unit) }

    var callback = AURenderCallbackStruct(
        inputProc: { _, _, _, _, _, ioData in
            for buffer in UnsafeMutableAudioBufferListPointer(ioData)! {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }, inputProcRefCon: nil)
    AudioUnitSetProperty(
        unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
        UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    guard AudioUnitInitialize(unit) == noErr else { return }
    defer { AudioUnitUninitialize(unit) }
    guard AudioOutputUnitStart(unit) == noErr else { return }
    usleep(50_000)
    AudioOutputUnitStop(unit)
}
#endif
