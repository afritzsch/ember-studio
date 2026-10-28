import Foundation

/// A `dawctl script` file (CTL-010), also the golden fixture format (TEST-001): one request per
/// line. A line is either
///   - a JSON object `{"method": …, "params": {…}}`, where `jsonrpc` may be left out and a
///     missing `id` becomes the line number, or
///   - shorthand: `method` or `method {params}`, e.g. `project.new {"name": "demo"}`.
/// Blank lines and lines starting with `#` or `//` are skipped.
public struct ControlScript: Sendable {
    public struct Line: Hashable, Sendable {
        /// 1-based.
        public var number: Int
        public var request: RPCRequest
    }

    public var lines: [Line]

    /// Throws `invalidRequest` naming the first bad line.
    public init(parsing text: String) throws(ControlError) {
        var lines: [Line] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            do {
                if let request = try Self.request(fromLine: String(raw), defaultID: .int(Int64(number))) {
                    lines.append(Line(number: number, request: request))
                }
            } catch {
                throw .invalidRequest("line \(number): \(error.detail)")
            }
        }
        self.lines = lines
    }

    public init(contentsOf url: URL) throws(ControlError) {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw .model(.invalidArgument("cannot read script \(url.path): \(error.localizedDescription)"))
        }
        try self.init(parsing: text)
    }

    /// One script or REPL line; nil for blank and comment lines.
    public static func request(fromLine raw: String, defaultID: RPCID?) throws(ControlError) -> RPCRequest? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { return nil }
        if line.hasPrefix("{") {
            let json: JSONValue
            do {
                json = try JSONValue(parsing: Data(line.utf8))
            } catch {
                throw .parseError("not JSON")
            }
            return try RPCRequest(validating: json, defaultID: defaultID)
        }
        let method = String(line.prefix { !$0.isWhitespace })
        let rest = line.dropFirst(method.count).trimmingCharacters(in: .whitespaces)
        var params: JSONValue?
        if !rest.isEmpty {
            do {
                params = try JSONValue(parsing: Data(rest.utf8))
            } catch {
                throw .parseError("params of \(method) are not JSON")
            }
        }
        return try RPCRequest(validating: ["method": .string(method), "params": params ?? .object([:])], defaultID: defaultID)
    }
}

extension RPCRequest {
    /// Checks the JSON-RPC 2.0 request shape. With a `defaultID` (scripts), `jsonrpc` may be left
    /// out and a missing `id` gets the default; without one (the wire), a missing `id` makes a
    /// notification.
    init(validating json: JSONValue, defaultID: RPCID? = nil) throws(ControlError) {
        guard case .object(let object) = json else { throw .invalidRequest("a request must be a JSON object") }
        switch object["jsonrpc"] {
        case .string("2.0"): break
        case nil where defaultID != nil: break
        default: throw .invalidRequest("jsonrpc must be \"2.0\"")
        }
        guard let method = object["method"]?.stringValue, !method.isEmpty else {
            throw .invalidRequest("method must be a non-empty string")
        }
        var id: RPCID?
        switch object["id"] {
        case nil: id = defaultID
        case .int(let i): id = .int(i)
        case .string(let s): id = .string(s)
        case .null: id = nil
        default: throw .invalidRequest("id must be a number or a string")
        }
        let params = object["params"]
        switch params {
        case nil, .null, .object: break
        default: throw .invalidParams("params must be an object (named params)")
        }
        self.init(id: id, method: method, params: params)
    }
}
