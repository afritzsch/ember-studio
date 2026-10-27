// RT safety trap (02-engine-core ENG-030..033). The trap exists only in Debug (BUILD-005), and so
// do these tests.
#if DEBUG
import AudioToolbox
import Darwin
import Foundation
import Testing

/// The trap's C entry points (Sources/DAWEngine/core/RtTrap.cpp). Swift can't include engine
/// headers (the module map exposes only EngineFacade.h), so they're resolved with dlsym.
enum RtTrapC {
    enum Kind: Int32 {
        case allocation = 0, deallocation, lock
        static let total: Int32 = -1
    }

    /// Mirrors `Probe` in RtTrap.cpp.
    enum Probe: Int32, CaseIterable {
        case none = 0, malloc, calloc, realloc, posixMemalign, newDelete, vectorGrowth, string,
            function, pthreadMutex, stdMutex, unfairLock
    }

    static func symbol<T>(_ name: String, as type: T.Type) -> T {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {  // RTLD_DEFAULT
            fatalError("RT trap symbol \(name) not linked into the test bundle")
        }
        return unsafeBitCast(address, to: type)
    }

    static var install: @convention(c) () -> Bool {
        symbol("daw_rt_trap_install", as: (@convention(c) () -> Bool).self)
    }
    static var installed: @convention(c) () -> Bool {
        symbol("daw_rt_trap_installed", as: (@convention(c) () -> Bool).self)
    }
    static var inRealtimeContext: @convention(c) () -> Bool {
        symbol("daw_rt_trap_in_realtime_context", as: (@convention(c) () -> Bool).self)
    }
    static var nestedScopeFlags: @convention(c) () -> Int32 {
        symbol("daw_rt_trap_nested_scope_flags", as: (@convention(c) () -> Int32).self)
    }
    static var probeCount: @convention(c) () -> Int32 {
        symbol("daw_rt_trap_probe_count", as: (@convention(c) () -> Int32).self)
    }
    static var violations: @convention(c) (Int32) -> UInt64 {
        symbol("daw_rt_trap_violations", as: (@convention(c) (Int32) -> UInt64).self)
    }
    static var reset: @convention(c) () -> Void {
        symbol("daw_rt_trap_reset", as: (@convention(c) () -> Void).self)
    }
    static var firstViolation:
        @convention(c) (UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int>?) -> Int32
    {
        symbol(
            "daw_rt_trap_first_violation",
            as: (@convention(c) (UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int>?)
                -> Int32).self)
    }
    static var runProbe: @convention(c) (Int32, Bool) -> Bool {
        symbol("daw_rt_trap_run_probe", as: (@convention(c) (Int32, Bool) -> Bool).self)
    }
    static var withScope: @convention(c) (@convention(c) (UnsafeMutableRawPointer?) -> Void, UnsafeMutableRawPointer?) -> Void {
        symbol(
            "daw_rt_trap_with_scope",
            as: (@convention(c) (@convention(c) (UnsafeMutableRawPointer?) -> Void, UnsafeMutableRawPointer?)
                -> Void).self)
    }
    static var runProbeOnRtThread: @convention(c) (Int32) -> Bool {
        symbol("daw_rt_trap_run_probe_on_rt_thread", as: (@convention(c) (Int32) -> Bool).self)
    }
    static var runProbeBesideRtThread: @convention(c) (Int32) -> Bool {
        symbol(
            "daw_rt_trap_run_probe_beside_rt_thread", as: (@convention(c) (Int32) -> Bool).self)
    }

    static func count(_ kind: Kind) -> UInt64 { violations(kind.rawValue) }
    static var total: UInt64 { violations(Kind.total) }

    /// Kind and symbolized frames of the first violation since the last reset.
    static func first() -> (kind: Kind, frames: [String])? {
        var length = 0
        guard firstViolation(nil, 0, &length) >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length + 1)
        let kind = firstViolation(&buffer, buffer.count, nil)
        let text = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return (Kind(rawValue: kind)!, text.split(separator: "\n").map(String.init))
    }

    /// Installs the trap, zeroes the counters, runs `body`, and returns what it counted.
    static func measure(_ body: () -> Void) -> (allocations: UInt64, deallocations: UInt64, locks: UInt64) {
        #expect(install())
        reset()
        body()
        return (count(.allocation), count(.deallocation), count(.lock))
    }
}

// Counters are process-wide, so these run one at a time.
@Suite("RT trap (ENG-030..033)", .serialized)
struct RtTrapTests {
    @Test("ENG-030: inRealtimeContext is set only inside RtScope, and scopes nest")
    func realtimeContextFlag() {
        #expect(RtTrapC.install())
        #expect(!RtTrapC.inRealtimeContext())
        // before: off, outer: on, nested: on, after nested: still on, after outer: off.
        #expect(RtTrapC.nestedScopeFlags() == 0b01110)
        #expect(!RtTrapC.inRealtimeContext())
    }

