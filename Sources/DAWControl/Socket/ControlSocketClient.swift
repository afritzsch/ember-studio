import Darwin
import Foundation

/// CTL-011 / CTL-023: the attach-mode side of the app socket. Sends one request at a time and
/// reads lines until its response; `progress` notifications on the way (CTL-031) go to the
/// caller. Used by `dawctl --attach` and `dawmcp`'s attach mode.
public final class ControlSocketClient: @unchecked Sendable {
    public let path: String
    private let fd: Int32
    private let queue = DispatchQueue(label: "dev.emberstudio.control.client")
    // Touched on `queue` only.
    private var buffer = Data()
    private var nextID: Int64 = 1
    private var closed = false

    /// Connects now; `attachFailed` if nothing listens at `path`.
    public init(path: String) throws(ControlError) {
        self.path = path
        fd = try Self.connect(path)
    }

    deinit { if !closed { Darwin.close(fd) } }

    /// True if a server accepts connections at `path` right now.
    public static func isListening(at path: String) -> Bool {
        guard let fd = try? connect(path) else { return false }
        Darwin.close(fd)
        return true
    }

    /// Retries until a server listens at `path` (an app that is still starting), `alive` turns
    /// false, or `timeout` passes.
    public static func connect(
        path: String, timeout: Duration, alive: @Sendable () -> Bool = { true }
    ) async throws(ControlError) -> ControlSocketClient {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            do {
                return try ControlSocketClient(path: path)
            } catch {
                guard alive() else { throw .attachFailed("the app exited before it listened at \(path)") }
                guard clock.now < deadline else { throw .attachFailed("nothing listened at \(path) within \(timeout)") }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Sends `request` and returns its response (nil for a notification, which gets none).
    /// Notifications that arrive first go to `notify`, on the client's queue.
    public func send(
        _ request: RPCRequest, notify: @escaping @Sendable (RPCRequest) -> Void = { _ in }
    ) async throws(ControlError) -> RPCResponse? {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<RPCResponse?, ControlError>, Never>) in
            queue.async { continuation.resume(returning: self.roundTrip(request, notify: notify)) }
        }
        return try result.get()
    }

    /// Like `Dispatcher.call`: the result, or the error the response carried.
    public func call(
        _ method: String, _ params: JSONValue? = nil, progress: (@Sendable (ControlProgress) -> Void)? = nil
    ) async throws(ControlError) -> JSONValue {
        let id = queue.sync { () -> Int64 in
            defer { nextID += 1 }
            return nextID
        }
        let request = RPCRequest(id: .int(id), method: method, params: params)
        let response = try await send(request) { notification in
            if let progress, let update = ControlProgress(notification: notification) { progress(update) }
        }
        guard let response else { throw .internalError("no response to \(method)") }
        if let error = response.error { throw .remote(error) }
        return response.result ?? .null
    }

    public func call(
        _ method: ControlMethod, _ params: JSONValue? = nil, progress: (@Sendable (ControlProgress) -> Void)? = nil
    ) async throws(ControlError) -> JSONValue {
        try await call(method.rawValue, params, progress: progress)
    }

    public func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }

    // MARK: I/O (on `queue`)

    private func roundTrip(_ request: RPCRequest, notify: (RPCRequest) -> Void) -> Result<RPCResponse?, ControlError> {
        guard !closed else { return .failure(.attachFailed("the connection to \(path) is closed")) }
        var bytes = Array(request.line().utf8)
        bytes.append(0x0A)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return .failure(posixFailure("cannot write to", path)) }
            offset += n
        }
        guard let id = request.id else { return .success(nil) }
        while true {
            let line: String
            switch readLine() {
            case .success(let l): line = l
            case .failure(let error): return .failure(error)
            }
            guard let json = try? JSONValue(parsing: Data(line.utf8)) else { continue }
            if json["method"] != nil, let notification = try? RPCRequest(validating: json) {
                notify(notification)
                continue
            }
            guard let response = try? json.decode(RPCResponse.self) else { continue }
            // A response to an earlier request whose caller gave up isn't this one's.
            if response.id == id { return .success(response) }
        }
    }

    private func readLine() -> Result<String, ControlError> {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                return .success(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else {
                return .failure(n == 0 ? .attachFailed("the app closed the connection at \(path)") : posixFailure("cannot read from", path))
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private static func connect(_ path: String) throws(ControlError) -> Int32 {
        guard var address = unixAddress(path) else {
            throw .attachFailed("socket path is longer than \(ControlSocketPath.maxLength) bytes: \(path)")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixFailure("cannot create a socket for", path) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let error = posixFailure("nothing listens at", path)
            Darwin.close(fd)
            throw error
        }
        return fd
    }
}
