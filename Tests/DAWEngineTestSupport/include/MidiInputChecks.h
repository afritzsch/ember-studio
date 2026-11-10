#pragma once
// T-053 checks for MIDI input and recording (09 REC-010..012). Run from Tests/DAWEngineTests/
// MidiInputTests.swift. C++ because they call MidiInputRouter's DAW_RT block functions and the
// MIDI clip player in RtScopes with synthetic timestamps; every block must count 0 RT violations
// (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// REC-010: host time → sample time against the device clock anchor, synthetic timestamps; a
// received event struck during an earlier block is recorded where it was struck.
CheckResult midiHostTimeConversion();

// REC-011, REC-012: injected notes land in the right block at the right frame, also right on a
// block boundary, both live and in the recording (minus the output latency).
CheckResult midiBlockBoundaryPlacement();

// REC-012: paired notes, an unpaired note closed at stop, an off with no on ignored, nothing
// played means no take; notes held across a loop wrap end at the loop end.
CheckResult midiPairsNotesOnStop();

// REC-011: inputs merge in time order; the same key from two inputs sounds once and ends with the
// last release; a controller panic (CC 123) ends only that input's notes.
CheckResult midiMergesInputs();

// T-053 notes: disarming with a key down, an input disappearing, and a re-created player: no note
// or pedal ever hangs. 0 RT violations.
CheckResult midiNeverHangs();

// REC-011: only armed players get live input; live events interleave in frame order with clip
// notes; pre-roll blocks don't consume them.
CheckResult midiMergesIntoPlayerOutput();

// T-053 notes: a full queue and a full record buffer are counted, never block, and leave no note
// hanging. 0 RT violations.
CheckResult midiOverflowIsCounted();

// REC-010..012 end to end: a realtime facade on the fake device plays an injected note through a
// sampler (audible on the strip meter) and records it, placed at its transport sample − output
// latency, to the sample. 0 RT violations. Offline engines refuse injection.
CheckResult midiThroughFacade();

// REC-010 against the real CoreMIDI: a virtual source appears, is connected, delivers a note, and
// disappears, which ends its held note. Passes without checking anything when the system has no
// MIDI server (DAW_SKIP_DEVICE_TESTS, or a client can't be created).
CheckResult midiCoreMidiVirtualSource();

} // namespace daw::testing
