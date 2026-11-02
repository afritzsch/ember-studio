# Autobuild decisions

Decisions an autobuild lead took without the user (`/autobuild`, see `.claude/skills/autobuild/SKILL.md`). Review them; anything here can be reverted. The `SPEC.md` decision log is untouched.

| Date | Phase | ID | Question | Options | Choice | Why |
|---|---|---|---|---|---|---|
| 2026-11-02 | 1 | T-042 Q1 | T-042's briefing asked for an audible end-to-end check (MIDI track + sampler + notes renders non-silent), but MIDI edges carry no data yet (DW-099, E lane). Merge now or wait? | (a) merge now, move the audible check to the DW-099 task / T-044; (b) hold T-042 until DW-099 lands | (a) | Everything up to the engine boundary is verified (the real engine accepts the graph with the sampler configJSON, 0 RT violations). DW-099 is outside T-042's modules, and holding it would block T-043/T-044 for no gain. |
| 2026-11-02 | 1 | T-042 validate | T-042 tightened `validate()`: note velocity must be 1…127 (0 was allowed), so a saved project with a velocity-0 note no longer opens (`invalidProject`). Accept? | (a) accept; (b) have open repair velocity 0 → 1 | (a) | 06 already clamps velocity to 1…127 in the MidiClipPlayer, no note command can write 0, and no projects exist outside tests. Logged as DW-150 in case real files ever need a repair. |
| 2026-11-02 | 1 | T-035 overlap | T-035 made a missing-asset clip still hide the clip under it (with silence). Accept, or let unplayable clips reveal what's under them? | (a) coverage depends only on the clips; (b) unplayable clips are transparent | (a) | The result depends only on the timeline, not on load state, so a render doesn't change when an asset finishes loading. It's a one-line change if the user prefers (b). |
