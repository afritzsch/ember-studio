/// The error type of every throwing DAWModel API (CONV §4: typed `throws(DAWError)` at module
/// boundaries).
///
/// It lives in DAWModel because that is the lowest Swift module: DAWControl, `dawctl`, `dawmcp`
/// and the app all depend on it, and the engine (C++) reports `daw::Result` instead. It is
/// Codable so the control protocol can put it in JSON-RPC error data (CTL-003).
///
/// To add a case: add it here and to `code`. Associated values must stay Codable.
public enum DAWError: Error, Hashable, Sendable, Codable {
    /// A command referenced an ID that doesn't exist (MODEL-031). `kind` is the entity, e.g. "track".
    case notFound(kind: String, id: ModelID)
    /// A command argument is out of range or inconsistent with the project (MODEL-031).
    case invalidArgument(String)
    /// MODEL-030: the edit would close a routing cycle (D-14). `path` is the cycle's node IDs.
    case routingCycle(path: [NodeIDValue])
    /// DW-021: a tempo map (or the session rate it is built at) was rejected.
    case invalidTempoMap(reason: TempoMapError)
    /// MODEL-006: JSON named a command `type` that isn't registered.
    case unknownCommandType(String)
    /// MODEL-006: JSON for a known command didn't decode.
    case malformedCommand(String)
    /// A declared API whose implementation belongs to a later task.
    case notImplemented(String)
    /// DW-076: the engine failed for a reason that isn't the caller's input (file I/O, out of
    /// memory, an internal error). `detail` is the engine's message.
    case engine(code: EngineErrorCode, detail: String)

    /// DW-021
    public init(_ error: TempoMapError) {
        self = .invalidTempoMap(reason: error)
    }

    /// The case name, stable for the wire (CTL-003 `data.dawError`).
    public var code: String {
        switch self {
        case .notFound: "notFound"
        case .invalidArgument: "invalidArgument"
        case .routingCycle: "routingCycle"
        case .invalidTempoMap: "invalidTempoMap"
        case .unknownCommandType: "unknownCommandType"
        case .malformedCommand: "malformedCommand"
        case .notImplemented: "notImplemented"
        case .engine: "engine"
        }
    }
}

/// DW-076: why the engine failed (`DAWError.engine`). Mirrors the `daw::ErrorCode`s that aren't
/// about the caller's arguments.
public enum EngineErrorCode: String, Hashable, Sendable, Codable {
    /// A file couldn't be read or written.
    case io
    case outOfMemory
    /// The engine has no such object (asset, job, node).
    case notFound
    /// A bug or an unexpected engine state.
    case `internal`
}

extension DAWError: CustomStringConvertible {
    public var description: String {
        // No unapplied `String.init` here: when this file and EngineClient.swift share a batch
        // compile job, that reference hides CxxStdlib's `String(std.string)` from EngineClient
        // (a compiler issue with C++ interop; seen in T-022 on a full rebuild).
        switch self {
        case .notFound(let kind, let id): "no \(kind) with id \(id)"
        case .invalidArgument(let detail): "invalid argument: \(detail)"
        case .routingCycle(let path): "routing cycle: \(path.map { "\($0)" }.joined(separator: " → "))"
        case .invalidTempoMap(let reason): "invalid tempo map: \(reason.rawValue)"
        case .unknownCommandType(let type): "unknown command type \"\(type)\""
        case .malformedCommand(let detail): "malformed command: \(detail)"
        case .notImplemented(let what): "not implemented: \(what)"
        case .engine(let code, let detail): "engine error (\(code.rawValue)): \(detail)"
        }
    }
}
