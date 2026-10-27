import DAWEngineTestSupport
import Foundation
import Testing

// T-005: ParamSlotTable and ParamSmoother (ENG-020..023). The ramp math is tested here, calling
// daw::ParamSmoother directly; the table (non-movable) and the RT-trap checks are C++
// (Tests/DAWEngineTestSupport/ParamChecks.cpp).

@Suite("ENG-020: ParamSlotTable allocation")
struct ParamSlotTableTests {
    @Test("ENG-020: 65,536 preallocated slots by default; IDs are stable indices")
    func defaultCapacity() { expectPasses(daw.testing.paramTableDefaultCapacity()) }
    @Test("ENG-020: allocate/free reuse slots and initialize values")
    func allocateFree() { expectPasses(daw.testing.paramTableAllocateFree()) }
    @Test("ENG-020: contiguous ranges, holes reused, fragmentation reported")
    func contiguousRanges() { expectPasses(daw.testing.paramTableContiguousRanges()) }
    @Test("ENG-020: bad ranges and double frees are errors that change nothing")
    func errors() { expectPasses(daw.testing.paramTableErrors()) }
    @Test("ENG-020: concurrent allocate/free from several threads never overlap")
    func concurrent() { expectPasses(daw.testing.paramTableConcurrentAllocate()) }
}

@Suite("ENG-021: ParamSlot reads and writes")
struct ParamSlotTests {
    @Test("ENG-021: relaxed writes are seen by the next read; generation counts writes")
    func readWrite() { expectPasses(daw.testing.paramSlotReadWrite()) }

    @Test("ENG-021: a fader sweep on one thread, read once per block on another")
    func crossThread() {
        #if DEBUG
        // The check also asserts the reader's RtScope count, which needs the trap (BUILD-005).
        #expect(daw.RtTrap.install())
        #endif
        expectPasses(daw.testing.paramSlotCrossThread())
    }
}

@Suite("ENG-022: ParamSmoother per-block linear ramps")
struct ParamSmootherTests {
    /// Renders one block of `smoother` towards `target` and returns the samples.
    static func render(_ smoother: inout daw.ParamSmoother, to target: Float, frames: Int) -> [Float] {
        let ramp = smoother.next(target, UInt32(frames))
        var out = [Float](repeating: .nan, count: frames)
        out.withUnsafeMutableBufferPointer { ramp.fill($0.baseAddress) }
        return out
    }

    @Test("ENG-022: a 0→1 step is an exact linear ramp over one block, for every size 0…4096")
    func stepRampEveryBlockSize() {
        var worstError = 0.0
        var failedSizes: [Int] = []
        for frames in 0...4096 {
            var smoother = daw.ParamSmoother(0)
            let block = Self.render(&smoother, to: 1, frames: frames)
            var ok = block.count == frames
            var previous: Float = 0
            for (i, v) in block.enumerated() {
                // value[i] = (i + 1) / frames; float rounding only (≤ 2 ulps at 1.0).
                let error = abs(Double(v) - Double(i + 1) / Double(frames))
                worstError = max(worstError, error)
                ok = ok && error <= 2.5e-7 && v > previous
                previous = v
            }
            if frames > 0 {
                ok = ok && block.last == 1 // the block ends exactly on the target
                ok = ok && smoother.current() == 1
                // The next block holds the target: the ramp took exactly one block.
                ok = ok && Self.render(&smoother, to: 1, frames: frames).allSatisfy { $0 == 1 }
            } else {
                // ENG-004: a 0-frame block renders nothing and doesn't use up the ramp.
                ok = ok && smoother.current() == 0
            }
            if !ok { failedSizes.append(frames) }
        }
        #expect(failedSizes.isEmpty, "block sizes failing: \(failedSizes.prefix(20))")
        #expect(worstError <= 2.5e-7)
    }

    @Test("ENG-022: power-of-two blocks are bit-exact")
    func powerOfTwoExact() {
        for shift in 0...12 {
            let frames = 1 << shift
            var smoother = daw.ParamSmoother(0)
            let block = Self.render(&smoother, to: 1, frames: frames)
            #expect(block == (0..<frames).map { Float($0 + 1) / Float(frames) }, "frames \(frames)")
        }
    }

