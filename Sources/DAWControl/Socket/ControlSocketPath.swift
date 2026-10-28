import CryptoKit
import Foundation

/// CTL-032: control sockets are per instance, so parallel worktrees never share one
/// (00-conventions §9).
public enum ControlSocketPath {
    /// `sockaddr_un.sun_path` holds 104 bytes with its terminating NUL.
    public static let maxLength = 103

    /// The app's default without `--control-socket` (Debug builds): `$TMPDIR/emberstudio-<pid>.sock`.
    public static func forProcess(_ pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                  temporaryDirectory: String = NSTemporaryDirectory()) -> String {
        place("emberstudio-\(pid).sock", in: temporaryDirectory)
    }

    /// What attach mode (`dawmcp` CTL-023, `dawctl --attach` CTL-011) uses for the checkout at
    /// `root`: `$TMPDIR/emberstudio-<hash of the root path>.sock`. Stable across runs, so a dawctl
    /// call finds the app dawmcp launched for the same worktree.
    public static func forCheckout(_ root: URL, temporaryDirectory: String = NSTemporaryDirectory()) -> String {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return place("emberstudio-\(digest).sock", in: temporaryDirectory)
    }

    /// The checkout (the folder with `Package.swift`) that holds `start`, e.g. a tool's executable
    /// in `<root>/.build/debug/`.
    public static func checkoutRoot(containing start: URL) -> URL? {
        var dir = start.resolvingSymlinksInPath()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The checkout of the running executable, else of the current directory.
    public static func currentCheckoutRoot() -> URL? {
        let starts = [Bundle.main.executableURL,
                      URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)]
        return starts.compactMap { $0 }.lazy.compactMap(checkoutRoot(containing:)).first
    }

    /// `name` in `directory`, or in /tmp when that path wouldn't fit a socket address.
    private static func place(_ name: String, in directory: String) -> String {
        let path = (directory as NSString).appendingPathComponent(name)
        return path.utf8.count <= maxLength ? path : "/tmp/" + name
    }
}
