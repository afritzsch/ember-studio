import Foundation

/// Where headless tools look for `test.fixture` scripts (13, *Protocol details*): `$DAWCTL_FIXTURES`
/// (colon-separated), then `Tests/GoldenTests/fixtures` of the checkout the executable was built in
/// (it lives in `<repo>/.build/<config>/`), then of the current directory's checkout.
public enum ControlFixtures {
    public static func defaultDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL? = Bundle.main.executableURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> [URL] {
        var dirs: [URL] = []
        if let env = environment["DAWCTL_FIXTURES"] {
            dirs += env.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        }
        for start in [executable?.resolvingSymlinksInPath(), currentDirectory].compactMap({ $0 }) {
            var dir = start
            while dir.path != "/" {
                if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) {
                    let fixtures = dir.appending(path: "Tests/GoldenTests/fixtures")
                    if !dirs.contains(fixtures) { dirs.append(fixtures) }
                    break
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        return dirs
    }
}
