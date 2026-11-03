import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-012: bars/beats from the tempo map, snapping (off, bar, beat, 1/8…1/32, triplets) and the grid
// lines the canvas draws. 960 PPQ: a 4/4 bar is 3840 ticks, a beat 960.

@Suite("Snap grid (UI-012)")
struct SnapGridTests {
    static func grid(_ signatures: [TimeSignatureEvent] = [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]) throws -> SnapGrid {
        SnapGrid(tempoMap: try TempoMap(tempoEvents: [TempoEvent(tick: 0, bpm: 120)], timeSignatures: signatures, sampleRate: 48_000))
    }

    @Test("UI-012: snap to beat, bar and note values in 4/4: nearest line, ties to the later one, never before 0")
    func snap44() throws {
        let g = try Self.grid()
        #expect(g.snap(1000, .beat) == 960)
        #expect(g.snap(1500, .beat) == 1920)
        #expect(g.snap(480, .beat) == 960, "a tie goes to the later line")
        #expect(g.snap(1900, .bar) == 0 && g.snap(1920, .bar) == 3840 && g.snap(9000, .bar) == 7680)
        #expect(g.snap(250, .eighth) == 480 && g.snap(230, .eighth) == 0)
        #expect(g.snap(130, .sixteenth) == 240 && g.snap(110, .sixteenth) == 0)
        #expect(g.snap(59, .thirtySecond) == 0 && g.snap(61, .thirtySecond) == 120)
        #expect(g.snap(-500, .beat) == 0)
        #expect(g.snap(1234, .off) == 1234)
    }

    @Test("UI-012: triplet grids are 2/3 of the straight value (1/4T 640, 1/8T 320, 1/16T 160, 1/32T 80)")
    func triplets() throws {
        let g = try Self.grid()
        #expect(SnapMode.quarterTriplet.noteTicks == 640 && SnapMode.eighthTriplet.noteTicks == 320)
        #expect(SnapMode.sixteenthTriplet.noteTicks == 160 && SnapMode.thirtySecondTriplet.noteTicks == 80)
        #expect(g.snap(170, .eighthTriplet) == 320 && g.snap(150, .eighthTriplet) == 0)
        #expect(g.snap(4540, .quarterTriplet) == 4480)
        #expect(g.snap(81, .sixteenthTriplet) == 160 && g.snap(41, .thirtySecondTriplet) == 80)
    }

    @Test("UI-012: lines restart at bar lines (7/8 at 1/4 triplets) and follow signature changes")
    func oddMetersAndChanges() throws {
        let seven = try Self.grid([TimeSignatureEvent(tick: 0, numerator: 7, denominator: 8)])
        #expect(seven.bar(containing: 100).length == 3360)
        #expect(seven.beatTicks(at: 100) == 480)
        #expect(seven.snap(3290, .quarterTriplet) == 3360, "the bar line, not 3200 + 640")
        #expect(seven.snap(3250, .quarterTriplet) == 3200)
        #expect(seven.snap(1000, .beat) == 960)

        // 4/4 for bar 1, then 3/4 from bar 2 (tick 3840).
        let change = try Self.grid([TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4),
                                    TimeSignatureEvent(tick: 3840, numerator: 3, denominator: 4)])
        #expect(change.bar(containing: 5000) == (3840, 2880))
        #expect(change.snap(6640, .bar) == 6720)
        #expect(change.barNumber(at: 6720) == 3)
        #expect(change.step(.bar, at: 0) == 3840 && change.step(.bar, at: 4000) == 2880)
        #expect(change.step(.off, at: 0) == 960, "a nudge with snapping off moves a beat")
    }

    @Test("UI-012: grid lines: bars numbered, beats and the snap resolution when they're far enough apart, bars thinned when zoomed out")
    func lines() throws {
        let g = try Self.grid()
        let fine = g.lines(from: 0, to: 7680, minSpacing: 100, snap: .sixteenth)
        #expect(fine.count == 32)
        #expect(fine.first == GridLine(tick: 0, kind: .bar(1)))
        #expect(fine.contains(GridLine(tick: 3840, kind: .bar(2))))
        #expect(fine.filter { $0.kind == .beat }.map(\.tick.raw) == [960, 1920, 2880, 4800, 5760, 6720])
        #expect(fine.filter { $0.kind == .subdivision }.count == 24)
        #expect(Set(fine.map(\.tick)).count == fine.count, "one line per tick")

        let beatsOnly = g.lines(from: 0, to: 7680, minSpacing: 500, snap: .sixteenth)
        #expect(beatsOnly.count == 8, "16ths are too close; bars and beats remain")
        let barsOnly = g.lines(from: 0, to: 7680, minSpacing: 1000, snap: .sixteenth)
        #expect(barsOnly.map(\.kind) == [.bar(1), .bar(2)])
        let thinned = g.lines(from: 0, to: 61_440, minSpacing: 5000, snap: .off)
        let expectedBars: [GridLine.Kind] = [1, 3, 5, 7, 9, 11, 13, 15].map { .bar($0) }
        #expect(thinned.map(\.kind) == expectedBars)
        let window = g.lines(from: 1000, to: 3000, minSpacing: 100, snap: .beat)
        #expect(window.map(\.tick.raw) == [1920, 2880])
    }
}