    @Test("ENG-031: each allocating or locking probe inside RtScope is counted", arguments: [
        // (probe, allocations, deallocations, locks); nil = at least one.
        (RtTrapC.Probe.malloc, 1, 1, 0),
        (.calloc, 1, 1, 0),
        (.realloc, 2, 1, 0),  // malloc + realloc, then free
        (.posixMemalign, 1, 1, 0),
        (.newDelete, 1, 1, 0),
        (.pthreadMutex, 0, 0, 1),
        (.stdMutex, 0, 0, 1),
        (.unfairLock, 0, 0, 1),
    ] as [(RtTrapC.Probe, UInt64, UInt64, UInt64)])
    func countsExactly(probe: RtTrapC.Probe, allocations: UInt64, deallocations: UInt64, locks: UInt64) {
        let counted = RtTrapC.measure { #expect(RtTrapC.runProbe(probe.rawValue, true)) }
        #expect(counted.allocations == allocations)
        #expect(counted.deallocations == deallocations)
        #expect(counted.locks == locks)
    }

    @Test("ENG-031: std::vector growth, std::string and std::function inside RtScope are counted",
          arguments: [RtTrapC.Probe.vectorGrowth, .string, .function])
    func countsContainerAllocations(probe: RtTrapC.Probe) {
        let counted = RtTrapC.measure { #expect(RtTrapC.runProbe(probe.rawValue, true)) }
        #expect(counted.allocations >= 1)
        #expect(counted.deallocations >= 1)
    }

    @Test("ENG-031: a clean probe inside RtScope counts nothing")
    func cleanCodeCountsNothing() {
        let counted = RtTrapC.measure { #expect(RtTrapC.runProbe(RtTrapC.Probe.none.rawValue, true)) }
        #expect(counted == (0, 0, 0))
        #expect(RtTrapC.first() == nil)
    }

    @Test("ENG-031: violations on a dedicated RT thread are counted; spawning it isn't")
    func countsOnAnotherThread() {
        let counted = RtTrapC.measure {
            #expect(RtTrapC.runProbeOnRtThread(RtTrapC.Probe.malloc.rawValue))
        }
        #expect(counted == (1, 1, 0))
    }

    @Test("ENG-032: the first violation's backtrace is captured and symbolized off-thread")
    func firstViolationBacktrace() throws {
        _ = RtTrapC.measure {
            #expect(RtTrapC.runProbeOnRtThread(RtTrapC.Probe.pthreadMutex.rawValue))
            #expect(RtTrapC.runProbe(RtTrapC.Probe.malloc.rawValue, true))
        }
        #expect(RtTrapC.total == 3)
        let first = try #require(RtTrapC.first())
        #expect(first.kind == .lock, "later violations must not overwrite the first")
        #expect(first.frames.contains { $0.contains("runProbe") },
                "backtrace should reach the offending code:\n\(first.frames.joined(separator: "\n"))")

        RtTrapC.reset()
        #expect(RtTrapC.first() == nil, "reset re-arms capture")
        #expect(RtTrapC.runProbe(RtTrapC.Probe.newDelete.rawValue, true))
        #expect(try #require(RtTrapC.first()).kind == .allocation)
    }

    @Test("ENG-032: violations don't abort by default")
    func doesNotAbortByDefault() {
        setenv("DAW_RT_TRAP_ABORT", "0", 1)
        let counted = RtTrapC.measure {
            for _ in 0..<10 { #expect(RtTrapC.runProbe(RtTrapC.Probe.malloc.rawValue, true)) }
        }
        unsetenv("DAW_RT_TRAP_ABORT")
        #expect(counted == (10, 10, 0))
    }

    @Test("ENG-032: DAW_RT_TRAP_ABORT=1 aborts on the first violation")
    func abortsWhenRequested() async {
        await #expect(processExitsWith: .signal(SIGABRT)) {
            setenv("DAW_RT_TRAP_ABORT", "1", 1)
            _ = RtTrapC.install()
            _ = RtTrapC.runProbe(RtTrapC.Probe.malloc.rawValue, true)
        }
        await #expect(processExitsWith: .success) {
            setenv("DAW_RT_TRAP_ABORT", "1", 1)
            _ = RtTrapC.install()
            _ = RtTrapC.runProbe(RtTrapC.Probe.malloc.rawValue, false)  // outside the scope
        }
    }

    @Test("ENG-033: work outside RtScope isn't counted, on this thread or beside an RT thread")
    func outsideScopeIsAllowed() {
        let counted = RtTrapC.measure {
            for probe in RtTrapC.Probe.allCases {
                #expect(RtTrapC.runProbe(probe.rawValue, false))
                #expect(RtTrapC.runProbeBesideRtThread(probe.rawValue))
            }
        }
        #expect(counted == (0, 0, 0))
        #expect(RtTrapC.Probe.allCases.count == Int(RtTrapC.probeCount()))
    }

    @Test("ENG-033: CoreAudio device start/stop outside the render scope isn't counted")
    func coreAudioStartIsAllowed() {
        let counted = RtTrapC.measure { startAndStopDefaultOutput() }
        #expect(counted == (0, 0, 0))

        // The same work inside the scope is counted, so the scope is what excludes it.
        let scoped = RtTrapC.measure { RtTrapC.withScope({ _ in startAndStopDefaultOutput() }, nil) }
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
