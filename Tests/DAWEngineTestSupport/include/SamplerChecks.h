#pragma once
// T-041 checks for the Sampler (06 DSP-020..023, DW-096, DW-100), run from
// Tests/DAWEngineTests/SamplerTests.swift. C++ because they drive the node's DAW_RT process()
// inside RtScopes (every check asserts 0 violations, CONV §5.3), GraphBuilder and the Engine.
//
// Most checks feed NodeIO::midiIn directly, splitting a list of events at absolute frames into
// the blocks being rendered, so they control every event exactly. A sampler fed by a
// midiClipPlayer through a RenderGraph (T-045, DW-099) is checked in MidiRoutingChecks.h.

#include "Checks.h"

namespace daw::testing {

// DSP-020: the configJSON zone format: every field, defaults, empty config, unknown keys,
// 64-bit asset IDs, and each malformed or out-of-range input rejected with invalidArgument;
// the registered factory resolves assets through the AssetLookup.
CheckResult samplerParsesZones();

// DSP-020: key and velocity ranges pick zones (inclusive, layered); zone gain; mono to L/R and
// stereo; missing or wrong-rate assets are silent; one-shot voices end at the asset's end;
// loops (clamped to the asset) keep playing.
CheckResult samplerZoneMapping();

// DSP-021: rate 2^((note − root + tune)/12) with Hermite interpolation: rate 1 is bit-exact;
// A4 root playing A5 peaks at 880 Hz ±1 Hz (FFT), as does tune +12 on the root key.
CheckResult samplerPitch();

// DSP-022: ADSR stages on their exact frames (note-on/off mid-block), the velocity curve, and
// the same output bit for bit in any block size (including 1 and 0).
CheckResult samplerEnvelope();

// DSP-022 acceptance "40 notes → 32 voices, no clicks": the 8 oldest are stolen and fade out
// over 5 ms with no step in the output; released notes are stolen before held ones; a burst
// that also fills every fade slot stays bounded.
CheckResult samplerVoiceStealing();

// DSP-023, DW-100: sustain pedal defers note-offs until it goes up; CC 123 releases one
// channel's held notes (the pedal still holds them); pitch bend ±2 semitones from its frame.
CheckResult samplerPedalBendAllNotesOff();

// DW-096: registerBuiltinNodes registers the sampler; the midi_tempo shape (player ─midi→
// sampler → master) builds and renders through GraphBuilder + Engine with 0 RT violations; a
// bad config is rejected at build time.
CheckResult samplerThroughGraphBuilder();

} // namespace daw::testing
