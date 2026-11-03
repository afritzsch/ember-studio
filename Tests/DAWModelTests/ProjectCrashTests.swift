import DAWModel
import Darwin
import Foundation
import Synchronization
import Testing

// MODEL-041, MODEL-044/045 with a real crash: ProjectSaveCrashHelper (Tests/ProjectSaveCrashHelper)
// saves or autosaves in its own process and is killed with SIGKILL. The test target depends on
// it, so `swift test` builds it next to the test bundle.

private final class BundleMarker {}

private func helperURL() -> URL {
    Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "ProjectSaveCrashHelper")
}

/// Launches the helper; its stdout lines arrive on `lines`.
private func launchHelper(_ mode: String, folder: URL) throws -> (Process, AsyncStream<String>) {
    let process = Process()
    process.executableURL = helperURL()
    process.arguments = [mode, folder.path]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.standardError
    let (lines, continuation) = AsyncStream<String>.makeStream()
    let buffer = Mutex(Data())
    out.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            continuation.finish()
            return
        }
        let complete: [String] = buffer.withLock { data in
            data.append(chunk)
            var found: [String] = []
            while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                found.append(String(decoding: data[data.startIndex..<newline], as: UTF8.self))
                data.removeSubrange(data.startIndex...newline)
            }
            return found
        }
        for line in complete { continuation.yield(line) }
    }
    try process.run()
    return (process, lines)
}

/// Waits for the line `expected`, failing after `timeout`.
private func waitForLine(_ expected: String, in lines: AsyncStream<String>, timeout: Duration = .seconds(60)) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await line in lines where line == expected { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

private func killAndWait(_ process: Process) {
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
}

@Suite("Persistence under a real crash (MODEL-041, MODEL-045)", .serialized)
@MainActor
struct ProjectCrashTests {
    @Test("MODEL-041: SIGKILL while project.json.tmp is being written leaves a loadable project")
    func killDuringSave() async throws {
        let temp = try TempFolder("crash")
        defer { temp.remove() }
        var killedBeforeRename = 0
        var killedMidWrite = 0
        let runs = 8
        for run in 0..<runs {
            let folder = temp.url.appending(path: "Kill\(run).dawproject")
            let (process, lines) = try launchHelper("save-loop", folder: folder)
            #expect(await waitForLine("ready", in: lines), "the first save completed")
            let full = try Data(contentsOf: folder.appending(path: "project.json")).count

            // Kill between the tmp file's creation and its rename. Even runs aim at the write
            // itself (the file is shorter than a full one), odd runs at any point (mostly fsync).
            // DW-172: the spin runs off the main actor (it never awaits, and on the main actor it
            // held every other @MainActor test in the process for up to 30 s per run). It sends
            // the kill itself, from the same thread, the moment the condition holds, so the kill
            // timing is as tight as before.
            let tmp = folder.appending(path: "project.json.tmp").path
            let pid = process.processIdentifier
            let anyPoint = run % 2 == 1
            await Task.detached {
                let deadline = ContinuousClock.now + .seconds(30)
                var info = stat()
                while ContinuousClock.now < deadline {
                    guard stat(tmp, &info) == 0 else { continue }
                    if anyPoint || (info.st_size > 0 && Int(info.st_size) < full / 2) { break }
                }
                kill(pid, SIGKILL)
            }.value
            process.waitUntilExit()
            #expect(process.terminationReason == .uncaughtSignal)

            var info = stat()
            if stat(tmp, &info) == 0 {
                killedBeforeRename += 1
                if Int(info.st_size) < full { killedMidWrite += 1 }
                print("run \(run): killed with \(info.st_size) of \(full) bytes of project.json.tmp written")
            }
            let store = try await ProjectStore.open(folder, recover: false)
            store.autosavePolicy = nil
            #expect(store.project.name.hasPrefix("gen "))
            #expect(store.project.tracks.count == 200 && store.project.tracks.allSatisfy { $0.clips.count == 60 })
            #expect(store.loadReport.repairs.isEmpty)
        }
        #expect(killedBeforeRename > 0, "at least one kill landed before the rename")
        #expect(killedMidWrite > 0, "at least one kill left a truncated project.json.tmp")
    }

    @Test("MODEL-044/045: after a SIGKILL, the autosaved edit is offered, and opened with recover")
    func recoverAfterCrash() async throws {
        let temp = try TempFolder("crash")
        defer { temp.remove() }
        let folder = temp.url.appending(path: "Crash.dawproject")
        let (process, lines) = try launchHelper("autosave", folder: folder)
        #expect(await waitForLine("autosaved", in: lines))
        killAndWait(process)

        let plain = try await ProjectStore.open(folder, recover: false)
        plain.autosavePolicy = nil
        #expect(plain.project.name == "saved" && plain.project.tracks.isEmpty)
        #expect(plain.loadReport.recoveryAvailable)

        let recovered = try await ProjectStore.open(folder, recover: true)
        recovered.autosavePolicy = nil
        #expect(recovered.loadReport.recovered && recovered.isDirty)
        #expect(recovered.project.tracks.map(\.name) == ["unsaved"])
    }
}
