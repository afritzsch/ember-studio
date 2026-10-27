import Foundation
import PluginCatalog
import Testing

/// A per-test scratch directory under $TMPDIR, removed when the test drops it (CONV §9).
final class TestDirectory: Sendable {
    let url: URL

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "macdaw-plugin-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // $TMPDIR is under /var, a symlink to /private/var. Directory enumeration reports the
        // /private form, so expectations use it too (resolvingSymlinksInPath strips /private).
        let real = try #require(realpath(url.path, nil))
        defer { free(real) }
        self.url = URL(filePath: String(cString: real), directoryHint: .isDirectory)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ component: String) -> URL { url.appending(path: component) }
}

private final class BundleMarker {}

enum Fixtures {
    /// The `PluginScanner` built next to the test bundle (the test target depends on it).
    static var scannerURL: URL {
        Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "PluginScanner")
    }

    static func launcher(timeout: TimeInterval = ScannerLauncher.defaultTimeout) -> ScannerLauncher {
        ScannerLauncher(executableURL: scannerURL, timeout: timeout)
    }

    static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Fixtures/FakeVST3.cpp compiled once per test process. Only pluginterfaces is needed.
    static let fakeVST3Binary: Result<URL, FixtureError> = {
        let sdk = repoRoot.appending(path: "Vendor/vst3sdk").path
        let output = FileManager.default.temporaryDirectory
            .appending(path: "macdaw-fake-vst3-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        let arguments = [
            "clang++", "-std=c++20", "-bundle", "-arch", "arm64", "-w", "-isystem", sdk,
            repoRoot.appending(path: "Tests/PluginScannerTests/Fixtures/FakeVST3.cpp").path,
            "\(sdk)/pluginterfaces/base/funknown.cpp",
            "\(sdk)/pluginterfaces/base/coreiids.cpp",
            "\(sdk)/public.sdk/source/vst/vstinitiids.cpp",
            "-framework", "CoreFoundation", "-o", output.path,
        ]
        do {
            let result = try runTool("/usr/bin/xcrun", arguments)
            guard result.status == 0 else { return .failure(FixtureError(message: result.stderr)) }
            return .success(output)
        } catch {
            return .failure(FixtureError(message: "\(error)"))
        }
    }()

    /// Writes `<name>.vst3` into `directory`, containing the fake binary (or no binary at all for
    /// `withBinary: false`, which makes the module fail to load). See FakeVST3.cpp for how the
    /// name selects its behaviour.
    @discardableResult
    static func makeVST3Bundle(
        named name: String, in directory: URL, version: String = "1.2.3", withBinary: Bool = true
    ) throws -> URL {
        let bundle = directory.appending(path: "\(name).vst3", directoryHint: .isDirectory)
        let macOS = bundle.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleExecutable": name,
            "CFBundleIdentifier": "dev.macdaw.tests.\(name.filter(\.isLetter))",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
        if withBinary {
            try FileManager.default.copyItem(at: fakeVST3Binary.get(), to: macOS.appending(path: name))
        }
        return bundle
    }

    /// An executable shell script, standing in for the scanner in launcher tests.
    static func script(_ body: String, in directory: TestDirectory) throws -> URL {
        let url = directory.path("scanner-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

struct FixtureError: Error, CustomStringConvertible {
    var message: String
    var description: String { "fixture build failed: \(message)" }
}

/// Runs a short-lived tool. Output is small, so reading the pipes one after the other is safe.
func runTool(_ path: String, _ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: String) {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(filePath: path)
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, out, String(decoding: err, as: UTF8.self))
}

extension PluginCandidate {
    static func vst3(_ path: String, mtime: Double = 1, version: String = "1.0") -> PluginCandidate {
        PluginCandidate(format: .vst3, path: path, mtime: mtime, version: version,
                        name: URL(filePath: path).deletingPathExtension().lastPathComponent)
    }
}
