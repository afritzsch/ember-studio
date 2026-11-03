#pragma once
// T-045 checks for MIDI edge routing (DW-099; 06 DSP-003, 05 MIX-001 and MIX-021 for MIDI
// edges), run from Tests/DAWEngineTests/MidiRoutingTests.swift. C++ because they drive the Engine
// (non-movable), GraphBuilder, RenderGraph internals and RtScope. Every render runs in an RtScope
// that must count 0 violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// DSP-003, MIX-001: a player → instrument MIDI edge carries the player's events. The instrument's
// midiIn is the player's written() span itself (no copy); the player's step has
// GraphBuilder::kMidiCapacity, a step without outgoing MIDI edges none. Events land at the
// frames their ticks sound at, in random block sizes; a fan-out edge gives a second consumer the
// same events.
CheckResult midiRoutingPlayerToInstrument();

// MIX-001, DW-099: two players into one instrument merge in frame order, stable for equal frames
// (description order of the edges), with nothing dropped: each block's midiIn equals the stable
// merge of the players' outputs, over random notes and random block sizes; swapping the edge
// order swaps the ties.
CheckResult midiRoutingMergesInFrameOrder();

// DW-099 (no hanging notes when a snapshot swaps): dense notes that overflow the player's
// fixed-capacity writer, rebuilds every few blocks, locates, loop changes and stops in random
// block sizes. The capacity is the same in every graph, no off reaches the instrument without
// its on, and after a stop nothing is held.
CheckResult midiRoutingNoHangingNotesAcrossSwaps();

// MIX-021 for MIDI: a MIDI edge into a node whose audio input runs through a latent node is
// delayed by the difference, so a note-on and an audio impulse on the same tick reach the
// instrument on the same frame and both come out at the timeline sample (MIX-023). A rebuild
// while the event is in flight carries the MIDI delay line over by edge ID (bit-identical to no
// rebuild); with a new edge ID the in-flight event is gone (the control).
CheckResult midiRoutingPdcDelaysMidiEdges();

// MIX-021/022 for MIDI, MidiDelayLine on its own: events come out `delay` frames later in random
// block sizes; a changed delay keeps order and loses nothing; at most maxOut() leave per block,
// the rest late but in order; overflow drops note-ons and other events, never the off of a note
// (or the pedal-up of a pedal) it let through, and counts drops; CC 123 releases the reserve.
CheckResult midiDelayLineSemantics();

// DW-099 end to end: through the EngineFacade (offline), midiClipPlayer → sampler → strip →
// master with a 440 Hz sine zone rooted at A4 renders A5 at 880 Hz (±1 Hz), audible during the
// note, silent after its release, with 0 RT violations.
CheckResult midiTrackWithSamplerThroughFacade();

} // namespace daw::testing
