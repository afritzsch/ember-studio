import Foundation
import Testing

@testable import DAWModel

// DW-196 (T-065, 06 "Contract delta (T-065)"): ParamInfo's `steps` and value labels, published by
// the engine's `paramInfoJSON` and parsed into `ParamDescriptor`.

@Suite("ParamInfo steps and value labels (DW-196, T-065)")
struct ParamStepsTests {
    @Test("DW-196: paramInfoJSON publishes steps and labels for every enum/switch built-in param; ParamCatalog parses them")
    func engineTables() throws {
        let catalog = ParamCatalog(engine: try EngineClient(.offline()))
        func row(_ kind: NodeKind, _ id: String) -> ParamDescriptor? {
            catalog.infos[kind]?.values.first { $0.id == id }
        }
        // The delay's note menu: 14 note values, labels in index order (Delay::kNotes).
        let note = try #require(row(.delay, "note"))
        #expect(note.steps == 13 && note.isDiscrete && !note.isSwitch)
        #expect(note.labels == ["1/32", "1/16T", "1/16", "1/8T", "1/16D", "1/8", "1/4T", "1/8D", "1/4", "1/2T", "1/4D",
                                "1/2", "1/2D", "1/1"])
        #expect(note.display(5) == "1/8" && note.display(5.4) == "1/8" && note.display(13) == "1/1")
        #expect(note.value(ofStep: 8) == 8)
        // Switches: sync and ping-pong, the EQ's band switches, the compressor's detector (labelled).
        for (kind, id) in [(NodeKind.delay, "sync"), (.delay, "pingpong"), (.eq, "hpOn"), (.eq, "lowOn"), (.eq, "peak1On"),
                           (.eq, "peak2On"), (.eq, "highOn"), (.eq, "lpOn"), (.channelStrip, "mute"), (.channelStrip, "phase"),
                           (.gain, "mute"), (.metronome, "on")] {
            let r = try #require(row(kind, id), "\(kind) \(id)")
            #expect(r.steps == 1 && r.isSwitch && r.labels == nil, "\(kind) \(id)")
            #expect(r.choices.map(\.label) == ["Off", "On"])
        }
        let detector = try #require(row(.compressor, "detector"))
        #expect(detector.steps == 1 && detector.labels == ["Peak", "RMS"])
        #expect(detector.display(0) == "Peak" && detector.display(1) == "RMS" && detector.display(0.6) == "RMS")
        // Everything else is continuous.
        for kind in [NodeKind.eq, .compressor, .delay, .reverb, .sampler] {
            for r in catalog.infos[kind].map({ Array($0.values) }) ?? [] where !["note", "sync", "pingpong", "detector"].contains(r.id) && !r.id.hasSuffix("On") {
                #expect(r.steps == 0 && r.labels == nil, "\(kind) \(r.id)")
            }
        }
        #expect(row(.delay, "mix")?.display(0.3) == "0.30")
        #expect(row(.delay, "time")?.display(375) == "375 ms")
    }

    @Test("DW-196: rows without steps are continuous; labels that don't match the steps are dropped")
    func parsing() {
        let json = #"""
        [{"index":0,"id":"a","name":"A","min":0,"max":1,"default":0},
         {"index":1,"id":"b","name":"B","min":0,"max":2,"default":0,"steps":2,"labels":["x","y","z"]},
         {"index":2,"id":"c","name":"C","min":0,"max":2,"default":0,"steps":2,"labels":["x"]},
         {"index":3,"id":"d","name":"D","min":-1,"max":1,"default":0,"steps":4}]
        """#
        let rows = ParamCatalog.parseInfos(json)
        #expect(rows[0]?.steps == 0 && rows[0]?.choices.isEmpty == true)
        #expect(rows[1]?.labels == ["x", "y", "z"] && rows[1]?.display(1.2) == "y")
        #expect(rows[2]?.steps == 2 && rows[2]?.labels == nil && rows[2]?.choices.map(\.label) == ["0", "1", "2"])
        #expect(rows[3]?.choices.map(\.value) == [-1, -0.5, 0, 0.5, 1])
        #expect(rows[3]?.step(of: .nan) == 0 && rows[3]?.step(of: 7) == 4)
    }
}
