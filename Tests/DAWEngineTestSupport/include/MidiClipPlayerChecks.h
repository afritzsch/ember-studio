#pragma once
// T-040 checks for the MidiClipPlayer (06 DSP-003; TIME-005/006/008 for timeline nodes; DW-051,
// DW-096), run from Tests/DAWEngineTests/MidiClipPlayerTests.swift. C++ because they drive the
// Transport, the Engine (non-movable), GraphBuilder and RtScope.
//
// The RenderGraph doesn't route MIDI yet (midiOut has capacity 0 in a graph), so most checks run
// the player the way Engine::render does: Transport::advance, reset() on a locate while playing,
// then process() into a MidiEventWriter of their own, all inside an RtScope that must count 0
// violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// DSP-003: note-on/off at the frames their ticks sound at, with channel, pitch and velocity;
// offs before ons on the same tick; invalid notes dropped, velocity clamped to 1..127. The same
// events in blocks of 256, 1 and random sizes (note-offs across block boundaries).
CheckResult midiClipPlayerEmitsNotes();

// DSP-003, ENG-004: random notes over a tempo map with changes, rendered in random block sizes
// including 0, give exactly a brute-force oracle's events.
CheckResult midiClipPlayerMatchesOracle();

// DSP-003, TIME-005/006: a note hanging over the loop end gets its off at the wrap frame, before
// the new pass's ons there; notes started before the loop start aren't chased.
CheckResult midiClipPlayerLoopWrap();

// DSP-003, TIME-008: a locate while playing releases every note at frame 0 of the next block;
// a stop does too; play after stop or locate doesn't chase notes already under way.
CheckResult midiClipPlayerLocateAndStop();

// DSP-003 acceptance "no stuck notes after random locates": random locates, stops, plays, loop
// changes and block sizes. No off without its on, no note held past its end at any block end,
// nothing held after a stop; also with a midiOut too small for every event.
CheckResult midiClipPlayerNoStuckNotesFuzz();

// DSP-003, DW-051: a new instance opens its first non-empty block with All Notes Off (CC 123)
// on all 16 channels, once.
CheckResult midiClipPlayerAllNotesOffOnNewInstance();

// DW-096, DW-051: registerBuiltinNodes registers midiClipPlayer (MIDI only); a MIDI track like
// the midi_tempo fixture builds through the real GraphBuilder and renders through the Engine
// with 0 RT violations; each player gets only its own notes, and a configVersion bump makes a
// new instance with the new notes.
CheckResult midiClipPlayerThroughGraphBuilder();

} // namespace daw::testing
