import AudioToolbox
import Foundation
import PluginCatalog
import Testing

/// PLUG-002. These use Apple's built-in AUs (AUDelay, AUSampler), which ship with macOS, so they
/// don't depend on what else is installed.
@Suite("PLUG-002: audio unit discovery and scan")
struct AudioUnitScanTests {
    @Test("PLUG-002: identifiers round-trip, including unprintable and ':' codes")
    func identifierRoundTrip() throws {
        let delay = try #require(AudioUnitIdentifier("aufx:dely:appl"))
        #expect(delay.type == kAudioUnitType_Effect)
        #expect(delay.subtype == 0x6465_6C79)  // 'dely'
        #expect(delay.manufacturer == kAudioUnitManufacturer_Apple)
        #expect(delay.description == "aufx:dely:appl")

        let odd = AudioUnitIdentifier(type: kAudioUnitType_MusicDevice, subtype: 0x613A_6263, manufacturer: 0x0102_0304)
        #expect(odd.description == "aumu:0x613A6263:0x01020304")
        #expect(AudioUnitIdentifier(odd.description) == odd)

        #expect(AudioUnitIdentifier("aufx:dely") == nil)
        #expect(AudioUnitIdentifier("aufx:toolong:appl") == nil)
    }

    @Test("PLUG-002: component manager lists effects, instruments and music effects")
    func discovery() throws {
        let candidates = SystemPluginDiscovery.audioUnitCandidates()
        let identifiers = Set(candidates.map(\.path))
        #expect(identifiers.contains("aufx:dely:appl"))
        #expect(identifiers.contains("aumu:samp:appl"))
        for candidate in candidates {
            #expect(candidate.format == .au)
            let id = try #require(AudioUnitIdentifier(candidate.path))
            #expect(SystemPluginDiscovery.audioUnitTypes.contains(id.type))
            #expect(!candidate.version.isEmpty)
        }
        #expect(SystemPluginDiscovery.audioUnitTypes == [
            kAudioUnitType_Effect, kAudioUnitType_MusicDevice, kAudioUnitType_MusicEffect,
        ])
    }

    @Test("PLUG-002: scanner reports an AU effect")
    func scanEffect() throws {
        let candidate = try #require(SystemPluginDiscovery.audioUnitCandidates().first { $0.path == "aufx:dely:appl" })
        let result = try Fixtures.launcher().scan(candidate)
        let delay = try #require(result.first)
        #expect(result.count == 1)
        #expect(delay.status == .ok)
        #expect(delay.format == .au)
        #expect(delay.identifier == "aufx:dely:appl")
        #expect(delay.name == "AUDelay")
        #expect(delay.vendor == "Apple")
        #expect(!delay.isInstrument)
        #expect(!delay.hasSidechain)
        #expect(delay.numParams > 0)
    }

    @Test("PLUG-002: scanner reports an AU instrument")
    func scanInstrument() throws {
        let candidate = PluginCandidate(format: .au, path: "aumu:samp:appl", mtime: 0, version: "", name: "AUSampler")
        let sampler = try #require(try Fixtures.launcher().scan(candidate).first)
        #expect(sampler.status == .ok)
        #expect(sampler.name == "AUSampler")
        #expect(sampler.isInstrument)
    }

    @Test("PLUG-002: unknown or malformed AU identifiers are blocked, not fatal")
    func scanUnknown() throws {
        let unknown = PluginCandidate(format: .au, path: "aufx:zzzz:zzzz", mtime: 0, version: "", name: "Gone")
        let result = try Fixtures.launcher().scan(unknown)
        #expect(result.map(\.status) == [.blocked])
        #expect(result.first?.reason == "component is not registered")

        let malformed = PluginCandidate(format: .au, path: "nonsense", mtime: 0, version: "", name: "?")
        #expect(try Fixtures.launcher().scan(malformed).first?.reason == "malformed AU identifier")
    }
}
