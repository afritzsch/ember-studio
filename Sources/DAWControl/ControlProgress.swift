import Foundation

/// CTL-031: how far a long request (an offline render, an asset load) has got. The dispatcher
/// reports it while the request runs; each transport forwards it its own way:
///
/// - the app socket and `dawctl serve`: a JSON-RPC notification on the same connection, before the
///   response: `{"jsonrpc": "2.0", "method": "progress", "params": {"id": <request id>,
///   "method": "render.offline", "progress": 0.42}}` (only for requests with an `id`);
/// - `dawmcp`: MCP `notifications/progress` when the tool call carries a `progressToken`.
public struct ControlProgress: Hashable, Sendable, Codable {
    /// The control method that is running.
    public var method: String
    /// 0…1.
    public var progress: Double
    public var message: String?

    public init(method: String, progress: Double, message: String? = nil) {
        self.method = method
        self.progress = progress
        self.message = message
    }

    /// The notification's method name on the socket.
    public static let notificationMethod = "progress"

    /// The socket notification for request `id`.
    public func notification(for id: RPCID) -> RPCRequest {
        var params: [String: JSONValue] = [
            "method": .string(method), "progress": .double(progress),
        ]
        params["id"] = try? JSONValue(encoding: id)
        if let message { params["message"] = .string(message) }
        return RPCRequest(id: nil, method: Self.notificationMethod, params: .object(params))
    }

    /// Reads a socket notification back; nil if `request` isn't one.
    public init?(notification request: RPCRequest) {
        guard request.id == nil, request.method == Self.notificationMethod,
              let method = request.params?["method"]?.stringValue,
              let progress = request.params?["progress"]?.doubleValue
        else { return nil }
        self.init(method: method, progress: progress, message: request.params?["message"]?.stringValue)
    }
}

/// Receives progress while a request runs (on the main actor, between the request's awaits).
public typealias ControlProgressHandler = @MainActor (ControlProgress) -> Void
