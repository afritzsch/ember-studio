import Darwin
import Foundation
import os

/// CTL-030: serves the control protocol on a Unix domain socket: newline-delimited JSON-RPC
/// (CTL-001), one response line per request, `progress` notifications before the response of a
/// long request (CTL-031). The app runs one in attach mode; `dawctl serve` runs one headless.
///
/// - Local only: a Unix socket, created 0600 (umask while binding, then chmod), and every peer is
///   checked with `getpeereid` to be this user.
/// - Stale sockets are unlinked on start (CTL-032); a path where another server still answers, or
///   that isn't a socket, is refused instead.
/// - Requests are handled on the main actor (CTL-031), in order per connection; the `Dispatcher`
///   serializes connections against each other.
@MainActor
public final class ControlSocketServer {
    /// One request line in; the response line out (nil for a notification). `notify` writes a
    /// notification to the same connection.
    public typealias Handler = @MainActor (_ line: String, _ notify: @escaping @MainActor (RPCRequest) -> Void) async -> String?

    public let path: String
    private let handler: Handler
    private var listener: SocketListener?
    private var connections: [ObjectIdentifier: SocketConnection] = [:]

    private static let log = Logger(subsystem: "dev.emberstudio", category: "control")

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public convenience init(path: String, dispatcher: Dispatcher) {
        self.init(path: path) { line, notify in await dispatcher.handle(line: line, notify: notify) }
    }

    public var isListening: Bool { listener != nil }

    /// Binds and starts accepting. Throws `attachFailed` with the reason.
    public func start() throws(ControlError) {
        guard listener == nil else { return }
        let listener = try SocketListener(path: path)
        listener.onAccept = { [weak self] connection in
            Task { @MainActor in await self?.serve(connection) }
        }
        listener.resume()
        self.listener = listener
        Self.log.info("control socket listening at \(self.path, privacy: .public)")
    }

    /// Stops accepting, closes every connection and removes the socket file.
    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }

    private func serve(_ connection: SocketConnection) async {
        guard listener != nil else {
            connection.close()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        for await line in connection.lines where !line.allSatisfy(\.isWhitespace) {
            let response = await handler(line) { notification in connection.send(notification.line()) }
            if let response { connection.send(response) }
        }
        connection.close()
        connections[key] = nil
    }
}

extension RPCRequest {
    /// One line of newline-delimited JSON, without the newline.
    public func line() -> String {
        (try? JSONValue.makeEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

// MARK: Sockets

/// What failed, with errno.
func posixFailure(_ what: String, _ path: String) -> ControlError {
    .attachFailed("\(what) \(path): \(String(cString: strerror(errno)))")
}

/// A `sockaddr_un` for `path`, or nil if it doesn't fit.
func unixAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard !bytes.isEmpty, bytes.count <= ControlSocketPath.maxLength else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

/// The listening socket. Accepts on its own queue and hands connections to `onAccept`.
final class SocketListener: @unchecked Sendable {
    let path: String
    var onAccept: (@Sendable (SocketConnection) -> Void)?
    private let fd: Int32
    private let source: DispatchSourceRead
    /// The socket file this listener created, so `cancel` never removes someone else's.
    private let inode: ino_t

    init(path: String) throws(ControlError) {
        guard var address = unixAddress(path) else {
            throw .attachFailed("socket path is longer than \(ControlSocketPath.maxLength) bytes: \(path)")
        }
        try Self.removeStale(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixFailure("cannot create a socket for", path) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // CTL-030: 0600 from the moment the file exists.
        let mask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(mask)
        guard bound == 0 else {
            let error = posixFailure("cannot bind", path)
            Darwin.close(fd)
            throw error
        }
        var info = stat()
        guard chmod(path, 0o600) == 0, lstat(path, &info) == 0, listen(fd, 16) == 0 else {
            let error = posixFailure("cannot listen at", path)
            Darwin.close(fd)
            unlink(path)
            throw error
        }
        self.path = path
        self.fd = fd
        self.inode = info.st_ino
        self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "dev.emberstudio.control.accept"))
        source.setEventHandler { [unowned self] in self.acceptOne() }
        source.setCancelHandler { Darwin.close(fd) }
    }

    func resume() { source.resume() }

    func cancel() {
        source.cancel()
        var info = stat()
        if lstat(path, &info) == 0, info.st_ino == inode { unlink(path) }
    }

    /// CTL-032: a socket nobody answers on is left over from a crashed instance.
    private static func removeStale(_ path: String) throws(ControlError) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else {
            throw .attachFailed("\(path) exists and isn't a socket; not replacing it")
        }
        if ControlSocketClient.isListening(at: path) {
            throw .attachFailed("another instance is already listening at \(path)")
        }
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        // CTL-030: local only, and only this user.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            Darwin.close(client)
            return
        }
        onAccept?(SocketConnection(fd: client))
    }
}

/// One accepted connection: its request lines as a stream, and ordered writes.
final class SocketConnection: @unchecked Sendable {
    /// A longer line closes the connection instead of growing the buffer forever.
    static let maxLineBytes = 64 << 20

    let lines: AsyncStream<String>
    private let fd: Int32
    private let continuation: AsyncStream<String>.Continuation
    private let queue = DispatchQueue(label: "dev.emberstudio.control.connection")
    private let source: DispatchSourceRead
    // Touched on `queue` only.
    private var buffer = Data()
    private var readCancelled = false
    private var closeRequested = false

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        (lines, continuation) = AsyncStream<String>.makeStream()
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in self.readAvailable() }
        // The fd is closed only once the read source has let go of it (DispatchSource rules).
        source.setCancelHandler { [unowned self] in
            self.readCancelled = true
            if self.closeRequested { Darwin.close(fd) }
        }
        source.resume()
    }

    /// Writes `line` and a newline; dropped once the connection is closed.
    func send(_ line: String) {
        queue.async { [self] in
            guard !closeRequested else { return }
            var bytes = Array(line.utf8)
            bytes.append(0x0A)
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return }
                offset += n
            }
        }
    }

    func close() {
        queue.async { [self] in
            guard !closeRequested else { return }
            closeRequested = true
            continuation.finish()
            if readCancelled { Darwin.close(fd) } else { source.cancel() }
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let n = read(fd, &chunk, chunk.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard n > 0 else { return finishReading() }
        buffer.append(contentsOf: chunk[0..<n])
        while let newline = buffer.firstIndex(of: 0x0A) {
            continuation.yield(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > Self.maxLineBytes { finishReading() }
    }

    /// End of input: a last line without a newline still counts.
    private func finishReading() {
        if !buffer.isEmpty, buffer.count <= Self.maxLineBytes {
            continuation.yield(String(decoding: buffer, as: UTF8.self))
        }
        buffer.removeAll()
        continuation.finish()
        source.cancel()
    }
}
