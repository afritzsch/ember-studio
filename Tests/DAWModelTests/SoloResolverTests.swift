import DAWModel
import Testing

/// MIX-006 truth table on this routing:
///
///   T1 ───────────────────────→ master
///   T2 ─┐
///       ├→ A → B ─────────────→ master
///   T3 ─┘
///   T4 ───────────────────────→ master
///   T4 ─(post send)→ FX ──────→ master
@Suite("SoloResolver (MIX-006)")
struct SoloResolverTests {
    enum Ch: String, CaseIterable, CustomTestStringConvertible {
        case t1, t2, t3, t4, a, b, fx
        var testDescription: String { rawValue }
    }

    private static func project(solo: Set<Ch>, mute: Set<Ch> = []) -> (Project, [Ch: NodeIDValue]) {
        var p = Project(name: "solo")
        var id: [Ch: NodeIDValue] = [:]
        for ch in Ch.allCases { id[ch] = p.ids.allocate() }
        func strip(_ ch: Ch) -> ChannelStripState {
            ChannelStripState(mute: mute.contains(ch), solo: solo.contains(ch))
        }
        p.tracks = [
            Track(id: id[.t1]!, name: "T1", kind: .audio, strip: strip(.t1)),
            Track(id: id[.t2]!, name: "T2", kind: .audio, strip: strip(.t2), output: .bus(id[.a]!)),
            Track(id: id[.t3]!, name: "T3", kind: .audio, strip: strip(.t3), output: .bus(id[.a]!)),
            Track(id: id[.t4]!, name: "T4", kind: .audio, strip: strip(.t4),
                  sends: [Send(id: p.ids.allocate(), target: id[.fx]!)]),
        ]
        p.buses = [
            Bus(id: id[.a]!, name: "A", strip: strip(.a), output: .bus(id[.b]!)),
            Bus(id: id[.b]!, name: "B", strip: strip(.b)),
            Bus(id: id[.fx]!, name: "FX", strip: strip(.fx)),
        ]
        return (p, id)
    }

    struct Row: CustomTestStringConvertible, Sendable {
        var solo: Set<Ch>
        var mute: Set<Ch> = []
        var muted: Set<Ch>
        var testDescription: String {
            "solo \(solo.map(\.rawValue).sorted()) mute \(mute.map(\.rawValue).sorted()) → muted \(muted.map(\.rawValue).sorted())"
        }
    }

    static let table: [Row] = [
        // No solo: only explicit mutes.
        Row(solo: [], muted: []),
        Row(solo: [], mute: [.t2, .fx], muted: [.t2, .fx]),
        // A soloed track: everything else is muted except the buses it feeds (downstream).
        Row(solo: [.t1], muted: [.t2, .t3, .t4, .a, .b, .fx]),
        Row(solo: [.t2], muted: [.t1, .t3, .t4, .fx]),
        Row(solo: [.t4], muted: [.t1, .t2, .t3, .a, .b]),  // FX: fed through a send
        // A soloed bus: the tracks (and buses) feeding it stay audible, and the buses it feeds.
        Row(solo: [.a], muted: [.t1, .t4, .fx]),
        Row(solo: [.b], muted: [.t1, .t4, .fx]),  // T2/T3 feed B through A
        Row(solo: [.fx], muted: [.t1, .t2, .t3, .a, .b]),  // T4 feeds FX through a send
        // Several solos combine.
        Row(solo: [.t1, .fx], muted: [.t2, .t3, .a, .b]),
        Row(solo: [.t2, .t3], muted: [.t1, .t4, .fx]),
        // Mute wins over solo and over "feeds a soloed bus".
        Row(solo: [.a], mute: [.t2], muted: [.t1, .t2, .t4, .fx]),
        Row(solo: [.t1], mute: [.t1], muted: [.t1, .t2, .t3, .t4, .a, .b, .fx]),
    ]

    @Test("MIX-006: solo-in-place truth table", arguments: table)
    func truthTable(_ row: Row) {
        let (p, id) = Self.project(solo: row.solo, mute: row.mute)
        let muted = SoloResolver.mutedChannels(in: p)
        let expected = Set(row.muted.map { id[$0]! })
        #expect(muted == expected)
        #expect(!muted.contains(p.master.id), "solo never mutes the master")
    }

    @Test("MIX-006: the master is muted only by its own mute")
    func master() {
        var (p, _) = Self.project(solo: [.t1])
        p.master.strip.mute = true
        #expect(SoloResolver.mutedChannels(in: p).contains(p.master.id))
    }

    @Test("MIX-006, MIX-007: resolved mutes land in strip mute slots and the owner's send mute slots")
    func paramValues() {
        let (p, id) = Self.project(solo: [.t1])
        let runtime = RuntimeIDs.sequential(for: p)
        let values = GraphDescriptionBuilder.paramValues(p, runtime: runtime, catalog: ParamCatalog())
        func mute(_ ch: Ch) -> Float? { values[runtime.stripParam(id[ch]!, ParamLayout.Strip.mute)!] }
        #expect(mute(.t1) == 0 && mute(.t2) == 1 && mute(.fx) == 1)
        let send = p.tracks[3].sends[0]
        #expect(values[runtime.sendMuteParam(send.id)!] == 1, "T4 is solo-muted: its send is muted too")
        #expect(values[runtime.sendLevelParam(send.id)!] == send.level, "the level slot keeps its value")

        let (open, _) = Self.project(solo: [])
        let openValues = GraphDescriptionBuilder.paramValues(open, runtime: runtime, catalog: ParamCatalog())
        #expect(openValues[runtime.sendMuteParam(send.id)!] == 0)
        #expect(openValues[runtime.sendLevelParam(send.id)!] == send.level)
    }
}
