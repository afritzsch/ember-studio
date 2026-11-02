import Darwin
import Foundation

/// CTL-023 / CTL-011: starts **this checkout's** built app with a control socket and connects to it.
///
/// - The app is `<root>/.build/xcode/Build/Products/Debug/Ember Studio.app`, the derived data path
///   `scripts/test.sh` builds into. It is (re)built with `xcodebuild` when it is missing or older
///   than the sources, unless the caller says not to.
/// - It is launched with `Process` and an argument array, never `open -a` (which could pick another
///   worktree's build) and never through a shell, so the space in "Ember Studio.app" is safe
///   (DW-046).
/// - Arguments: `--control-socket <path> --engine <engine> --parent-pid <this pid>`; the app exits
///   when its parent does, so a killed `dawmcp` leaves no app behind.
/// - A socket that already answers is reused: that app was started by someone else (an earlier
///   `dawmcp`, a person), so `terminate()` leaves it running.
public enum AppLauncher {
    /// What to start: an executable and the arguments that come before the launcher's own.
    public struct Target: Sendable, Hashable {
        public var executable: URL
        public var leadingArguments: [String]
        public var trailingArguments: [String]

        public init(executable: URL, leadingArguments: [String] = [], trailingArguments: [String] = []) {
            self.executable = executable
            self.leadingArguments = leadingArguments
            self.trailingArguments = trailingArguments
        }

        /// The checkout's Debug app. AppKit doesn't restore windows from an earlier session.
        public static func app(checkoutRoot root: URL) -> Target {
            Target(executable: AppLauncher.appExecutable(checkoutRoot: root),
                   trailingArguments: ["-ApplePersistenceIgnoreState", "YES"])
        }

        func arguments(socketPath: String, engine: EngineChoice, parentPID: Int32?) -> [String] {
            var arguments = leadingArguments + ["--control-socket", socketPath, "--engine", engine.rawValue]
            if let parentPID { arguments += ["--parent-pid", String(parentPID)] }
            return arguments + trailingArguments
        }
    }

    public static func appBundle(checkoutRoot root: URL) -> URL {
        root.appending(path: ".build/xcode/Build/Products/Debug/Ember Studio.app", directoryHint: .isDirectory)
    }

    public static func appExecutable(checkoutRoot root: URL) -> URL {
        appBundle(checkoutRoot: root).appending(path: "Contents/MacOS/Ember Studio")
    }

    /// Inputs of the app build; any of them newer than the app's executable makes it stale.
    static let buildInputs = ["App/EmberStudio", "App/EmberStudio.xcodeproj", "App/Info.plist",
                              "App/EmberStudio.entitlements", "Sources", "Package.swift", "Package.resolved"]

    /// True when the app is missing or older than a file it is built from.
    public static func needsBuild(checkoutRoot root: URL) -> Bool {
        guard let built = modificationDate(appExecutable(checkoutRoot: root).path) else { return true }
        for input in buildInputs {
            let url = root.appending(path: input)
            if let date = modificationDate(url.path), date > built { return true }
            guard let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            else { continue }
            for case let file as URL in walker {
                if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date > built
                {
                    return true
                }
            }
        }
        return false
    }

