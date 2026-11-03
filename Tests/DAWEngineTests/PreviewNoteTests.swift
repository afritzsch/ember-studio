import DAWEngineTestSupport
import Testing

// T-043 (UI-021): auditioning notes through the engine. EngineFacade::previewNote queues notes in a
// lock-free MidiPreviewInbox; the track's MidiClipPlayer merges them into its MIDI output, so they
// reach the track's instrument. The checks are C++ (Tests/DAWEngineTestSupport/PreviewNoteChecks.cpp)
// because they run the player's DAW_RT process() in RtScopes; every check asserts 0 RT violations
// (CONV §5.3).

@Suite("Preview notes (UI-021)")
struct PreviewNoteTests {
    @Test("UI-021: a preview reaches its own player at frame 0; retrigger, stray offs, clamping, releaseAll")
    func deliversToItsPlayer() { expectPasses(daw.testing.previewInboxDeliversToItsPlayer()) }

    @Test("UI-021, DW-051: a re-created player turns held previews back on after its All Notes Off; no instrument, no notes")
    func survivesRecreatedPlayer() { expectPasses(daw.testing.previewNotesSurviveRecreatedPlayer()) }

    @Test("UI-021: mailboxes are claimed per player and handed on only when empty and silent")
    func mailboxesAreReused() { expectPasses(daw.testing.previewInboxMailboxesAreReused()) }

    @Test("UI-021, DSP-003: random previews over a dense clip in a small writer never hang a note")
    func neverHang() { expectPasses(daw.testing.previewNotesNeverHang()) }

    @Test("UI-021: previewNote on a MIDI track with a sampler sounds on the strip meter; off, stop and locate end it; offline ignores it")
    func throughFacade() { expectPasses(daw.testing.previewNoteThroughFacade()) }
}
