#pragma once
// T-052 checks for audio recording (09 REC-001..005). Run from Tests/DAWEngineTests/
// RecordingTests.swift. C++ because they call the recorder's DAW_RT captureBlock in RtScopes,
// drive a Transport by hand and reach the fake driver behind the facade; every capture must count
// 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// REC-001: a RecordFifo takes a block whole or not at all; frames come out in order behind their
// chunk header; a full FIFO refuses the block and keeps what it has; capacity ≥ 2 s at 96 kHz.
CheckResult recordFifoKeepsBlocksWhole();

// REC-001, REC-003, REC-004: two armed tracks on different input pairs record their own pair
// while the transport plays and records (random block sizes), nothing while it doesn't, and a
// block whose transport didn't advance isn't captured twice. finalize() closes 32-bit float stereo
// CAFs in the recordings directory holding exactly the frames captured, with startSample = the
// first captured position − latency; 0 RT violations.
CheckResult recorderCapturesArmedPairs();

// REC-005: with a punch range and the loop off, only frames whose timeline position (q − D) lies
// in [punchIn, punchOut) are written: the take starts at punchIn's sample and is exactly as long
// as the range, at any block split. With the loop on, the punch is ignored.
CheckResult recorderPunchesInAndOut();

// REC-002: with daw.diskwrite stalled, a full FIFO drops whole blocks without blocking the audio
// thread (0 RT violations); droppedFrames() and the take count them; the file gets silence in
// their place, so the audio after the drop is still at its timeline position.
CheckResult recorderDropsWhenWriterStalls();

// REC-003 end to end: a realtime facade on a fake device with distinct input and output latency
// loops its output (a metronome) back to its input. The recorded take, placed at its
// startSample, has each click within ±1 sample of where it was played; recordingFinalized
// carries the file; telemetry shows the input latency and 0 drops; 0 RT violations.
CheckResult facadeRecordsLoopbackAligned();

// IO-021 (2), DW-119, REC-004: losing the device while recording finalizes the take
// (recordingFinalized with frames); stop, setRecording(false) and a change to what's armed end a
// take too, and the next take gets a file of its own. Offline engines record nothing.
CheckResult facadeFinalizesTakes();

} // namespace daw::testing
