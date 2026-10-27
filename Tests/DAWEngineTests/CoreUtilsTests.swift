import Foundation
import Testing

// T-002: Result, DAW_RT, SpscQueue, AudioBufferPool. The checks are C++ (Sources/DAWEngine/core/
// CoreUtilsSelfTests.cpp), because Swift only sees EngineFacade.h. Each is an `extern "C"`
// function bound here by symbol name; see Sources/DAWEngine/core/SelfTest.h.

@_silgen_name("daw_selftest_result_value_and_error")
private func resultValueAndError(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
@_silgen_name("daw_selftest_result_void")
private func resultVoid(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
@_silgen_name("daw_selftest_result_move_only_and_converting")
private func resultMoveOnly(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
@_silgen_name("daw_selftest_rt_annotation_nonblocking")
private func rtAnnotationNonblocking(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
@_silgen_name("daw_selftest_spsc_fifo_full_empty")
private func spscFifoFullEmpty(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
@_silgen_name("daw_selftest_spsc_wraparound")
private func spscWraparound(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
@_silgen_name("daw_selftest_spsc_bulk")
private func spscBulk(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
@_silgen_name("daw_selftest_spsc_two_threads")
private func spscTwoThreads(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
@_silgen_name("daw_selftest_pool_layout")
private func poolLayout(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
@_silgen_name("daw_selftest_pool_mixed_channel_counts")
private func poolMixedChannelCounts(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
@_silgen_name("daw_selftest_pool_errors_and_empty")
private func poolErrorsAndEmpty(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
@_silgen_name("daw_selftest_pool_move")
private func poolMove(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32

/// Runs one C++ self-test and records its first failure, if any.
private func run(_ test: (UnsafeMutablePointer<CChar>?, Int) -> Int32,
                 sourceLocation: SourceLocation = #_sourceLocation) {
    var buffer = [CChar](repeating: 0, count: 1024)
    let failures = buffer.withUnsafeMutableBufferPointer { test($0.baseAddress, $0.count) }
    let message = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    #expect(failures == 0, "\(failures) failed check(s); first: \(message)",
            sourceLocation: sourceLocation)
}

@Suite("Result (CONV §4)")
struct ResultTests {
    @Test("Result<T> holds a value or an Error") func valueAndError() { run(resultValueAndError) }
    @Test("Result<void>") func voidResult() { run(resultVoid) }
    @Test("Result<T> with move-only and converted values") func moveOnly() { run(resultMoveOnly) }
}

@Suite("ENG-060: SpscQueue")
struct SpscQueueTests {
    @Test("ENG-060: FIFO order, all N slots usable, full and empty rejected")
    func fifoFullEmpty() { run(spscFifoFullEmpty) }
    @Test("ENG-060: indices wrap around storage") func wraparound() { run(spscWraparound) }
    @Test("ENG-060: bulk push/pop are partial, never overwrite") func bulk() { run(spscBulk) }
    @Test("ENG-060: one producer and one consumer thread") func twoThreads() { run(spscTwoThreads) }
}

@Suite("ENG-061: AudioBufferPool")
struct AudioBufferPoolTests {
    @Test("ENG-061: preallocated, zeroed, aligned, disjoint buffers") func layout() { run(poolLayout) }
    @Test("ENG-061: per-buffer channel counts") func mixedChannels() { run(poolMixedChannelCounts) }
    @Test("ENG-061: invalid sizes are errors") func errors() { run(poolErrorsAndEmpty) }
    @Test("ENG-061: moving keeps storage") func move() { run(poolMove) }
}

@Suite("CONV-RT-06: DAW_RT")
struct RtAnnotationTests {
    @Test("CONV-RT-06: DAW_RT is [[clang::nonblocking]]; RT utilities pass the effect check")
    func nonblocking() { run(rtAnnotationNonblocking) }

    /// The engine's warning flags (Package.swift engineCxxSettings) that matter for DAW_RT.
    static let engineFlags = ["-std=c++20", "-Wall", "-Wextra", "-Werror", "-Wfunction-effects"]

    static let coreDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/DAWEngine/core")

    /// Compiles `source` (syntax only) the way DAWEngine would; returns the exit code and stderr.
    static func compile(_ source: String) throws -> (Int32, String) {
        // CONV §9: per-process unique temp path.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-rt06-\(ProcessInfo.processInfo.processIdentifier)-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("probe.cpp")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang++"] + engineFlags + ["-fsyntax-only", "-I", coreDir.path, file.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    @Test("CONV-RT-06: the compiler rejects blocking calls in DAW_RT code")
    func compilerRejectsBlockingCode() throws {
        let (allocates, allocError) = try Self.compile("""
            #include "Realtime.h"
            int* leak() DAW_RT { return new int(1); }
            """)
        #expect(allocates != 0)
        #expect(allocError.contains("nonblocking"), "\(allocError)")

        let (locks, lockError) = try Self.compile("""
            #include <mutex>
            #include "Realtime.h"
            std::mutex m;
            void locked() DAW_RT { std::lock_guard<std::mutex> g(m); }
            """)
        #expect(locks != 0)
        #expect(lockError.contains("nonblocking"), "\(lockError)")

        // Control: the same setup accepts RT-safe code, including the T-002 utilities.
        let (clean, cleanError) = try Self.compile("""
            #include "Realtime.h"
            #include "SpscQueue.h"
            daw::SpscQueue<int, 4> q;
            bool roundTrip() DAW_RT { int x = 0; return q.push(1) && q.pop(x) && x == 1; }
            """)
        #expect(clean == 0, "\(cleanError)")
    }
}
