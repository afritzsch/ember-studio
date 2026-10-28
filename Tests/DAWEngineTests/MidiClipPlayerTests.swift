import DAWEngineTestSupport
import Testing

// T-040: the MidiClipPlayer (06 DSP-003) as a timeline node (03 TIME-005/006/008): note events at
// exact frames and no hanging notes across locates, loop wraps and stops. Also its registration
// and note delivery through the real GraphBuilder (DW-051, DW-096). The checks are C++
// (Tests/DAWEngineTestSupport/MidiClipPlayerChecks.cpp) because they drive the Transport, Engine,
// GraphBuilder and RtScope; every check asserts its scopes counted 0 RT violations (CONV §5.3).

@Suite("MidiClipPlayer (DSP-003)")
struct MidiClipPlayerTests {
    @Test("DSP-003: note-on/off at their frames, offs before ons on a tick, invalid notes dropped; any block size")
    func emitsNotes() { expectPasses(daw.testing.midiClipPlayerEmitsNotes()) }

    @Test("DSP-003, ENG-004: random notes over a tempo map in random block sizes match an oracle")
    func matchesOracle() { expectPasses(daw.testing.midiClipPlayerMatchesOracle()) }

    @Test("DSP-003, TIME-006: a note hanging over the loop end ends at the wrap frame, before the new pass")
    func loopWrap() { expectPasses(daw.testing.midiClipPlayerLoopWrap()) }

    @Test("DSP-003, TIME-008: locate while playing and stop release held notes; no chasing")
    func locateAndStop() { expectPasses(daw.testing.midiClipPlayerLocateAndStop()) }

    @Test("DSP-003: no stuck notes after random locates, stops, loop changes and block sizes")
    func noStuckNotesFuzz() { expectPasses(daw.testing.midiClipPlayerNoStuckNotesFuzz()) }

    @Test("DSP-003, DW-051: a new instance starts with All Notes Off on all 16 channels, once")
    func allNotesOffOnNewInstance() { expectPasses(daw.testing.midiClipPlayerAllNotesOffOnNewInstance()) }

    @Test("DW-096, DW-051: midiClipPlayer is registered, builds and renders through GraphBuilder + Engine")
    func throughGraphBuilder() { expectPasses(daw.testing.midiClipPlayerThroughGraphBuilder()) }
}
