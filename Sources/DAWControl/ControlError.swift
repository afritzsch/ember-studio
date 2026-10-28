import DAWModel
import Foundation

/// Everything a control method can fail with. On the wire it becomes a JSON-RPC error (CTL-003)
/// whose `data` is `{"dawError": <name>, "detail": <text>, …}`:
///
/// | code   | `dawError`                        | when |
/// |--------|-----------------------------------|------|
/// | -32700 | `parseError`                      | the line isn't JSON |
/// | -32600 | `invalidRequest`                  | not a JSON-RPC 2.0 request |
/// | -32601 | `methodNotFound`                  | unknown method |
/// | -32602 | `invalidParams`                   | params don't decode or are out of range |
/// | -32603 | `internalError`                   | a bug |
/// | -32000 | the `DAWError` case (`routingCycle`, `notFound`, …) | the model or engine refused; `data.error` is the DAWError's JSON, and a cycle adds `data.path` |
/// | -32001 | `methodNotAvailableInHeadless`    | an attach-only method in headless mode (CTL-005) |
/// | -32002 | `noProject`                       | the method needs a project; call `project.new` first |
/// | -32003 | `timeout`                         | a job, graph build or `transport.wait` ran out of time |
///
/// `withData` adds context fields to `data` (a batch's failed `index`, a fixture's `line`).
public enum ControlError: Error, Hashable, Sendable {
    case parseError(String)
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)
    case model(DAWError)
    case methodNotAvailableInHeadless(String)
    case noProject
    case timeout(String)
    indirect case withData(ControlError, [String: JSONValue])

    public var code: Int {
        switch self {
        case .withData(let error, _): error.code
        case .parseError: -32700
        case .invalidRequest: -32600
        case .methodNotFound: -32601
        case .invalidParams: -32602
        case .internalError: -32603
        case .model: -32000
        case .methodNotAvailableInHeadless: -32001
        case .noProject: -32002
        case .timeout: -32003
        }
    }

    /// `data.dawError`.
    public var name: String {
        switch self {
        case .withData(let error, _): error.name
        case .parseError: "parseError"
        case .invalidRequest: "invalidRequest"
        case .methodNotFound: "methodNotFound"
        case .invalidParams: "invalidParams"
        case .internalError: "internalError"
        case .model(let error): error.code
        case .methodNotAvailableInHeadless: "methodNotAvailableInHeadless"
        case .noProject: "noProject"
        case .timeout: "timeout"
        }
    }

    /// `data.detail` and the error message.
    public var detail: String {
        switch self {
        case .withData(let error, _): error.detail
        case .parseError(let s), .invalidRequest(let s), .invalidParams(let s), .internalError(let s), .timeout(let s):
            s
        case .methodNotFound(let method): "no method \"\(method)\""
        case .model(let error): error.description
        case .methodNotAvailableInHeadless(let method): "\(method) is only available in attach mode"
        case .noProject: "no project; call project.new first"
        }
    }

    public var rpcError: RPCError {
        if case .withData(let error, let extra) = self {
            var rpc = error.rpcError
            rpc.data = .object((rpc.data?.objectValue ?? [:]).merging(extra) { base, _ in base })
            return rpc
        }
        var data: [String: JSONValue] = ["dawError": .string(name), "detail": .string(detail)]
        if case .model(let error) = self {
            data["error"] = try? JSONValue(encoding: error)
            if case .routingCycle(let path) = error {
                data["path"] = .array(path.map { .int(Int64(bitPattern: $0)) })
            }
        }
        return RPCError(code: code, message: "\(name): \(detail)", data: .object(data))
    }

    /// Any error a handler threw.
    init(_ error: any Error) {
        switch error {
        case let error as ControlError: self = error
        case let error as DAWError: self = .model(error)
        case let error as DecodingError: self = .invalidParams(Self.describe(error))
        default: self = .internalError(String(describing: error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            return keys.isEmpty ? "params" : keys.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            let parent = path(context)
            return "missing \(parent == "params" ? key.stringValue : parent + "." + key.stringValue)"
        case .typeMismatch(let type, let context): return "\(path(context)): expected \(type)"
        case .valueNotFound(let type, let context): return "\(path(context)): expected \(type), got null"
        case .dataCorrupted(let context): return "\(path(context)): \(context.debugDescription)"
        @unknown default: return String(describing: error)
        }
    }
}
