#pragma once
// T-043 checks for preview notes (12 UI-021, 08 "Contract delta (T-043)"): EngineFacade::previewNote
// queues notes in a MidiPreviewInbox (nodes/MidiClipPlayer.h) that the track's MidiClipPlayer
// merges into its MIDI output. Run from Tests/DAWEngineTests/PreviewNoteTests.swift. C++ because
// they drive the player's DAW_RT process() in RtScopes and the facade's internals; every render
// must count 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// UI-021: posts reach their own player only, at frame 0 on channel 1, transport stopped or
// playing (before the player's own events, in frame order); velocity clamped to 1..127; an on for
// a held pitch retriggers (off, on); an off for a pitch that isn't held is dropped; releaseAll
// turns off every held note; bad posts (player 0, pitch > 127) are refused.
CheckResult previewInboxDeliversToItsPlayer();

// UI-021, DW-051: a re-created player (same NodeID) sends its All Notes Off and then turns the
// held previews back on, once each even when the same on is still queued; a player without MIDI
// storage (no instrument) writes nothing and holds nothing.
CheckResult previewNotesSurviveRecreatedPlayer();

// UI-021: kMailboxes players can hold notes at once; one more is refused until a mailbox is empty
// and holds nothing, which is then handed on; the old owner no longer sees its events.
CheckResult previewInboxMailboxesAreReused();

// UI-021, DSP-003: random previews over a dense clip in a small writer, random block sizes,
// play/stop/locate: no off without its on, frame order kept, and after releaseAll and a stop
// nothing is held (the player's reserve covers preview offs).
CheckResult previewNotesNeverHang();

// UI-021 end to end on the realtime facade (fake device): previewNote on a MIDI track with a
// sampler is audible on the track's strip meter with the transport stopped, ends with its off,
// and stop() and locate() end a held one; offline mode ignores note-ons (an export renders no
// preview); 0 RT violations.
CheckResult previewNoteThroughFacade();

} // namespace daw::testing