    /// `xcodebuild` into `<root>/.build/xcode` (as `scripts/test.sh`), its output appended to `log`.
    public static func buildApp(checkoutRoot root: URL, log: URL) async throws(ControlError) {
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: log) else { throw .attachFailed("cannot write \(log.path)") }
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild", "-project", "App/EmberStudio.xcodeproj", "-scheme", "EmberStudio",
                             "-configuration", "Debug", "-derivedDataPath", root.appending(path: ".build/xcode").path, "build"]
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let status = try await run(process)
        guard status == 0 else { throw .attachFailed("xcodebuild failed (exit \(status)); see \(log.path)") }
    }

    /// Connects to the app at `socketPath`, launching `target` first unless something already
    /// listens there. `parentPID` (default: this process) is passed as `--parent-pid`; nil lets the
    /// app outlive the caller (`dawctl --launch`).
    public static func attach(
        _ target: Target, socketPath: String, engine: EngineChoice = .fake,
        parentPID: Int32? = ProcessInfo.processInfo.processIdentifier, log: URL? = nil, timeout: Duration = .seconds(60)
    ) async throws(ControlError) -> AttachedApp {
        if ControlSocketClient.isListening(at: socketPath) {
            return AttachedApp(client: try ControlSocketClient(path: socketPath), process: nil)
        }
        guard FileManager.default.isExecutableFile(atPath: target.executable.path) else {
            throw .attachFailed("no app at \(target.executable.path); build it first (scripts/test.sh or daw_session_mode build: true)")
        }
        let process = Process()
        process.executableURL = target.executable
        process.arguments = target.arguments(socketPath: socketPath, engine: engine, parentPID: parentPID)
        process.standardInput = FileHandle.nullDevice
        if let log {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try? FileHandle(forWritingTo: log)
            process.standardOutput = handle ?? FileHandle.nullDevice
            process.standardError = handle ?? FileHandle.nullDevice
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
        } catch {
            throw .attachFailed("cannot launch \(target.executable.path): \(error.localizedDescription)")
        }
        let launched = ProcessBox(process)
        do {
            let client = try await ControlSocketClient.connect(path: socketPath, timeout: timeout) { launched.isRunning }
            return AttachedApp(client: client, process: process)
        } catch {
            AttachedApp.terminate(process)
            throw error
        }
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Runs `process` to the end without blocking the caller's thread.
    private static func run(_ process: Process) async throws(ControlError) -> Int32 {
        let result: Result<Int32, ControlError> = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: .success($0.terminationStatus)) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .failure(.attachFailed("cannot run xcodebuild: \(error.localizedDescription)")))
            }
        }
        return try result.get()
    }
}

/// `Process` is thread-safe for `isRunning`, but not marked Sendable.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
    var isRunning: Bool { process.isRunning }
}

/// An app attach mode is connected to.
public final class AttachedApp: @unchecked Sendable {
    public let client: ControlSocketClient
    /// The app this launcher started; nil when it reused one that was already running.
    public let process: Process?

    init(client: ControlSocketClient, process: Process?) {
        self.client = client
        self.process = process
    }

    public var socketPath: String { client.path }
    /// The launched app's pid (nil when reused).
    public var pid: Int32? { process?.processIdentifier }
    public var launched: Bool { process != nil }

    /// Closes the connection and, if this launcher started the app, stops it: SIGTERM, then
    /// SIGKILL after `grace`. An app that was already running is left alone.
    public func terminate(grace: Duration = .seconds(3)) {
        client.close()
        if let process { Self.terminate(process, grace: grace) }
    }

    static func terminate(_ process: Process, grace: Duration = .seconds(3)) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGTERM)
        let clock = ContinuousClock()
        let deadline = clock.now + grace
        while process.isRunning && clock.now < deadline { usleep(10_000) }
        if process.isRunning {
            kill(pid, SIGKILL)
            process.waitUntilExit()
        }
    }
}

/// `--parent-pid` (CTL-023): the app, or `dawctl serve`, exits when the process that launched it
/// is gone, so a killed `dawmcp` leaves nothing running.
public enum ParentProcessWatch {
    nonisolated(unsafe) private static var source: DispatchSourceProcess?

    /// Calls `onExit` (on the main queue) once `pid` has exited, at once if it already has.
    public static func start(_ pid: Int32, onExit: @escaping @Sendable () -> Void = { exit(0) }) {
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler(handler: onExit)
        watch.resume()
        source = watch
        // Already gone (or never existed): the source would never fire.
        if kill(pid, 0) != 0 && errno == ESRCH { DispatchQueue.main.async(execute: onExit) }
    }
}
