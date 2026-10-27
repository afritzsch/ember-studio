import Foundation

/// Scans one candidate. The production implementation is `ScannerLauncher`.
public protocol PluginScanning: Sendable {
    /// Returns the descriptors to cache for `candidate`, blocked ones included. Throws only when
    /// the scan could not be attempted at all, so nothing should be cached.
    func scan(_ candidate: PluginCandidate) throws(PluginCatalogError) -> [PluginDescriptor]
}

/// PLUG-001: runs the `PluginScanner` executable once per candidate and turns a crash, a timeout
/// or unusable output into a `blocked` descriptor with a reason.
public struct ScannerLauncher: PluginScanning {
    /// PLUG-001: a scan that takes longer than this is killed and the plugin blocked.
    public static let defaultTimeout: TimeInterval = 10

    public var executableURL: URL
    public var timeout: TimeInterval

    public init(executableURL: URL, timeout: TimeInterval = ScannerLauncher.defaultTimeout) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    /// Where the scanner sits when shipped next to the calling executable (SwiftPM build
    /// products, `dawctl`) or as an auxiliary executable of the app bundle.
    public static func bundledExecutableURL(in bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(forAuxiliaryExecutable: "PluginScanner") {
            return url
        }
        let sibling = bundle.executableURL?.deletingLastPathComponent().appending(path: "PluginScanner")
        return sibling.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    public func scan(_ candidate: PluginCandidate) throws(PluginCatalogError) -> [PluginDescriptor] {
        let result = try run(arguments: candidate.scannerArguments)
        switch result.termination {
        case .timedOut:
            return [.blocked(candidate, reason: "timed out after \(Self.format(timeout)) s")]
        case .signaled(let signal):
            return [.blocked(candidate, reason: "scanner crashed (\(Self.signalName(signal)))")]
        case .exited(let status) where status != 0:
            return [.blocked(candidate, reason: "scanner exited with status \(status)"
                + Self.detail(result.stderr))]
        case .exited:
            do {
                return try ScannerOutput.decode(result.stdout)
            } catch {
                return [.blocked(candidate, reason: "scanner printed invalid output"
                    + Self.detail(result.stderr))]
            }
        }
    }

    // MARK: Process

    enum Termination: Equatable {
        case exited(Int32)
        case signaled(Int32)
        case timedOut
    }

    struct RunResult {
        var termination: Termination
        var stdout: Data
        var stderr: Data
    }

    /// Output goes to temp files rather than pipes: a plugin that forks a helper could keep a pipe
    /// open after the scanner dies, and a full pipe could stall the scanner (CONV §9: the names
    /// are unique per run).
    func run(arguments: [String]) throws(PluginCatalogError) -> RunResult {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appending(path: "emberstudio-scan-\(UUID().uuidString)", directoryHint: .isDirectory)
        let stdoutURL = scratch.appending(path: "stdout")
        let stderrURL = scratch.appending(path: "stderr")
        defer { try? fileManager.removeItem(at: scratch) }

        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            fileManager.createFile(atPath: stderrURL.path, contents: nil)
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
            process.standardError = try FileHandle(forWritingTo: stderrURL)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
        } catch {
            throw .scannerUnavailable("could not launch \(executableURL.path): \(error.localizedDescription)")
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(process.processIdentifier, SIGKILL)
            finished.wait()
        }

        let termination: Termination =
            if timedOut { .timedOut }
            else if process.terminationReason == .uncaughtSignal { .signaled(process.terminationStatus) }
            else { .exited(process.terminationStatus) }
        return RunResult(
            termination: termination,
            stdout: (try? Data(contentsOf: stdoutURL)) ?? Data(),
            stderr: (try? Data(contentsOf: stderrURL)) ?? Data())
    }

    // MARK: Reasons

    static func signalName(_ signal: Int32) -> String {
        let names: [Int32: String] = [
            SIGSEGV: "SIGSEGV", SIGBUS: "SIGBUS", SIGILL: "SIGILL", SIGABRT: "SIGABRT",
            SIGTRAP: "SIGTRAP", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL", SIGTERM: "SIGTERM",
        ]
        return names[signal] ?? "signal \(signal)"
    }

    /// The last line the scanner wrote to stderr, as context for a reason.
    static func detail(_ stderr: Data) -> String {
        let lastLine = String(decoding: stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return lastLine.isEmpty ? "" : ": " + String(lastLine.prefix(200))
    }

    static func format(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}
