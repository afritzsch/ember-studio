import Foundation

// CTL-001: JSON-RPC 2.0 messages, one per line on every transport (dawctl, dawmcp, the app socket).

/// A request ID: a number or a string. A request without one is a notification and gets no
/// response.
public enum RPCID: Hashable, Sendable, Codable {
    case int(Int64)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

public struct RPCRequest: Hashable, Sendable, Codable {
    public var jsonrpc: String
    public var id: RPCID?
    public var method: String
    /// Named params (an object). Missing means `{}`.
    public var params: JSONValue?

    public init(id: RPCID?, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    public init(_ id: Int64, _ method: ControlMethod, _ params: JSONValue? = nil) {
        self.init(id: .int(id), method: method.rawValue, params: params)
    }
}

/// CTL-003: `data` carries `{dawError, detail}`, see `ControlError`.
public struct RPCError: Error, Hashable, Sendable, Codable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// `data.dawError`: the stable name of what went wrong.
    public var dawError: String? { data?["dawError"]?.stringValue }
}

public struct RPCResponse: Hashable, Sendable, Codable {
    public var jsonrpc: String
    /// Null when the request couldn't be read far enough to know its ID.
    public var id: RPCID?
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: RPCID?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: RPCID?, error: RPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }

    public var isError: Bool { error != nil }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        id = try c.decodeIfPresent(RPCID.self, forKey: .id)
        error = try c.decodeIfPresent(RPCError.self, forKey: .error)
        // A null result is still a result; it is only absent on errors.
        result = error == nil ? try c.decodeIfPresent(JSONValue.self, forKey: .result) ?? .null : nil
    }

    /// JSON-RPC 2.0: `id` is always present (null if unknown), and exactly one of result/error.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        if let error {
            try c.encode(error, forKey: .error)
        } else {
            try c.encode(result ?? .null, forKey: .result)
        }
    }

    /// One line of newline-delimited JSON, without the newline.
    public func line() -> String {
        (try? JSONValue.makeEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
            ?? #"{"error":{"code":-32603,"message":"unencodable response"},"id":null,"jsonrpc":"2.0"}"#
    }
}
