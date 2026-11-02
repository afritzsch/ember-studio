import Darwin
import Foundation

/// MODEL-041: crash-safe file replacement. The data goes to `<file>.tmp`, is flushed to the disk
/// (`F_FULLFSYNC`, since plain `fsync` on macOS only reaches the drive's cache), and is renamed
/// over the file. `rename` is atomic, so a process killed at any point leaves either the old file
/// or the new one, never a mix. The folder is synced afterwards so the rename itself is durable.
enum AtomicFile {
    /// Bytes per `write` call, so one call never holds a huge buffer in the kernel.
    static let chunkSize = 64 * 1024

    static func write(_ data: Data, to url: URL) throws(DAWError) {
        let path = url.path
        let tmp = path + ".tmp"
        let fd = Darwin.open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw error(tmp, "cannot create") }
        var failure: DAWError?
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, base + offset, min(buffer.count - offset, chunkSize))
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = error(tmp, "write failed")
                    return
                }
                offset += n
            }
        }
        if failure == nil, !fullSync(fd) { failure = error(tmp, "fsync failed") }
        Darwin.close(fd)
        if let failure {
            unlink(tmp)
            throw failure
        }
        guard Darwin.rename(tmp, path) == 0 else {
            let failure = error(path, "cannot replace with \(tmp)")
            unlink(tmp)
            throw failure
        }
        syncDirectory(url.deletingLastPathComponent())
    }

    /// Copies a file the same way: to a temporary name, flushed, then renamed into place.
    static func copy(_ source: URL, to destination: URL) throws(DAWError) {
        let tmp = destination.deletingLastPathComponent().appending(path: "." + destination.lastPathComponent + ".tmp")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.copyItem(at: source, to: tmp)
        } catch {
            throw .fileIO(path: source.path, detail: "cannot copy to \(destination.path): \(error.localizedDescription)")
        }
        let fd = Darwin.open(tmp.path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 {
            _ = fullSync(fd)
            Darwin.close(fd)
        }
        guard Darwin.rename(tmp.path, destination.path) == 0 else {
            let failure = error(destination.path, "cannot move the copy into place")
            unlink(tmp.path)
            throw failure
        }
        syncDirectory(destination.deletingLastPathComponent())
    }

    private static func fullSync(_ fd: Int32) -> Bool {
        // F_FULLFSYNC isn't supported by every file system; fsync is the fallback.
        fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
    }

    private static func syncDirectory(_ url: URL) {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        Darwin.close(fd)
    }

    private static func error(_ path: String, _ what: String) -> DAWError {
        .fileIO(path: path, detail: "\(what): \(String(cString: strerror(errno)))")
    }
}
