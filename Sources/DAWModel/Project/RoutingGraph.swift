/// MODEL-030 (D-14): which channels feed which, for cycle rejection. Nodes are channels (tracks,
/// buses, the master); an edge `a → b` means audio can flow from `a` into `b` through a main output,
/// a send, or a sidechain from `a` into a device on `b`.
///
/// Channel granularity loses nothing: inside a channel, every way in (a bus's input, a device's
/// sidechain input) reaches every tap (pre-fader is the last insert or the source, post-fader the
/// strip), so a cycle between channels is a cycle in the engine graph and vice versa. A
/// self-sidechain is always a cycle for the same reason.
///
/// It is deliberately stricter than the graph GraphDescriptionBuilder emits: bypassed devices'
/// sidechains count, so toggling bypass never has to check for cycles.
struct RoutingGraph {
    /// Targets in project order, so the reported path is deterministic.
    private var edges: [NodeIDValue: [NodeIDValue]] = [:]
    /// Tracks, then buses: where a full cycle search starts.
    private let channels: [NodeIDValue]

    init(_ project: Project) {
        channels = project.tracks.map(\.id) + project.buses.map(\.id)
        func route(_ from: NodeIDValue, _ output: OutputTarget, _ sends: [Send]) {
            switch output {
            case .master: edges[from, default: []].append(project.master.id)
            case .bus(let id): edges[from, default: []].append(id)
            }
            for send in sends { edges[from, default: []].append(send.target) }
        }
        for track in project.tracks { route(track.id, track.output, track.sends) }
        for bus in project.buses { route(bus.id, bus.output, bus.sends) }
        project.forEachDeviceSlot { slot, channel in
            if let source = slot.sidechainSource?.source { edges[source, default: []].append(channel) }
        }
    }

    /// The channels along a shortest path from `start` to `goal`, both included (`[start]` when
    /// they are the same), or nil if `goal` isn't reachable. Breadth-first, so the cycle an edit is
    /// rejected with is the shortest one through the new route.
    func path(from start: NodeIDValue, to goal: NodeIDValue) -> [NodeIDValue]? {
        if start == goal { return [start] }
        var parent: [NodeIDValue: NodeIDValue] = [start: start]
        var queue = [start]
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            for next in edges[node] ?? [] where parent[next] == nil {
                parent[next] = node
                if next == goal {
                    var path = [goal]
                    var at = goal
                    while at != start {
                        at = parent[at]!
                        path.append(at)
                    }
                    return path.reversed()
                }
                queue.append(next)
            }
        }
        return nil
    }

    /// Some cycle as `[a, b, …, a]`, or nil if the routing is acyclic (MODEL-032).
    func cycle() -> [NodeIDValue]? {
        enum Mark { case onPath, done }
        var marks: [NodeIDValue: Mark] = [:]
        for root in channels where marks[root] == nil {
            // Each frame is a node and how many of its edges have been followed.
            var path: [(node: NodeIDValue, next: Int)] = [(root, 0)]
            marks[root] = .onPath
            while let top = path.last {
                let targets = edges[top.node] ?? []
                guard top.next < targets.count else {
                    marks[top.node] = .done
                    path.removeLast()
                    continue
                }
                path[path.count - 1].next += 1
                let next = targets[top.next]
                switch marks[next] {
                case .onPath:
                    let start = path.firstIndex { $0.node == next }!
                    return path[start...].map(\.node) + [next]
                case .done:
                    continue
                case nil:
                    marks[next] = .onPath
                    path.append((next, 0))
                }
            }
        }
        return nil
    }
}