@Suite("Timeline geometry and clip interval index (UI-010)")
struct TimelineIndexTests {
    @Test("UI-010: tick ↔ x and row ↔ y round-trip; visible rows are clamped")
    func geometry() {
        let g = TimelineGeometry(pixelsPerBeat: 32, scrollX: 100, scrollY: 32, trackHeight: 64, size: CGSize(width: 640, height: 22 + 128))
        #expect(g.x(Tick(960)) == -68)
        #expect(g.tick(atX: g.x(Tick(4800))) == 4800)
        #expect(g.row(atY: 10) == nil, "the ruler")
        #expect(g.row(atY: 22) == 0 && g.row(atY: 22 + 32) == 1)
        #expect(g.visibleRows(of: 10) == 0..<3)
        #expect(g.visibleRows(of: 2) == 0..<2)
        let v = g.visibleTicks
        #expect(v.from == 3000 && v.to.raw >= 3000 + 640 * 30)
    }

    private static func track(_ id: NodeIDValue, _ clips: [(Int64, Int64)], firstID: ModelID) -> Track {
        Track(id: id, name: "T\(id)", kind: .midi, clips: clips.enumerated().map { i, c in
            .midi(MidiClip(id: firstID + ModelID(i), start: Tick(c.0), length: Tick(c.1)))
        })
    }

    @Test("UI-010: the index returns exactly the clips overlapping a range, overlapping and long clips included")
    func intervalQuery() {
        // Row 0: a long clip under short ones; row 1: back to back.
        let tracks = [Self.track(1, [(0, 100_000), (100, 50), (500, 50), (2000, 10)], firstID: 100),
                      Self.track(2, [(0, 1000), (1000, 1000), (2000, 1000)], firstID: 200)]
        let index = ClipIntervalIndex(tracks: tracks)
        #expect(index.clipCount == 7 && index.rowCount == 2)
        #expect(index.clips(rows: 0..<1, from: 520, to: 530).map(\.id) == [100, 102])
        #expect(index.clips(rows: 0..<2, from: 1000, to: 1001).map(\.id) == [100, 201], "end is exclusive: clip 200 ends at 1000")
        #expect(index.clips(rows: 1..<2, from: 999, to: 2001).map(\.id) == [200, 201, 202])
        #expect(index.clips(rows: 0..<2, from: 5000, to: 5000).isEmpty)
        #expect(index.clips(rows: 5..<9, from: 0, to: 10).isEmpty)
        #expect(index.entry(201)?.row == 1 && index.entry(201)?.trackID == 2)
    }

    @Test("UI-010: index queries match a brute-force scan on random clips")
    func randomized() {
        var rng = SystemRandomNumberGenerator()
        var tracks: [Track] = []
        var id: ModelID = 1
        for t in 0..<8 {
            var clips: [(Int64, Int64)] = []
            for _ in 0..<60 { clips.append((Int64.random(in: 0..<100_000, using: &rng), Int64.random(in: 1..<20_000, using: &rng))) }
            clips.sort { $0.0 < $1.0 }
            tracks.append(Self.track(NodeIDValue(t + 1), clips, firstID: id))
            id += 60
        }
        let index = ClipIntervalIndex(tracks: tracks)
        for _ in 0..<200 {
            let from = Int64.random(in: 0..<120_000, using: &rng)
            let to = from + Int64.random(in: 1..<30_000, using: &rng)
            let a = Int.random(in: 0...8, using: &rng), b = Int.random(in: 0...8, using: &rng)
            let rows = min(a, b)..<max(a, b)
            let expected = rows.flatMap { r in
                tracks[r].clips.filter { $0.start.raw < to && $0.start.raw + $0.length.raw > from }.map(\.id)
            }
            #expect(index.clips(rows: rows, from: from, to: to).map(\.id).sorted() == expected.sorted())
        }
    }
}
