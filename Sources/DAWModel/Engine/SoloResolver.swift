/// MIX-006: solo-in-place, resolved in the model (never at RT, never by a rebuild). The result
/// goes into each strip's mute slot through `setParam`.
///
/// When any track or bus is soloed, a channel stays audible if it is
///   - soloed itself,
///   - upstream of a soloed channel (it feeds a soloed bus, directly or through other buses), or
///   - downstream of a soloed channel (a bus a soloed track or bus feeds).
/// Every other track and bus is muted. "Feeds" follows main outputs and sends, not sidechains,
/// which carry no audio to the output. The master is never muted by solo. A channel's own mute
/// always wins.
public enum SoloResolver {
    /// The tracks, buses and master whose strip mute slot must be on.
    public static func mutedChannels(in project: Project) -> Set<NodeIDValue> {
        var muted = Set<NodeIDValue>()
        if project.master.strip.mute { muted.insert(project.master.id) }
        for track in project.tracks where track.strip.mute { muted.insert(track.id) }
        for bus in project.buses where bus.strip.mute { muted.insert(bus.id) }

        let soloed = project.tracks.filter(\.strip.solo).map(\.id) + project.buses.filter(\.strip.solo).map(\.id)
        guard !soloed.isEmpty else { return muted }

        // Channel → channel routing (tracks and buses only; the master is the sink).
        let buses = Set(project.buses.map(\.id))
        var down: [NodeIDValue: [NodeIDValue]] = [:]
        var up: [NodeIDValue: [NodeIDValue]] = [:]
        func link(_ from: NodeIDValue, _ output: OutputTarget, _ sends: [Send]) {
            var targets = sends.map(\.target)
            if case .bus(let id) = output { targets.append(id) }
            for target in targets where buses.contains(target) {
                down[from, default: []].append(target)
                up[target, default: []].append(from)
            }
        }
        for track in project.tracks { link(track.id, track.output, track.sends) }
        for bus in project.buses { link(bus.id, bus.output, bus.sends) }

        var audible = Set(soloed)
        audible.formUnion(reachable(from: soloed, in: down))
        audible.formUnion(reachable(from: soloed, in: up))
        for track in project.tracks where !audible.contains(track.id) { muted.insert(track.id) }
        for bus in project.buses where !audible.contains(bus.id) { muted.insert(bus.id) }
        return muted
    }

    /// Iterative DFS; the visited set also guards against a cyclic project (MODEL-030 should have
    /// prevented one).
    private static func reachable(from starts: [NodeIDValue], in edges: [NodeIDValue: [NodeIDValue]]) -> Set<NodeIDValue> {
        var seen = Set<NodeIDValue>()
        var stack = starts
        while let node = stack.popLast() {
            for next in edges[node] ?? [] where seen.insert(next).inserted {
                stack.append(next)
            }
        }
        return seen
    }
}
