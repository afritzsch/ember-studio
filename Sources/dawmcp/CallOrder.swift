import Foundation

/// DW-163 (T-098): `tools/call` requests run strictly in the order they arrive. The MCP SDK handles
/// each request in a task of its own, so two pipelined calls (a fixture, then a render that needs
/// it) could reach the dispatcher in either order. `CallOrderTagger` sees stdin before the SDK
/// does and numbers every `tools/call` in `params._meta` (`CallOrder.metaKey`); the tool handler
/// waits for its number's turn (`CallSequencer.waitTurn`) and passes it on when done (`finish`).
///
/// `daw_render_cancel` isn't numbered: it must reach the render it cancels while that runs (13
/// "Contract delta (T-096)"). A numbered request that never reaches the handler (cancelled by
/// the client, or refused by the SDK before it) doesn't hold up the ones after it: a
/// `notifications/cancelled` releases its number, and a number whose call hasn't started
/// `abandonAfter` after it became next is skipped.
enum CallOrder {
    static let metaKey = "dev.emberstudio.dawmcp/seq"
    /// Calls that skip the queue.
    static let unordered: Set<String> = ["daw_render_cancel"]
}

final class CallSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    /// The number whose turn it is.
    private var next = 0
    private var started = Set<Int>()
    private var released = Set<Int>()
    private var idToSeq: [String: Int] = [:]
    /// When `next` last changed, to notice a number that never starts.
    private var nextSince = ContinuousClock.now
    let abandonAfter: Duration

    init(abandonAfter: Duration = .seconds(5)) {
        self.abandonAfter = abandonAfter
    }

    /// The next number, for a request with JSON-RPC id `id` (its key from `idKey`).
    func issue(id: String?) -> Int {
        lock.withLock {
            defer { issued += 1 }
            if let id { idToSeq[id] = issued }
            return issued
        }
    }

    /// Waits until every earlier number has finished (or was released or abandoned).
    func waitTurn(_ seq: Int) async {
        while true {
            let go: Bool = lock.withLock {
                // A number before ours that never started (the SDK dropped its request): skip it.
                if next < seq, !started.contains(next), ContinuousClock.now - nextSince > abandonAfter {
                    release(next)
                }
                guard next == seq else { return false }
                started.insert(seq)
                return true
            }
            if go { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// The call numbered `seq` is done; the next one may start.
    func finish(_ seq: Int) {
        lock.withLock { release(seq) }
    }

    /// `notifications/cancelled` for the request with id key `id`: if it hasn't started, its
    /// number is released (a cancelled request never reaches the handler).
    func cancel(id: String) {
        lock.withLock {
            guard let seq = idToSeq[id], !started.contains(seq) else { return }
            release(seq)
        }
    }

    private func release(_ seq: Int) {
        guard seq >= next else { return }
        released.insert(seq)
        while released.remove(next) != nil { bump() }
    }

    private func bump() {
        if let id = idToSeq.first(where: { $0.value == next })?.key { idToSeq[id] = nil }
        started.remove(next)
        next += 1
        nextSince = .now
    }

    /// A JSON-RPC id as a dictionary key (numbers and strings never collide).
    static func idKey(_ id: Any?) -> String? {
        switch id {
        case let s as String: "s:" + s
        case let n as NSNumber: "n:" + n.stringValue
        default: nil
        }
    }
}

/// Copies the MCP client's stdin to the pipe the SDK's transport reads, numbering `tools/call`
/// requests on the way (DW-163). Runs on a thread of its own; closes the pipe at EOF, so the
/// server sees the client go away as before.
final class CallOrderTagger: @unchecked Sendable {
    let sequencer: CallSequencer
    private let input: FileHandle
    private let output: FileHandle

    init(sequencer: CallSequencer, input: FileHandle, output: FileHandle) {
        self.sequencer = sequencer
        self.input = input
        self.output = output
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "dawmcp.stdin"
        thread.start()
    }

    private func run() {
        var pending = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                write(tag(Data(line)) + Data("\n".utf8))
            }
        }
        if !pending.isEmpty { write(tag(pending)) }
        try? output.close()
    }

    private func write(_ data: Data) {
        do { try output.write(contentsOf: data) } catch {}
    }

    /// The line with its `tools/call` requests numbered; anything else unchanged.
    func tag(_ line: Data) -> Data {
        guard line.contains(where: { $0 == UInt8(ascii: "{") }),
              let json = try? JSONSerialization.jsonObject(with: line) else { return line }
        if var batch = json as? [Any] {
            var changed = false
            for i in batch.indices {
                if let message = batch[i] as? [String: Any], let tagged = tag(message) {
                    batch[i] = tagged
                    changed = true
                }
            }
            return changed ? (try? JSONSerialization.data(withJSONObject: batch, options: [.withoutEscapingSlashes])) ?? line : line
        }
        guard let message = json as? [String: Any], let tagged = tag(message) else { return line }
        return (try? JSONSerialization.data(withJSONObject: tagged, options: [.withoutEscapingSlashes])) ?? line
    }

    /// nil: leave the message as it is.
    private func tag(_ message: [String: Any]) -> [String: Any]? {
        switch message["method"] as? String {
        case "notifications/cancelled":
            if let params = message["params"] as? [String: Any], let id = CallSequencer.idKey(params["requestId"]) {
                sequencer.cancel(id: id)
            }
            return nil
        case "tools/call":
            // Only requests the SDK will hand to the tool handler: an id, a tool name, object
            // arguments and _meta (anything else gets an error without reaching it).
            guard message["id"] != nil, var params = message["params"] as? [String: Any],
                  let name = params["name"] as? String, !CallOrder.unordered.contains(name),
                  params["arguments"] == nil || params["arguments"] is [String: Any]
            else { return nil }
            var meta: [String: Any]
            switch params["_meta"] {
            case nil: meta = [:]
            case let object as [String: Any]: meta = object
            default: return nil
            }
            meta[CallOrder.metaKey] = sequencer.issue(id: CallSequencer.idKey(message["id"]))
            params["_meta"] = meta
            var tagged = message
            tagged["params"] = params
            return tagged
        default:
            return nil
        }
    }
}

/// DW-147/DW-151 (T-098): a dawmcp started by the MCP client keeps the build it started with, so
/// commands and engine changes made since aren't there. While the binary on disk is newer than
/// this process, every tool result carries `warning` (no self-restart: the session's project would
/// be lost). The engine is linked into the binary statically, so the binary's own date covers it.
struct StaleBinaryWatch: Sendable {
    static let warning = "stale: dawmcp binary rebuilt since launch; restart the MCP server (e.g. /mcp in Claude Code) to use the new build"

    let paths: [String]
    let launched: Date

    init(paths: [String] = [Bundle.main.executableURL?.resolvingSymlinksInPath().path].compactMap { $0 }, launched: Date = Date()) {
        self.paths = paths
        self.launched = launched
    }

    /// The warning while any watched file was modified after launch, else nil.
    func check() -> String? {
        for path in paths {
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { continue }
            if modified > launched { return Self.warning }
        }
        return nil
    }
}