    @Test("ENG-022: ramps chain across blocks of random sizes with no jumps")
    func continuityAcrossBlocks() {
        var rng = SystemRandomNumberGenerator()
        var smoother = daw.ParamSmoother(0.5)
        var previousEnd: Float = 0.5
        for _ in 0..<2_000 {
            let frames = Int.random(in: 0...4096, using: &rng)
            let target = Float.random(in: -2...2, using: &rng)
            let ramp = smoother.next(target, UInt32(frames))
            #expect(ramp.start == previousEnd)
            var out = [Float](repeating: .nan, count: frames)
            out.withUnsafeMutableBufferPointer { ramp.fill($0.baseAddress) }
            if frames > 0 {
                #expect(out.last == target)
                // The first sample is one step past the previous block's end, never a jump.
                let step = (target - previousEnd) / Float(frames)
                #expect(abs(out[0] - (previousEnd + step)) <= 1e-6)
                #expect(abs(ramp.at(UInt32(frames / 2)) - out[frames / 2]) == 0)
                previousEnd = target
            }
            #expect(smoother.current() == previousEnd)
        }
    }

    @Test("ENG-022: multiply applies the same ramp as fill (gain stage)")
    func multiplyMatchesFill() {
        for (start, target, frames) in [(0.0, 1.0, 512), (1.0, 1.0, 300), (0.8, -0.3, 4096), (2.0, 0.0, 1)]
            as [(Float, Float, Int)] {
            let ramp = daw.ParamRamp(start: start, target: target, numFrames: UInt32(frames))
            #expect(ramp.isConstant() == (start == target))
            var gains = [Float](repeating: 0, count: frames)
            gains.withUnsafeMutableBufferPointer { ramp.fill($0.baseAddress) }
            let input = (0..<frames).map { Float(sin(Double($0) * 0.01)) }
            var samples = input
            samples.withUnsafeMutableBufferPointer { ramp.multiply($0.baseAddress) }
            #expect(samples == zip(input, gains).map { $0 * $1 })
        }
    }

    @Test("ENG-022: reset jumps without a ramp; an unchanged value gives a constant block")
    func resetAndConstant() {
        var smoother = daw.ParamSmoother()
        #expect(smoother.current() == 0)
        smoother.reset(0.7)
        let held = smoother.next(0.7, 256)
        #expect(held.isConstant())
        #expect(held.step() == 0)
        #expect(Self.render(&smoother, to: 0.7, frames: 256).allSatisfy { $0 == 0.7 })
    }
}

@Suite("ENG-023: param values bypass snapshots")
struct ParamSnapshotIsolationTests {
    @Test("ENG-023: a fader sweep changes only the slot; the node config stays identical")
    func sweepLeavesConfig() { expectPasses(daw.testing.paramWritesLeaveConfigUntouched()) }

    @Test("ENG-022/021: the smoother reads the slot once per block and ramps to it")
    func smootherFollowsSlot() { expectPasses(daw.testing.paramSmootherFollowsSlot()) }

    /// ENG-023: the value path can't reach the snapshot path. The param sources depend on nothing
    /// in the engine beyond the RT annotations and Result, so a write can't publish a graph.
    @Test("ENG-023: param slot sources include no graph, engine or snapshot headers")
    func noSnapshotDependency() throws {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DAWEngine/core")
        let allowed: Set<String> = ["core/ParamSlotTable.h", "core/Realtime.h", "core/Result.h"]
        for file in ["ParamSlotTable.h", "ParamSlotTable.cpp", "ParamSmoother.h"] {
            let source = try String(contentsOf: core.appendingPathComponent(file), encoding: .utf8)
            let engineIncludes = source.split(separator: "\n")
                .filter { $0.hasPrefix("#include \"") }
                .map { $0.dropFirst("#include \"".count).prefix { $0 != "\"" } }
                .map(String.init)
            #expect(!engineIncludes.isEmpty, "\(file): no includes found")
            #expect(Set(engineIncludes).isSubset(of: allowed), "\(file) includes \(engineIncludes)")
        }
    }
}

#if DEBUG
// CONV §5.3: the trap exists only in Debug (BUILD-005). The count is the RtScope's own (DW-019),
// so RtTrapTests provoking violations in parallel can't leak into it.
@Suite("ENG-021/022: param RT paths under the RT trap")
struct ParamRealtimeTests {
    @Test("ENG-021/022: slot reads/writes and smoothing make no RT violations")
    func rtSafe() {
        #expect(daw.RtTrap.install())
        #expect(daw.testing.paramRtViolations() == 0)
    }
}
#endif
