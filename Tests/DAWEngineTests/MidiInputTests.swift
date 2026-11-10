import DAWEngineTestSupport
import Foundation
import Testing

// T-053 (09 REC-010..012): MIDI input in the engine. The checks are C++
// (Tests/DAWEngineTestSupport/MidiInputChecks.cpp) because they call MidiInputRouter's DAW_RT
// block functions with synthetic timestamps in RtScopes; each asserts 0 RT violations (CONV §5.3).

@Suite("MIDI input (REC-010..012)")
struct MidiInputTests {
    @Test("REC-010: host time converts to sample time against the device clock anchor (synthetic timestamps)")
    func hostTime() { expectPasses(daw.testing.midiHostTimeConversion()) }

    @Test("REC-011, REC-012: injected notes land at the right block and frame, also on a block boundary, live and recorded (− output latency)")
    func blockBoundary() { expectPasses(daw.testing.midiBlockBoundaryPlacement()) }

    @Test("REC-012: notes are paired on stop; unpaired close at stop; nothing played means no take; a note across a loop wrap ends at the loop end")
    func pairing() { expectPasses(daw.testing.midiPairsNotesOnStop()) }

    @Test("REC-011: inputs merge in time order; a key held by two inputs sounds once; CC 123 ends only that input's notes")
    func merging() { expectPasses(daw.testing.midiMergesInputs()) }

    @Test("T-053: disarm while held, a disappearing input and a re-created player never leave a note or pedal hanging")
    func neverHangs() { expectPasses(daw.testing.midiNeverHangs()) }

    @Test("REC-011: only armed players get live MIDI, in frame order with clip notes; pre-roll doesn't consume it")
    func playerOutput() { expectPasses(daw.testing.midiMergesIntoPlayerOutput()) }

    @Test("T-053: a full queue and a full record buffer are counted, never block, and leave no note hanging")
    func overflow() { expectPasses(daw.testing.midiOverflowIsCounted()) }

    @Test("REC-010..012 through a realtime facade: play-through is audible, the recording lands at sample − output latency; 0 RT violations")
    func throughFacade() { expectPasses(daw.testing.midiThroughFacade()) }

    @Test("REC-010: a real CoreMIDI virtual source appears, connects, plays and disappears without leaving a note hanging")
    func coreMidi() { expectPasses(daw.testing.midiCoreMidiVirtualSource()) }
}
