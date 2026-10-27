import DAWEngineTestSupport
import Foundation
import Testing

// T-002: Result, DAW_RT, SpscQueue, AudioBufferPool. The checks are C++ (Tests/DAWEngineTestSupport/
// CoreUtilsChecks.cpp) because the types are templates or move-only and DAW_RT bodies are only
// checked by the C++ compiler; Swift calls them directly through the test-support module.

/// Records a C++ check function's first failure, if any (Tests/DAWEngineTestSupport/include/Checks.h).
func expectPasses(_ result: daw.testing.CheckResult, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(result.failures == 0,
            "\(result.failures) failed check(s); first: \(String(result.firstFailure))",
            sourceLocation: sourceLocation)
}

@Suite("Result (CONV §4)")
struct ResultTests {
    @Test("Result<T> holds a value or an Error")
    func valueAndError() { expectPasses(daw.testing.resultValueAndError()) }
    @Test("Result<void>") func voidResult() { expectPasses(daw.testing.resultVoid()) }
    @Test("Result<T> with move-only and converted values")
    func moveOnly() { expectPasses(daw.testing.resultMoveOnlyAndConverting()) }
}

@Suite("ENG-060: SpscQueue")
struct SpscQueueTests {
    @Test("ENG-060: FIFO order, all N slots usable, full and empty rejected")
    func fifoFullEmpty() { expectPasses(daw.testing.spscFifoFullEmpty()) }
    @Test("ENG-060: indices wrap around storage")
    func wraparound() { expectPasses(daw.testing.spscWraparound()) }
    @Test("ENG-060: bulk push/pop are partial, never overwrite")
    func bulk() { expectPasses(daw.testing.spscBulk()) }
    @Test("ENG-060: one producer and one consumer thread")
    func twoThreads() { expectPasses(daw.testing.spscTwoThreads()) }
}

@Suite("ENG-061: AudioBufferPool")
struct AudioBufferPoolTests {
    @Test("ENG-061: preallocated, zeroed, aligned, disjoint buffers")
    func layout() { expectPasses(daw.testing.poolLayout()) }
    @Test("ENG-061: per-buffer channel counts")
    func mixedChannels() { expectPasses(daw.testing.poolMixedChannelCounts()) }
    @Test("ENG-061: invalid sizes are errors")
    func errors() { expectPasses(daw.testing.poolErrorsAndEmpty()) }
    @Test("ENG-061: moving keeps storage") func move() { expectPasses(daw.testing.poolMove()) }
}

@Suite("CONV-RT-06: DAW_RT")
struct RtAnnotationTests {
    @Test("CONV-RT-06: DAW_RT is [[clang::nonblocking]]; RT utilities pass the effect check")
    func nonblocking() { expectPasses(daw.testing.rtAnnotationNonblocking()) }

    /// The engine's warning flags (Package.swift engineCxxSettings) that matter for DAW_RT.
    static let engineFlags = ["-std=c++20", "-Wall", "-Wextra", "-Werror", "-Wfunction-effects"]

    /// DW-007: engine headers include each other rooted here ("core/Realtime.h").
    static let engineRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/DAWEngine")

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
        process.arguments = ["clang++"] + engineFlags + ["-fsyntax-only", "-I", engineRoot.path, file.path]
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
            #include "core/Realtime.h"
            int* leak() DAW_RT { return new int(1); }
            """)
        #expect(allocates != 0)
        #expect(allocError.contains("nonblocking"), "\(allocError)")

        let (locks, lockError) = try Self.compile("""
            #include <mutex>
            #include "core/Realtime.h"
            std::mutex m;
            void locked() DAW_RT { std::lock_guard<std::mutex> g(m); }
            """)
        #expect(locks != 0)
        #expect(lockError.contains("nonblocking"), "\(lockError)")

        // Control: the same setup accepts RT-safe code, including the T-002 utilities.
        let (clean, cleanError) = try Self.compile("""
            #include "core/Realtime.h"
            #include "core/SpscQueue.h"
            daw::SpscQueue<int, 4> q;
            bool roundTrip() DAW_RT { int x = 0; return q.push(1) && q.pop(x) && x == 1; }
            """)
        #expect(clean == 0, "\(cleanError)")
    }
}
