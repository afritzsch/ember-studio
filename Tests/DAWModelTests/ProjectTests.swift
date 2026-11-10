import DAWModel
import Foundation
import Testing

@Suite("Project")
struct ProjectTests {
    @Test("A new project: 48 kHz, default tempo map, master allocated, empty")
    func defaults() {
        let project = Project(name: "P")
        #expect(project.formatVersion == Project.currentFormatVersion)
        #expect(project.sessionSampleRate == 48_000 && project.tempoMap == TempoMap())
        #expect(project.master.id == 1 && project.ids.next == 2)
        #expect(project.tracks.isEmpty && project.buses.isEmpty && project.assets.isEmpty && project.loop == nil)
    }

    @Test("Document types round-trip through JSON (Codable, Equatable)")
    func codableRoundTrip() throws {
        var project = try Project(name: "Full", sessionSampleRate: 44_100)
        try project.setTempoMap(
            tempoEvents: [TempoEvent(tick: 0, bpm: 100), TempoEvent(tick: 3840, bpm: 140)],
            timeSignatures: [TimeSignatureEvent(tick: 0, numerator: 7, denominator: 8)])
        let bus = Bus(id: project.ids.allocate(), name: "Verb")
        let comp = DeviceSlot(
            id: project.ids.allocate(), kind: .builtin(.compressor), params: [ParamValue(index: 0, value: -12)],
            sidechainSource: SidechainRef(source: bus.id, tap: .preFader))
        let au = DeviceSlot(
            id: project.ids.allocate(),
            kind: .au(AUDescriptor(identifier: "aufx:dely:appl", name: "AUDelay")), pluginState: Data([1, 2, 3]))
        let vst = DeviceSlot(
            id: project.ids.allocate(), kind: .vst3(VST3Descriptor(identifier: "/x.vst3#ABC", name: "X")), bypass: true)
        // Allocated like every ID, so decoding leaves the allocator as it was (DW-031).
        let asset = project.ids.allocate()
        project.buses = [bus]
        project.tracks = [
            Track(
                id: project.ids.allocate(), name: "Gtr", kind: .audio,
                clips: [.audio(AudioClip(id: project.ids.allocate(), assetID: asset, start: 960, length: 1920,
                                         sourceOffsetSamples: 100, gain: 0.5, fadeIn: 10, fadeOut: 20))],
                takeFolders: [TakeFolder(id: project.ids.allocate())], inserts: [comp, au],
                sends: [Send(id: project.ids.allocate(), target: bus.id, level: 0.7, tap: .preFader)],
                output: .bus(bus.id), armed: true, monitoring: .on,
                automation: [AutomationLane(
                    id: project.ids.allocate(), target: .device(slot: comp.id, index: 0),
                    points: [AutomationPoint(tick: 0, value: 0.5), AutomationPoint(tick: 960, value: 1, curve: .exp(2)),
                             AutomationPoint(tick: 1920, value: 0, curve: .hold)],
                    mode: .latch)]),
            Track(
                id: project.ids.allocate(), name: "Keys", kind: .midi,
                clips: [.midi(MidiClip(id: project.ids.allocate(), start: 0, length: 3840,
                                       notes: [Note(id: project.ids.allocate(), start: 0, length: 480, pitch: 60)]))],
                instrument: DeviceSlot(id: project.ids.allocate(), kind: .builtin(.sampler)), inserts: [vst]),
        ]
        project.assets = [AssetRef(id: asset, path: "Audio/gtr.wav", channels: 2, originalSampleRate: 48_000, frames: 1000)]
        project.loop = LoopRange(start: 0, end: 7680, isEnabled: false)
        project.master.strip.gain = 0.9

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.ids == project.ids)
        #expect(decoded.tempoMap.tickToSample(3840) == project.tempoMap.tickToSample(3840))
    }

    @Test("DW-020: the file holds the session rate once; the tempo map stores only its events")
    func sampleRateStoredOnce() throws {
        let project = try Project(sessionSampleRate: 96_000)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        #expect(json["sessionSampleRate"] as? Double == 96_000)
        let tempo = try #require(json["tempoMap"] as? [String: Any])
        #expect(Set(tempo.keys) == ["tempoEvents", "timeSignatures"])
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)).tempoMap.sampleRate == 96_000)
    }

    @Test("DW-020: setSessionSampleRate rebuilds the tempo map at the new rate")
    func setSessionSampleRateRebuildsMap() throws {
        var project = Project()
        try project.setTempoMap(
            tempoEvents: [TempoEvent(tick: 0, bpm: 120), TempoEvent(tick: 960, bpm: 60)],
            timeSignatures: [TimeSignatureEvent(tick: 0, numerator: 3, denominator: 4)])
        #expect(project.tempoMap.tickToSample(1920) == 24_000 + 48_000)
        try project.setSessionSampleRate(44_100)
        #expect(project.sessionSampleRate == 44_100 && project.tempoMap.sampleRate == 44_100)
        #expect(project.tempoMap.tickToSample(1920) == 22_050 + 44_100)
        #expect(project.tempoMap.tempoEvents.count == 2 && project.tempoMap.timeSignatures[0].numerator == 3)
    }

    @Test("DW-021: tempo map errors surface as DAWError.invalidTempoMap and change nothing")
    func tempoErrorsMapToDAWError() throws {
        var project = Project()
        let before = project
        #expect(throws: DAWError.invalidTempoMap(reason: .sampleRateOutOfRange)) {
            try project.setSessionSampleRate(10)
        }
        #expect(throws: DAWError.invalidTempoMap(reason: .tempoOutOfRange)) {
            try project.setTempoMap(tempoEvents: [TempoEvent(tick: 0, bpm: 0)], timeSignatures: TempoMap().timeSignatures)
        }
        #expect(throws: DAWError.invalidTempoMap(reason: .sampleRateOutOfRange)) {
            try Project(sessionSampleRate: 1e9)
        }
        #expect(project == before)
        #expect(DAWError(TempoMapError.eventsNotAscending) == .invalidTempoMap(reason: .eventsNotAscending))

        // A bad tempo map in a file fails decoding with the DAWError underneath.
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Project())) as? [String: Any])
        json["sessionSampleRate"] = 5.0
        let bad = try JSONSerialization.data(withJSONObject: json)
        #expect(performing: { try JSONDecoder().decode(Project.self, from: bad) }, throws: { error in
            guard case .dataCorrupted(let context) = error as? DecodingError else { return false }
            return context.underlyingError as? DAWError == .invalidTempoMap(reason: .sampleRateOutOfRange)
        })
    }

    @Test("Project equality ignores the ID allocator (IDs are never rolled back)")
    func equalityIgnoresAllocator() {
        let a = Project(id: UUID(), name: "Same")
        var b = a
        _ = b.ids.allocate()
        #expect(a == b)
        b.name = "Other"
        #expect(a != b)
    }

    @Test("IDAllocator never hands out 0 or a reserved ID")
    func allocator() {
        var ids = IDAllocator(next: 0)
        #expect(ids.allocate() == 1)
        ids.reserve(10)
        #expect(ids.allocate() == 11)
        ids.reserve(3)
        #expect(ids.allocate() == 12)
    }

    @Test("DAWError is Codable and has a stable code (routingCycle carries its path)")
    func dawErrorCodable() throws {
        let errors: [DAWError] = [
            .notFound(kind: "track", id: 4), .invalidArgument("x"), .routingCycle(path: [3, 5, 3]),
            .invalidTempoMap(reason: .noTempoEvents), .unknownCommandType("T"), .malformedCommand("m"),
            .notImplemented("n"), .engine(code: .io, detail: "d"),
        ]
        for error in errors {
            #expect(try JSONDecoder().decode(DAWError.self, from: JSONEncoder().encode(error)) == error)
        }
        #expect(errors.map(\.code) == [
            "notFound", "invalidArgument", "routingCycle", "invalidTempoMap", "unknownCommandType",
            "malformedCommand", "notImplemented", "engine",
        ])
        #expect(DAWError.routingCycle(path: [3, 5, 3]).description == "routing cycle: 3 → 5 → 3")
    }
}
