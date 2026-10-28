import DAWControl
import Foundation
import Testing

// CTL-025: scripts/dawmcp.sh and the .mcp.json entry that runs it. The script runs inside a scratch
// checkout with a stand-in `swift` (which "builds" a fake dawmcp), so the test checks the launcher's
// own logic, never builds this package from inside `swift test`, and works from any worktree path.

private let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// The physical path, as `pwd -P` prints it (Foundation's resolvingSymlinksInPath maps /private/var
/// back to /var).
private func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private struct Run {
    var status: Int32
    var stdout: String
    var stderr: String
}

private func run(_ executable: String, _ arguments: [String], in directory: URL, path: String) throws -> Run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = path
    process.environment = environment
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
               stderr: String(decoding: stderr, as: UTF8.self))
}

/// A scratch checkout: the real launcher, a manifest and a source file, and a `swift` on PATH that
/// logs each build and writes a dawmcp that prints its cwd and arguments.
private struct ScratchCheckout {
    let dir: TempDir
    var root: URL { dir.file("repo") }
    var bin: URL { dir.file("bin") }
    var buildLog: URL { dir.file("builds.log") }
    var path: String { bin.path + ":/usr/bin:/bin" }

    init() throws {
        dir = try TempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "Sources/dawmcp"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.copyItem(at: checkout.appending(path: "scripts/dawmcp.sh"), to: root.appending(path: "scripts/dawmcp.sh"))
        try fm.copyItem(at: checkout.appending(path: ".mcp.json"), to: root.appending(path: ".mcp.json"))
        try "// manifest".write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appending(path: "Package.resolved"), atomically: true, encoding: .utf8)
        try "// source".write(to: root.appending(path: "Sources/dawmcp/DawMCP.swift"), atomically: true, encoding: .utf8)
        let swift = """
            #!/bin/sh
            echo "$PWD $*" >> '\(buildLog.path)'
            echo "fake build output"
            [ -e '\(dir.file("fail").path)' ] && exit 1
            mkdir -p .build/debug
            printf '#!/bin/sh\\necho "server cwd=$PWD args=$*"\\n' > .build/debug/dawmcp
            chmod +x .build/debug/dawmcp
            """
        try swift.write(to: bin.appending(path: "swift"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "swift").path)
    }

    var builds: [String] {
        ((try? String(contentsOf: buildLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func launch(_ arguments: [String] = [], from directory: URL? = nil) throws -> Run {
        try run("/bin/sh", ["-c", #"exec "$0" "$@""#, root.appending(path: "scripts/dawmcp.sh").path] + arguments,
                in: directory ?? dir.url, path: path)
    }

    /// Makes `file` newer than the built binary.
    func touch(_ file: String) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: root.appending(path: file).path)
    }
}

@Suite("dawmcp launcher (CTL-025)")
struct LauncherTests {
    @Test("CTL-025: from any directory, builds the checkout's dawmcp once, then execs it at the checkout root")
    func buildsWhenNeeded() throws {
        let repo = try ScratchCheckout()
        let root = realPath(repo.root)

        // Missing binary: build (output on stderr only), then exec with the arguments.
        let first = try repo.launch(["--fixtures", "x"])
        #expect(first.status == 0, "\(first.stderr)")
        #expect(first.stdout == "server cwd=\(root) args=--fixtures x\n")
        #expect(first.stderr.contains("fake build output"))
        #expect(repo.builds == ["\(root) build --product dawmcp"])

        // Up to date: no build.
        let second = try repo.launch()
        #expect(second.stdout == "server cwd=\(root) args=\n")
        #expect(repo.builds.count == 1)

        // A changed source, manifest or pin: build again.
        for file in ["Sources/dawmcp/DawMCP.swift", "Package.swift", "Package.resolved"] {
            try repo.touch(file)
            #expect(try repo.launch().status == 0)
        }
        #expect(repo.builds.count == 4)

        // --build-only builds if needed and starts nothing.
        try repo.touch("Sources/dawmcp/DawMCP.swift")
        let buildOnly = try repo.launch(["--build-only"])
        #expect(buildOnly.status == 0 && buildOnly.stdout.isEmpty)
        #expect(repo.builds.count == 5)
    }

    @Test("CTL-025: a failed build exits 1 without starting a server or writing to stdout")
    func failedBuild() throws {
        let repo = try ScratchCheckout()
        try "".write(to: repo.dir.file("fail"), atomically: true, encoding: .utf8)
        let result = try repo.launch()
        #expect(result.status == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("build failed"))
    }

    @Test("CTL-025: .mcp.json registers dawmcp through the repo-relative launcher, from any folder of the worktree")
    func mcpJSON() throws {
        let config = try JSONValue(parsing: Data(contentsOf: checkout.appending(path: ".mcp.json")))
        let server = try #require(config["mcpServers"]?["dawmcp"])
        #expect(server["type"] == "stdio")
        let command = try #require(server["command"]?.stringValue)
        let arguments = (server["args"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(arguments.joined(separator: " ").contains("scripts/dawmcp.sh"))
        #expect(!arguments.joined().contains(checkout.path), "no absolute paths")

        // Run the configured command from a subfolder of the scratch checkout (a git repo, as a
        // worktree is): it must find that checkout's launcher.
        let repo = try ScratchCheckout()
        _ = try run("/usr/bin/git", ["init", "-q"], in: repo.root, path: repo.path)
        let sub = repo.root.appending(path: "Sources/dawmcp")
        let commandPath = command.hasPrefix("/") ? command : "/bin/\(command)"
        let result = try run(commandPath, arguments, in: sub, path: repo.path)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout == "server cwd=\(realPath(repo.root)) args=\n")
    }
}
