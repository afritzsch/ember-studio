# Autobuild run log

Unattended phases started by `/autobuild` (see `.claude/skills/autobuild/SKILL.md`). Decisions taken without the user are in `DECISIONS.md`.

| Phase | Tasks | Merged | week% start→end | Notes |
|---|---|---|---|---|
| 1 | T-032, T-025, T-042, T-035 | all 4 (T-035, T-025, T-042, T-032) | 0 → 10 | Resumed T-025/T-032 on `-r2` branches; one 5-hour pause (~27 min); DW-148 autosave race fixed; T-045 added |
| 2 | T-023, T-024, T-033, T-036 | all 4 (T-024, T-036, T-033, T-023) | 10 → 23 | 4 h stall: the lead's trial-merge `swift test` hung (DW-168, fixed) through a ~4 h 5-hour-window reset; EACCES flakes fixed (DW-169); `render.offline {loop}` and a facade `peaks` query added; T-026 added |

## Phase notes

### Phase 1 (2026-11-02)
- Wave: T-032 app shell (U+B, resume of `t-032-app-shell`), T-025 M2 goldens (E, resume of `t-025-m2-goldens`), T-042 note commands + instrument slot (M, new), T-035 crossfades (D, new).
- Start: week 0%, five-hour window 26%.
- `git worktree remove` on the merged `t-031-persistence` worktree needs `--force` (it contains submodules), and auto mode denied that. The worktree is left for the user to remove.
- Patchbay can't start a session on a branch whose worktree still exists, and removing those worktrees needs `--force` (submodules), which auto mode denied. So T-025 and T-032 resume on new branches `t-025-m2-goldens-r2` and `t-032-app-shell-r2`, based on the old WIP branches. The old worktrees `t-025-m2-goldens`, `t-031-persistence` and `t-032-app-shell` are left for the user to remove.
- T-035 merged (b5ce53e), then T-025 (898e1b0). The MODEL-044 autosave test flaked 3× under load (DW-148); T-042's worker took it as a follow-up.
- 5-hour window hit 85% at ~1793655150 (epoch). T-032 and T-042 were paused until the reset at 1793656800 + 120 s.
- Resumed both workers at 1793656923 (five-hour window back to 0%).
- T-042 merged (2641e0e), including the DW-148 autosave race fix. Added T-045 (MIDI routing, DW-099) as a ready E-lane task.
- T-032 merged (1bb0c7d). Phase over: 4/4 merged, main green (test.sh 11/11, swift test 2× green), no worker session left open.

### Phase 2 (2026-11-02)
- Wave: T-023 sidechain (E, graph), T-024 metronome (D), T-033 arrange canvas (U), T-036 M3 goldens (E, test-only). Earliest milestones first (M2, M3); T-045 (E, graph) waits for next phase because it overlaps T-023 in `Sources/DAWEngine/graph`.
- Start: week 10%, five-hour window 14%.
- T-024 merged (5f2ebdc). Added T-026 (project metronome wiring, M+B) as ready.
- T-036 merged, including the decided render.offline `loop: true` / ExportSpec.followLoop. The hung T-023 trial-merge `swift test` (4 h+, AttachTests waitUntilExit) and the EACCES flakes (ControlSocketServer process-wide umask) are handed to the T-023 worker. From now on every `swift test` / test.sh runs under a timeout wrapper.
- T-033 merged (peaks query decision logged). T-043 piano roll is now ready.
- T-023 merged with the DW-168 hang fix and the DW-169 umask fix. Every check ran under a timeout: test.sh 11/11, swift test 3× green. T-071 compressor is now ready.
- 5-hour window reached 83% about 30 min into the phase (reset ~4 h later). The workers had finished by then, so no pause was needed; the lead's hung test loop was killed after the reset, as the conductor asked.
- End: week 23%, 5-hour window 17%. main green (test.sh 11/11, timed swift test 3×). No worker session left open.

### Phase 3 (2026-11-03)
- Wave: T-045 MIDI edge routing (E, M4 critical), T-034 toolbar/transport (U, M3), T-026 project metronome (M+B, M2 remainder), T-071 compressor + sidechain golden (D, M7; the only D task with a merged dependency chain into M2's sidechain).
- Start: week 23%, five-hour window 19%.
- T-026's two open questions decided up front (DECISIONS.md): export excludes the click unless `includeMetronome: true`; `SetMetronome` is persisted but not undoable.
- All four workers reported within ~25 min. T-045 merged (4ba14f9), then T-071 (61dccc0; GR-meter encoding decision), then T-026 (c283f6c). The add-only conflicts (module.modulemap, EngineFacade.cpp includes + paramInfoJSON) were resolved by keeping both sides.
- test.sh's swift-test step failed on the T-045 trial merge only on wall-clock load flakes (UI-010 perf smoke, MODEL-044/DW-148 autosave) while four workers tested in parallel; plain swift test was 2× green, and the later trial merges were fully green (DW-172).
- 5-hour window hit 85% at 1793678717 (epoch), ~45 min into the phase. T-034 (finished, waiting for its metronome-button follow-up) paused until the reset at 1793692800 + 120 s.
