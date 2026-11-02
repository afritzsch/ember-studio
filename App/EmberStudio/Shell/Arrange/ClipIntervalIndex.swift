import DAWModel
import Foundation

/// UI-010: finds the clips inside a time range on a range of rows without looking at the others,
/// so drawing and hit-testing cost what is visible, not the project's size.
///
/// Per row, clips are sorted by start (the model keeps them so, DW-110) with a running maximum of
/// their ends. A query binary-searches the first clip starting at or after the range's end, and the
/// first clip whose running maximum end passes the range's start; only the clips between are looked
/// at. Clips on a track may overlap, which is why the running maximum is needed.
struct ClipIntervalIndex: Sendable {
    struct Entry: Sendable {
        var clip: Clip
        var row: Int
        var trackID: NodeIDValue
        var start: Int64 { clip.start.raw }
        var end: Int64 { clip.start.raw + clip.length.raw }
        var id: ModelID { clip.id }
    }

    private struct Row: Sendable {
        var entries: [Entry] = []
        var maxEnd: [Int64] = []
    }

    private var rows: [Row] = []
    private var locations: [ModelID: (row: Int, index: Int)] = [:]

    init() {}

    init(tracks: [Track]) {
        rows.reserveCapacity(tracks.count)
        for (r, track) in tracks.enumerated() {
            var row = Row()
            row.entries = track.clips.map { Entry(clip: $0, row: r, trackID: track.id) }
            // The model keeps clips in (start, id) order; sort anyway so the index never depends on it.
            if !row.entries.isSorted(by: { $0.start <= $1.start }) { row.entries.sort { $0.start < $1.start } }
            var running = Int64.min
            row.maxEnd = row.entries.map { entry in
                running = max(running, entry.end)
                return running
            }
            for (i, entry) in row.entries.enumerated() { locations[entry.id] = (r, i) }
            rows.append(row)
        }
    }

    var rowCount: Int { rows.count }
    var clipCount: Int { locations.count }

    func entry(_ id: ModelID) -> Entry? {
        locations[id].map { rows[$0.row].entries[$0.index] }
    }

    /// The clips on `rowRange` that overlap `[from, to)`, row by row, each row in start order.
    func clips(rows rowRange: Range<Int>, from: Int64, to: Int64) -> [Entry] {
        var out: [Entry] = []
        forEachClip(rows: rowRange, from: from, to: to) { out.append($0) }
        return out
    }

    func forEachClip(rows rowRange: Range<Int>, from: Int64, to: Int64, _ body: (Entry) -> Void) {
        guard to > from else { return }
        let lo = max(rowRange.lowerBound, 0), hi = min(rowRange.upperBound, rows.count)
        guard lo < hi else { return }
        for r in lo..<hi {
            let row = rows[r]
            // First clip starting at or after `to`: none from there on can overlap.
            let endIndex = Self.partition(row.entries.count) { row.entries[$0].start >= to }
            // First clip whose running max end passes `from`: none before it can overlap.
            let startIndex = Self.partition(endIndex) { row.maxEnd[$0] > from }
            var i = startIndex
            while i < endIndex {
                let entry = row.entries[i]
                if entry.end > from { body(entry) }
                i += 1
            }
        }
    }

    /// The first index in `0..<count` where the monotonic `predicate` holds (`count` if none).
    private static func partition(_ count: Int, _ predicate: (Int) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(mid) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

private extension Array {
    func isSorted(by areInOrder: (Element, Element) -> Bool) -> Bool {
        var i = 1
        while i < count {
            if !areInOrder(self[i - 1], self[i]) { return false }
            i += 1
        }
        return true
    }
}
