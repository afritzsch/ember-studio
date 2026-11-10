# Autobuild run log

Unattended phases started by `/autobuild` (see `.claude/skills/autobuild/SKILL.md`). Decisions taken without the user are in `DECISIONS.md`.

| Phase | Tasks | Merged | week% start→end | Notes |
|---|---|---|---|---|
| 1 | T-032, T-025, T-042, T-035 | all 4 (T-035, T-025, T-042, T-032) | 0 → 10 | Resumed T-025/T-032 on `-r2` branches; one 5-hour pause (~27 min); DW-148 autosave race fixed; T-045 added |
| 2 | T-023, T-024, T-033, T-036 | all 4 (T-024, T-036, T-033, T-023) | 10 → 23 | 4 h stall: the lead's trial-merge `swift test` hung (DW-168, fixed) through a ~4 h 5-hour-window reset; EACCES flakes fixed (DW-169); `render.offline {loop}` and a facade `peaks` query added; T-026 added |
| 3 | T-045, T-071, T-026, T-034 | all 4 (T-045, T-071, T-026, T-034) | 23 → 33 | MIDI edges audible (A5 at 880 Hz), compressor + `sidechain_compressor` golden, project metronome (export excludes the click; not undoable), toolbar/shortcuts; one 5-hour pause (~4 h, only T-034's follow-up waited); load flakes logged (DW-172) |
| 4 | T-044, T-073, T-056, T-043 | all 4 (T-044, T-073, T-056, T-043) | 34 → 49 | M4 complete (M4 goldens, piano roll + previewNote); reverb + `reverb_determinism`; session-rate change with asset re-conversion; one 5-hour pause (~4 h); T-052/053/061/062 found `ready` |
| 5 | T-052, T-061, T-055, T-072 | all 4 (T-055 part 1, T-072, T-052, T-072 follow-up, T-055 follow-up, T-061) | 50 → 75 | User-authorized final phase (week ≥ 50%). Recording (REC-001..005), AU hosting, audio prefs + arm/monitor, delay; DW-148/DW-172 autosave flakes fixed at the root (MODEL-041 blocked the main actor); two 5-hour pauses and a Mac sleep |
| 6 | T-053, T-062, T-070, T-076 | all 4 (T-076, T-062, T-070, T-053) + DW-214 AU crash fix | 1 → 20 | New run (week reset). M5 needs only T-054; VST3 + EQ + mixer done; `NodeRegistry::paramInfo` and `nanBlocks` telemetry; a production AU teardown crash found and fixed; one 5-hour pause (~4 h, T-076 merged during it) |
| 7 | T-054, T-064, T-074, T-082 | all 4 (T-082, T-064, T-054, T-074) | 20 → 42 | Final phase (user asked to stop after it). M5 complete (input monitoring); host bypass + NaN guard + safe mode; automation lanes + player; export dialog with normalize. Two 5-hour pauses (~3.7 h, ~4 h); T-082/T-064 merged during the second. UI-010 perf smoke failed in most full runs (load, DW-223) |

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
- Resumed T-034 at 1793692983 (five-hour window 0%). It merged main and added the `transport.metronome` toolbar toggle. T-034 merged (190deac). T-055 is now ready.
- End: 4/4 merged, main green (test.sh 11/11, timed swift test 2×), no worker session left open.

### Phase 4 (2026-11-03)
- Wave: T-044 M4 goldens (D, test-only), T-043 piano roll + audition (U, M4; `previewNote` pre-decided), T-056 session-rate change (E+M, M5; undo/events pre-decided), T-073 reverb (D, M7; new files only, disjoint from T-044).
- Start: week 34%, five-hour window 12%.
- Pre-decisions in DECISIONS.md: T-043 `previewNote` facade addition; T-056 `SetSessionSampleRate` history-exempt and follows engine-side rate changes (DW-130); T-056 additive progress events pre-accepted.
- T-044 merged (6c3a229): test.sh failed only on DW-172 load flakes; plain swift test green. Worker closed.
- 5-hour window hit 86% at 1793695307 (epoch), ~45 min into the phase. T-043 and T-073 paused (T-056 had just reported); sleeping until the reset at 1793710800 + 120 s.
- Resumed T-043, T-073, T-056 at 1793711078 (five-hour window 0%).
- T-073 merged (540ad43): test.sh 11/11, swift test green. The worker fixed EngineClientTests' reverb param check after merging main.
- T-056 merged (56b793c): module.modulemap add-only conflict kept both sides; test.sh 11/11, swift test green.
- T-043 merged (4a35541) after its worker merged main (T-056 conflicts in shared files, kept both) and fixed the arrange peak invalidation (one drop per pass). Marked T-052, T-053, T-061, T-062 `ready` (all deps were done).
- End: 4/4 merged, M4 complete, main green (plain swift test green after every merge; test.sh failed only on DW-172 flakes), week 49%, no worker session left open.

### Phase 5 (2026-11-03, user-authorized final phase)
- The user authorized one more phase although week ≥ 50% (WEEK_STOP). This is the last phase of the run.
- Wave: T-052 audio recording (E+M+B, M5 core), T-061 AU hosting (P, M6), T-055 audio preferences + toasts + session-rate UI, arm/monitor buttons after T-052 (U, M5), T-072 delay (D, M7; closes DW-162's real-tail check).
- Start: week 50%, five-hour window 42%.
- Pre-decisions in DECISIONS.md: T-052 additive contract + history-exempt `ArmTrack`/`SetMonitoring`; T-061 configJSON + additive contract, analysis-based golden; T-055 ordering.
- 5-hour window hit 89% at 1793713776 (epoch), ~20 min into the phase (week 56%). All four workers paused until the reset at 1793728800 + 120 s.
- Resumed all four workers at 1793729332 (five-hour window 0%, week 57%).
- 1793736878: the Mac slept ~19:20; all four workers' turns died ('computer went to sleep'). Sent each 'continue' at five 29%, week 61%.
- T-055 part 1 merged (f98f2e0): audio preferences, device toasts, session-rate UI. test.sh 11/11; plain swift test only DW-172 flakes. The worker stays open for the arm/monitor buttons after T-052.
- T-072 merged (1fc9162). T-052 reported (test.sh 11/11 on its branch); trial merge clean. 5-hour window hit 85% at 1793741071: T-061 and T-072 (follow-up: DW-148 test seam) paused until 1793746800 + 120 s; T-055 idle (queued).
- T-052 merged (46d17e7): test.sh 11/11. Worker closed. T-054 and T-080 now ready.
- Resumed T-061 and T-072 at 1793746900 (five 0%, week 69%); T-055 started its follow-up (arm/monitor buttons, recording toasts, DW-198, DW-200).
- T-072 follow-up merged (3b6bcb1): DW-148 autosave tests now deterministic, MODEL-041 spin off the main actor; test.sh 11/11. Worker closed.
- T-055 follow-up merged (94450af): track-header arm/monitor/input controls, recording toasts, DW-198/200; test.sh 11/11. T-055 done; worker closed.
- T-061 merged (c943dbf) after a small app follow-up (app saves capture live AU state, DW-143): test.sh 11/11. T-064 and T-074 now ready. Worker closed.
- End: 4/4 merged, main green (test.sh 11/11 on the last trial merge), week 75%, five-hour window 46%, no worker session left open. Run stopped as the user asked (final phase).

### Phase 6 (2026-11-09)
- New run after the phase-5 stop (week reset). Wave: T-053 CoreMIDI + MIDI recording (E, M5), T-062 VST3 hosting (P, M6), T-070 EQ (D, M7; also closes DW-173 `NodeRegistry::paramInfo`), T-076 mixer view (U, M7; includes DW-202). T-054 waits for the next phase (one E task per wave).
- Start: week 1%, five-hour window 4%.
- Pre-decisions in DECISIONS.md: T-053 contract, routing and placement; T-062 contract and test plugin; T-070 registry; T-076 inserts and faders.

- 5-hour window hit 85% at 1794264908 (epoch), ~44 min into the phase (week 11%). T-053, T-062, T-070 paused until the reset at 1794279600 + 120 s; T-076 had reported and waits for review.

- T-076 merged during the pause on a quiet machine: test.sh 11/11, swift test 2× green. Worker closed. M7's mixer view done; DW-202 closed.

- Resumed T-053, T-062, T-070 at 1794279732 (five-hour window 0%, week 12%).

- T-062 merged: test.sh 12/12 (new `test-plugins` stage), swift test 2× green. Worker closed. T-063 (plugin editors) now ready.

- T-070 merged (EQ, `NodeRegistry::paramInfo`, `nanBlocks` telemetry, sampler NaN guard, `routing` fixture through EngineClient). test.sh failed only on the AUDelay param flake (DW-214, also seen by T-053 without T-070); plain swift test 2× green. T-070's worker takes DW-214 as a follow-up.

- T-053 merged after its worker merged main twice (T-062's chained `registerNodes`, T-070's telemetry fields; kept both): test.sh 12/12, swift test 2× green. Worker closed. M5 now needs only T-054.

- DW-214 merged (T-070's follow-up): destroying a V2 AU right after parameter events crashed in Apple's `AUAudioUnitV2Bridge` listener (production-reachable: removing a device, rate change, engine teardown), and concurrent V2 init/uninit aborted. Fixed with a deferred release and a lifecycle lock; mutation-checked (5/5 crashes before, 8/8 × 1500 teardowns clean after). test.sh 12/12, swift test 2× green. Worker closed.

- End: 4/4 merged plus the DW-214 fix, main green (test.sh 12/12, swift test 2× after the last merge), week 20%, five-hour window 61%, no worker session left open. Next: phase 7.

### Phase 7 (2026-11-10)
- Wave: T-054 input monitoring (E, M5: last M5 task), T-064 host bypass / NaN guard / crash marker (P, M6), T-074 automation (E+M, M7; owns the new `automation/` modules), T-082 export dialog (U, M8). T-063 waits (P+U overlaps T-064 and T-082); T-080 waits (E+M overlaps T-054 and T-074).
- Start: week 20%, five-hour window 63% (reset at 1794297600).
- Pre-decisions in DECISIONS.md: T-054 contract and `auto` evaluation; T-064 bypass command, crash marker and NaN event; T-074 contract; T-082 normalize and selection.
- 5-hour window hit 87% at 1794284253 (epoch), ~13 min after the workers started (week 23%). All four paused until the reset at 1794297600 + 120 s.
- The conductor relayed that phase 7 is the user's final phase of this run (stop after it).
- Resumed all four workers at 1794297774 (five-hour window 0%, week 25%). T-074 allowed small additive core/nodes edits for the AUTO-003 wrap jump (DECISIONS "T-074 wrap jump").
- 5-hour window hit 86% at 1794300937 (~53 min after the resume; week 37%). T-054, T-064, T-074 paused until 1794315600 + 120 s; T-082 had reported and its trial merge runs during the pause.
- T-082 merged (ecad572) during the pause: test.sh 11/12 and one of two swift test runs failed only on the UI-010 perf smoke (load from other apps, load average 26–34; DW-223); UI-010 alone 3× green. Worker closed.
- T-064 merged (9fbb025) during the pause (it had finished; only an optional UI-010 baseline was open): 08 conflict kept both contract deltas; test.sh 11/12 and swift test 2× failed only on UI-010 (alone 3× green). Worker closed. T-083 now ready.
- Resumed T-054 and T-074 at 1794315741 (five-hour window 0%, week 37%), each told to `git merge main` first.
- T-054 merged: test.sh 11/12 (only UI-010, DW-223), swift test 2× green. Worker closed. M5 complete.
- T-074 merged after its worker merged main twice (T-064/T-082, then T-054; kept both sides): test.sh 12/12, swift test 2× failed only UI-010 (DW-223). Worker closed. T-075 and T-077 now ready.
- Lead spec items: DW-187, DW-188, DW-195 done.
- End: 4/4 merged, main green apart from the UI-010 load flake (T-074 trial merge test.sh 12/12), week 42%, five-hour window 31%, no worker session left open. Run stopped as the user asked (final phase).

## Summary for the user

This run (the second) had two phases, 6 and 7 (2026-11-09 → 2026-11-10). The week went 1% → 42%. It stopped after phase 7 because you asked.

**Merged in this run (8 tasks plus one crash fix, all on `main`, pushed):**
- Phase 6:
  - T-053 CoreMIDI + MIDI recording, T-062 VST3 hosting, T-070 EQ, T-076 mixer view.
  - DW-214: a real crash when an Apple V2 AU was destroyed right after parameter changes. Fixed with a deferred release plus a lifecycle lock.
- Phase 7:
  - T-054 input monitoring, which **completes M5**.
  - T-064 host bypass, plugin NaN guard and crash marker + safe-mode open.
  - T-074 automation lanes, player and plugin param path.
  - T-082 export dialog, with a new normalize option.
- Milestones:
  - M2–M5 are complete.
  - M6 still needs T-063 (plugin editors) and T-065 (device chain UI).
  - M7 still needs T-075 (automation recording + lane UI) and T-077 (M7 goldens).
  - M8 still needs T-080, T-081, T-083 and T-084.

**Decisions to review:** `docs/autobuild/DECISIONS.md` gained 16 rows in this run (phases 6–7), all taken without you. Each row says what to change if you disagree. The biggest ones:
- Arming a track is now structural (a new graph), and the default `auto` mode monitors an armed track while it records.
- Bypassed devices now stay in the graph behind a latency-matched pass-through. Safe mode bypasses every plugin for the session only, without writing to the document.
- Automation edits are undoable, and adding points creates the lane.
- Export normalize targets −0.1 dBFS.
- Every source reaches every armed MIDI track (there is no input picker yet).

Open questions only you can answer are in `docs/handover/HANDOVER.md` → *Open questions for the user*. New ones: the export dialog's "Choose…" needs a manual check (DW-222); monitoring has no feedback protection (DW-230); and should removing a send or device also delete its automation lanes (DW-234)?

**Tasks parked:** none. No task was stopped unfinished, and there are no `wip` tasks or WIP branches. 5 tasks are `ready`: T-063, T-075, T-077, T-080, T-083.

**Flaky test to know about:** UI-010's perf smoke (`perFrame < 16 ms`) failed in most full test runs in phase 7, even with the workers paused, because other apps were loading the machine. It passes alone every time (DW-223). Every merge was judged by that.

**Permission prompts that blocked work:** none in this run. `git worktree remove --force` is still denied in auto mode, so merged worktrees stay on disk; the list is in HANDOVER → *Sessions only the user can close*.

**Sessions you should close:** the conductor ("macDAW") once it reports. Every phase-7 worker is closed, and this lead (7) is closed by the conductor.

### Earlier run (phases 1–5)

The run had five phases (2026-11-02 → 2026-11-04). The week went 0% → 75%; phase 5 ran past WEEK_STOP because you authorized it.

**Merged in this run (20 tasks, all to `main`, pushed):**
- Phase 1: T-032 app shell, T-025 M2 goldens, T-042 note commands + instrument slot, T-035 crossfades.
- Phase 2: T-024 metronome node, T-036 M3 goldens (+ loop-following render), T-033 arrange canvas (+ facade `peaks`), T-023 sidechain.
- Phase 3: T-045 MIDI edge routing, T-071 compressor + sidechain golden, T-026 project metronome, T-034 toolbar/shortcuts.
- Phase 4: T-044 M4 goldens, T-073 reverb, T-056 session-rate change, T-043 piano roll + audition. **M4 complete.**
- Phase 5: T-052 audio recording, T-072 delay, T-055 audio preferences + arm/monitor controls, T-061 AU hosting.
- Milestones: M2, M3 and M4 are complete. M5 needs T-053 (CoreMIDI) and T-054 (monitoring). M6 needs T-062 (VST3), T-063 and T-064. M7 needs T-070 (EQ), T-074/075 and T-077.
- Flake fixes along the way: DW-148 autosave race (phase 1), DW-168 test hang and DW-169 EACCES (phase 2), DW-148/DW-172 autosave tests made deterministic plus MODEL-041 off the main actor (phase 5).

**Decisions to review:** `docs/autobuild/DECISIONS.md` has 18 rows (phases 1–5), all taken without you. Each says what to change if you disagree. The biggest ones:
- the contract additions (`peaks`, `previewNote`, `followLoop`, the T-052 recording API, the T-061 AU configJSON);
- the history-exempt commands (`SetMetronome`, `SetSessionSampleRate`, `ArmTrack`, `SetMonitoring`);
- the metronome being excluded from exports;
- analysis-based AU goldens.

The open questions only you can answer are listed in `docs/handover/HANDOVER.md` → *Open questions for the user*.

**Tasks parked:** none. No task was stopped unfinished, and there are no `wip` tasks or WIP branches. 9 tasks are `ready` (T-053, T-054, T-062, T-064, T-070, T-074, T-076, T-080, T-082).

**Permission prompts that blocked work:**
- `git worktree remove --force` (worktrees contain submodules) is denied in auto mode. That's why the merged worktrees are still on disk; the list is in HANDOVER → *Sessions only the user can close*. Allowlisting it, or removing them by hand, would clean up.
- No other prompt blocked a worker. One worker command in phase 5 was "Not run · auto mode's check had no usable answer" during the Mac sleep; the worker took another route.

**Sessions you should close:** the conductor ("macDAW") and older "macDAW"/"garminWatch" sessions in the sidebar. Every autobuild worker and phase lead 1–4 is closed; this lead (5) is closed by the conductor.
