You are AUTOBUILD phase lead 7. Read CLAUDE.md, then `.claude/skills/autobuild/SKILL.md`, then follow "Orchestrating with Patchbay" in specs/90-tasks.md. Use the Patchbay MCP tools for workers, never the Agent tool. The run log is `docs/autobuild/RUN.md` and the decisions taken without the user are in `docs/autobuild/DECISIONS.md`.

## State at handoff (2026-11-10, end of autobuild phase 6; main @ the "Autobuild phase 6: handover" commit, pushed; clean; no worker sessions running)
- Phase 6 merged all four wave tasks plus one flake fix:
  - **T-076** mixer view (UI-030, 031, 033; DW-202): bottom-pane Mixer tab, one strip per track/bus/master, custom fader/pan controls (gesture = one undo step, `ui.perform` nudge/reset ids), display-rate meters (`MeterBank` + one `MeterClockView` display link per mixer, not @Observable), routing pickers that show the model's cycle error as a toast. `ui.state` windows[].mixer; 12 "Mixer details".
  - **T-062** VST3 hosting (PLUG-011..016 for VST3): `plugins/VST3*`, one instance per slot like AU, configJSON `{identifier: "path#classUID", state}`, `EVS3` state container (component + controller), own fixed-capacity `IEventList`/`IParameterChanges` (0 RT violations). Test bundles from `scripts/build-test-vst3.sh` → `.build/test-plugins/{again,EmberTest}.vst3` (clang++ only; a new `test-plugins` stage in test.sh, so it now has **12** stages). VST3 params are normalized 0…1 (DW-213).
  - **T-070** EQ (DSP-030, 040, 041): `NodeKind::eq` (4 bands + HP/LP, RBJ TDF-II), `NodeRegistry::paramInfo(NodeKind)` now feeds `paramInfoJSON` for every built-in kind, additive `nanBlocks` telemetry (EQ, compressor, delay, reverb, sampler), `routing` fixture through EngineClient. Closed DW-074/078/092/096/141/142/173.
  - **T-053** CoreMIDI + MIDI recording (REC-010..012): `daw.midi` thread (CONV §3), per-source `SpscQueue<MidiInEvent>`, live play-through into armed tracks' `MidiClipPlayer`, notes recorded at sample − output latency, one undoable "Record" per track. `midi.inputs` / `midi.inject` (control + tools) for tests without hardware; CoreMIDI only for the default CoreAudio realtime engine.
  - **DW-214 fix (on T-070's branch):** destroying a V2 AU (AUDelay, AUSampler, most third-party AUs) soon after parameter events crashed in Apple's `AUAudioUnitV2Bridge` listener block, and V2 AU initialize/uninitialize on two threads aborted in CoreAudio. `AUInstance` now defers a bridged unit's last release by 1 s on a serial queue and serializes prepare/teardown under a process-wide lifecycle lock (non-RT). Regression suite "AU teardown (DW-214)".
- Done & merged (56): T-001..T-026, T-030..T-036, T-040..T-045, T-050..T-053, T-055, T-056, T-060..T-062, T-070..T-073, T-076, T-085..T-087.
- No `wip` tasks.
- **Ready (6):** T-054 input monitoring (E, M5: the last M5 task), T-063 plugin editors (P+U, M6), T-064 host bypass/NaN guard/crash marker (P, M6), T-074 automation (E+M, M7), T-080 loop takes/comping (E+M, M8), T-082 export dialog (U, M8).
- Discovered work runs DW-001..DW-218. New this phase: DW-206..218 (mixer Instruments check, stereo meters, VST3 editor/vstgui shim, VST3 restart flags, VST3 MIDI CC, offline processing flag, shared plugin-host template, VST3 normalized params, the AU flake (fixed), MIDI CC/pedal not recorded, no MIDI input picker, AU instantiate outside the lifecycle lock, VST3 teardown race unexamined).
- Last trial merges: T-076 11/11, T-062 12/12, T-070 11/12 (only the DW-214 flake, then fixed), T-053 12/12, DW-214 follow-up 12/12; plain `swift test` 2× green after every merge.
- Phase 6 week usage: 1% → 20% (one 5-hour pause of ~4 h, 44 min into the phase).

## Suggested next wave
- **T-054** input monitoring (E, M5): finishes M5. REC-020..022; T-053 decided that MIDI play-through ignores the monitoring mode (DECISIONS "T-053 routing").
- **T-064** host bypass / NaN guard / crash marker (P, M6) or **T-063** editors (P+U, M6): one P task per wave. T-063 needs vstgui4 or its own `IPlugView` test plugin (DW-208) and the plugin → model param path (DW-204). T-064 can reuse `nanBlocks` and the DW-214 lifecycle lock.
- **T-074** automation (E+M, M7): AU and VST3 param paths exist now (AUTO-009). It's E like T-054: check file overlap (T-054 is graph/strip/record; T-074 is a new AutomationPlayer + model lanes) before running both.
- **T-082** export dialog (U, M8): DW-177 (leave the click out by default).
- Small lead items: DW-187/188/195 (spec text), and spec 10 text for the DW-214 deferred V2 release.

## Decisions taken this phase (see docs/autobuild/DECISIONS.md)
- T-053: additive contract; every source reaches every armed MIDI track, play-through ignores monitoring; notes at sample − output latency, one undoable Record.
- T-062: same configJSON/pluginInfoJSON shape as T-061; a real `.vst3` bundle built by script; analytic golden.
- T-070: `NodeRegistry::paramInfo` built now; additive `nanBlocks` telemetry.
- T-076: inserts list read-only until DW-149; custom fader/pan controls with `ui.perform` ids.
- Not logged as user decisions (accepted at review): T-076 shows monitoring on MIDI strips (as their headers do) and appends channel names to the cycle toast; T-053 drops a live note-on older than 1 s.

## Sessions only the user can close
- In the sidebar: the "macDAW" conductor session (it closes phase leads itself). Phase lead 6 closed all its own workers; "Autobuild lead 5" and the older "macDAW" session are already gone.
- Worktrees left on disk (removing them needs `--force` because of submodules, which auto mode denies). All are merged or superseded:
  - `~/.patchbay/worktrees/macDAW/t-023-sidechain`, `t-024-metronome`, `t-025-m2-goldens`, `t-025-m2-goldens-r2`, `t-026-project-metronome`, `t-031-persistence`, `t-032-app-shell`, `t-032-app-shell-r2`, `t-033-arrange-canvas`, `t-034-toolbar-transport`, `t-035-crossfades`, `t-036-m3-goldens`, `t-042-note-commands`, `t-043-piano-roll`, `t-044-m4-goldens`, `t-045-midi-routing`, `t-052-audio-recording`, `t-055-audio-prefs`, `t-056-session-rate`, `t-061-au-hosting`, `t-071-compressor`, `t-072-delay`, `t-073-reverb`;
  - new this phase: `t-053-coremidi`, `t-062-vst3-hosting`, `t-070-eq`, `t-076-mixer-view`.
  - Remove them with `git worktree remove --force <path>`, then `git branch -D <branch>`. The old remote WIP branches `origin/t-025-m2-goldens`, `t-031-persistence` and `t-032-app-shell` can be deleted too.

## Environment note: CoreAudio
- On 2026-10-28 CoreAudio delivered no IO cycles for a while (environmental). Since then the CoreAudio device tests have passed normally (phases 1 and 2).
- Only if they fail with 0 cycles, use `DAW_SKIP_DEVICE_TESTS=1` and say so in merge commits.

## Lessons (keep following these)
- **Starting workers:** start them a few seconds apart. After each new_session, wait_for until its status is "Working". "Running" means the .patchbay.json setup is still going (now includes the dawmcp build).
- **Waiting on workers:**
  - Patchbay's status flaps to "Waiting for prompt"/"Done" while a worker runs a long foreground command, so wait_for often returns early.
  - Instead, run a background bash loop that watches the REPORT.md files: touch a marker, then loop over `~/.patchbay/worktrees/macDAW/*/REPORT.md` with `[ "$f" -nt marker ]` every 30 s. It notifies you when any worker writes or updates its report.
  - Check a worker with read_output only when needed.
- **Briefings:** use the template in 90-tasks.md, plus:
  - the other running tasks' files, marked "do NOT touch";
  - the shared add-only files (Package.swift, `Tests/DAWEngineTestSupport/include/module.modulemap`, `CommandRegistry.swift`);
  - "also write the report to an untracked REPORT.md (don't commit it)";
  - the CoreAudio fallback note above.
  - Read reports with the Read tool; read_output only shows the last screen.
- **Approvals and interface changes:**
  - Workers may claim "the user approved" something; verify with the user before accepting.
  - Any PROPOSED Interfaces change → AskUserQuestion, then relay the answer with send_input. Example: T-051's spec 08 delta, accepted, worker updated the heading to "accepted".
- **Review:**
  - `git diff --stat main...<branch>` for scope.
  - Trial merge on main with `git merge --no-ff --no-commit <branch>`.
  - Run `scripts/test.sh`, then `swift test` (or with `--skip GoldenTests`) 2–3 times. There are load-dependent flakes.
  - For new golden references, check that each adding commit has the update-goldens before/after summary (TEST-003).
  - Then update the spec Status tables and specs/90-tasks.md: task done, newly ready tasks, DW items closed or added. Python with explicit asserts works well for these table edits.
  - Then `git add <explicit paths>` and `git commit` ("T-XXX: merge (IDs)").
  - `git commit -- <paths>` fails during a merge. Never `git commit -a` (the user edits files in the main checkout).
- **Remote:** `origin` is the private repo `afritzsch/ember-studio`. Autobuild leads push `main` at the end of every phase (skill step 2.4; fall back to `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin main`). Workers never push.
- **Cleanup:** after a merge, close_session. `git worktree remove` needs `--force` because worktrees contain submodules, and auto mode denies `--force` (classified as irreversible local destruction). So merged worktrees stay; list them in the handover for the user to remove.
- **Merge order:**
  - When a dependency merges while another worker still runs, send_input that worker to commit, `git merge main`, and wire up the real thing.
  - If merging A would break B's tests (e.g. a stub test asserting `notImplemented`), give the small fix to whichever worker is free with explicit scope, rather than leaving main red.
- **Known false states:**
  - A "Done" status whose footer says "1 shell still running" means the worker is waiting on its own background job.
  - Ignore unsent prompt suggestions in a worker's input line.
- **C++ tests:** use the specs/14-testing.md "C++ unit tests" pattern. RT checks use RtScope::violations(). Under ASan/TSan the RT-trap allocation tests fail by design (DW-054, DW-065).
- **Resuming a stopped task (autobuild, new in phase 1):** Patchbay's `new_session(branch: X)` fails with "already exists" while X's worktree is still there, and you can't remove it (see Cleanup). Start the worker on a new branch `X-r2` with `base: X` instead, and update its `wip(...)` in 90-tasks.md.
- **Budget (phase 1):** four workers pushed the 5-hour window from 26% to 85% in about 35 minutes. The weekly budget moved only 0 → 10% for the whole phase. Expect a 5-hour pause in every 4-worker phase; pause workers as the skill says, and they resume cleanly.
- **Worker speed:** well-briefed workers finished in 25–60 min (T-035, T-025, T-042), and the big T-032 took about 2 h including a pause. Have the next phase's briefings ready.
- **Asking an idle worker for a lane-local follow-up works well:** T-042 found and fixed the MODEL-044 autosave race (DW-148) as an extra commit before its merge.
- **dawmcp in worker sessions is the build from worktree setup:** new commands and engine changes aren't visible to it (DW-147/151). Workers verify with a freshly built `.build/debug/dawctl` / `dawmcp` over stdio; tell them so in the briefing.
- **Trial merge with uncommitted lead files:** a `--no-commit` trial merge is fine while RUN.md/DECISIONS.md have local edits; commit those separately with explicit paths.
- **Always run `swift test` and `scripts/test.sh` under a timeout (new in phase 2).** macOS has no `timeout`; use a wrapper that kills the whole process tree, e.g. a bash script that backgrounds the command, polls `kill -0` every 5 s and on expiry kills `pgrep -P` children recursively, then the command (exit 124). Phase 2 lost 4 h to a hung `swift test` (DW-168, fixed). Budget: test.sh ≤ 40 min, swift test ≤ 15 min.
- **When a test run hangs, `sample <pid> 2` on the `swiftpm-testing-helper` shows the test and line** before you kill it.
- **`.build/test-logs/swift-test.log`** has the full swift-test output of the last `scripts/test.sh` (the console shows only the tail).
- **Known DAWControl flakes are fixed (phase 2):** the AttachTests hang (DW-168) and the EACCES "permission denied" in $TMPDIR (DW-169, ControlSocketServer umask). If EACCES comes back, look for process-wide state (umask, cwd, env) changed by a test or server.
- **The 5-hour pause can be long:** in phase 2 the window hit 83% about 30 min in, and its reset was ~4 h away. The workers had already finished, so nothing was lost. The lead's own test loop hung through the pause.
- **Pre-deciding a likely Interfaces addition in the briefing works** (T-033's peaks query): the worker didn't stop, and the lead logged it in DECISIONS.md afterwards.
- **Widening a finished worker's scope for a follow-up works** (T-036 built `render.offline {loop}`; T-023 fixed the two DAWControl flakes). Name the exact files and require additive edits where another worker shares them.
- **Expect conflicts in spec 08's "Contract delta" sections** when two workers add one; keep both sections.
- **Lead helpers live in `.git/autobuild/` (new in phase 3):** `tmo.sh` (timeout wrapper: `tmo.sh <seconds> <cmd…>`, exit 124), `watch.sh` (REPORT.md watcher; edit its task-number glob for your wave) and `common.txt` (the briefing template with this wave's rules). They are untracked and survive between phases. Point workers' briefings at `/Users/artem/dev/macDAW/.git/autobuild/tmo.sh`.
- **Pre-deciding a task's open questions in its briefing works (phase 3):** T-026 had two user questions; logging the recommended answers in DECISIONS.md before the start meant the worker never stopped.
- **Add-only shared files conflict on every merge after the first:** `module.modulemap`, the `#include` block and `paramInfoJSON` in `EngineFacade.cpp`. Resolve by keeping both sides (a Python regex over the conflict markers, asserting the count), then run the full timed tests.
- **Under 4-worker load, test.sh's swift-test step fails on wall-clock tests** (UI-010 perf smoke, MODEL-044/DW-148 autosave, CTL-031 progress; DW-172). They pass in plain `swift test` and once the workers are idle. Judge a trial merge by the specific failing tests, plus 2 plain `swift test` runs; log it in the merge commit.
- **Budget (phase 3):** the four workers reported within ~25 min; the 5-hour window went 19% → 85% in ~45 min with the lead reviewing. The rest of the phase (one worker follow-up) waited out a ~4 h reset. Merging in report order while others finish keeps the lead busy before the pause.
- **`usage.sh` once returned a stale-looking reading mid-phase** (week 23 / five 21 between two readings of 30 / 68). Re-read before acting on a surprising number.
- **Tell a finished worker that waits for its merge "queued, do nothing unless I message you"**, so it doesn't start extra work.
- **Phase 4 pattern worked well:** merge in report order while the others finish; when a later branch shares files with merged ones (T-043 vs T-056 in the facade/Swift engine files), have its worker `git merge main` and resolve, instead of resolving yourself. It also took a small lane-local follow-up from another worker's discovered work (arrange peak invalidation).
- **A test-only task can finish within ~20 min** (T-044); give the next one a small follow-up queue in the briefing so it doesn't sit idle.
- **Check `todo` tasks whose deps are all done** when you pick a wave; phase 4 found four that should have been `ready` (T-052, T-053, T-061, T-062).
- **Budget (phase 4):** the 5-hour window went 12% → 86% in ~45 min with four workers (paused ~4 h until the reset); the week went 34% → 49% for the whole phase. One 4-worker phase costs ~15 week-%.
- **`list_sessions` output is huge** (it echoes each worker's whole briefing). Prefer `wait_for(session, timeout: 5)` per worker to check status.
- **The Mac can sleep mid-phase (phase 5).** Every worker turn died with "API Error: Your computer went to sleep mid-response", and background watch loops stop firing. After waking: read_output each worker, `send_input` "Continue where you left off…", and restart the watcher. Tell workers to commit after each piece that builds, so a cut-off turn loses little.
- **Merging a U task in two parts works (phase 5):** T-055 merged its preferences part first, then `git merge main` after T-052 and added the controls that needed T-052's commands. The same branch can be trial-merged twice.
- **Finished workers make good flake hunters:** T-072's follow-up found that MODEL-041's crash test blocked the main actor for up to 30 s (the root of most DAWModelTests DW-172 flakes) and made the autosave tests wait on the store. Ask for a mutation check (reintroduce the bug, see the test fail).
- **Budget (phase 5):** four workers took the 5-hour window from 42% to 89% in ~20 min; the phase needed two pauses (~4 h and ~1.5 h). The week went 50% → 75%, the most of any phase (larger tasks plus follow-ups).
- **zsh doesn't word-split `$(…)`:** stage a merge's files with `git diff --cached --name-only HEAD | xargs git add --`, not `git add $F`.
- **`usage.sh` gave a stale low reading again (phase 6):** 4% week / 29% five-hour between readings of 11/84; three re-reads and a worker's status line agreed on 85. Re-read before acting on a surprising number, in either direction.
- **Budget (phase 6):** four workers took the 5-hour window from 4% to 85% in ~44 min. The week went 1% → ~20%. Resuming four large-context workers costs ~20% of a fresh 5-hour window within minutes.
- **Trial merges during a 5-hour pause are cheap and clean (phase 6):** with the workers paused the machine is idle, so test.sh had none of the DW-172 load flakes. Merging a finished worker then costs the lead only a few tool calls.
- **Chained `registerNodes` wrappers in `EngineFacade.cpp` conflict in a way that needs the code's author:** order matters (the last `set` for a kind wins). Abort the trial merge and have the later worker `git merge main`; T-053 did it twice in one phase (T-062, then T-070) without trouble.
- **A finished D-lane worker found and fixed a real production crash (DW-214)** from another worker's flaky-test note. Ask for root cause + mutation table; it was worth the ~1 h.
- **AU (V2) lifecycle rules (DW-214):** never destroy a bridged AU right after parameter events (release is deferred 1 s in `AUInstance`), and never initialize one V2 AU while another uninitializes (process-wide lifecycle lock). `params(true)` lags render-thread events by a few ms; tests must poll.

## Open questions for the user (not yet answered)
- DW-061: on a tempo edit, should the playhead keep its sample position (current behaviour) or its tick position (recommended; what most DAWs do)?
- DW-063: should offline exports reset all nodes (effect tails too) for fully repeatable exports on one engine?
- DW-125: a tempo edit after SetLoop can shrink an enabled loop below one block. Should the transport handle short loops, or should such tempo edits be refused?
- DW-008 (CONV-RT-06 wording: DAW_RT = `noexcept [[clang::nonblocking]]`).
- DW-012 (ENG-031 says "interpose"; the trap uses malloc_logger + GOT rebinding).
- DW-004 (.patchbay.json could just call scripts/bootstrap.sh; it now also builds dawmcp).
- DW-015 (PluginCatalog library product needs a 01 Interfaces change).
- Interfaces additions to 04: DW-069 (DriverConfig/DeviceLatency) and DW-116 (io/DeviceMonitor.h).
- Lead-owned small spec items: DW-066 (Package.swift name "macDAW"), DW-080 (daw.export thread in CONV §3), DW-122 (document DAW_DEVICE_EVENT_TESTS=1 in 14), DW-135 (`@node` fixtures render silence outside GoldenTests; document in 14's recipe).
- Don't edit the SPEC.md decision log.
- New in autobuild phase 1: DW-153 (EmberStudioShell as a library product, an 01 Interfaces change), DW-156 (one live engine per app or per window?). Also review the three decisions in `docs/autobuild/DECISIONS.md` (T-042 merged without the audible MIDI check; velocity 0 rejected on open; a missing-asset clip still hides the clip under it).
- New in autobuild phase 2:
  - DW-166: UI-010's 60 fps with 1,000 clips needs an Instruments run on the real app.
  - Review the four phase-2 decisions in `docs/autobuild/DECISIONS.md`.
- New in autobuild phase 3:
  - Review the three phase-3 decisions in `docs/autobuild/DECISIONS.md` (T-026's export click and undo; T-071's GR-meter encoding). T-026's two questions are answered there.
  - T-034: the NSEvent → KeyMonitor path has no automated test (posting key events needs Accessibility). A manual check in the app: Space, R, L, ⌘E, ⌫, ⌘T.
  - T-034 UX choices: arrow keys for `clip.nudge.*` (KeyChord drops function keys today); editable tempo/signature in the toolbar.
- New in autobuild phase 4:
  - Review the three phase-4 decisions in `docs/autobuild/DECISIONS.md` (T-043 `previewNote`; T-056 undo + DW-130; T-056 additive events).
  - T-043 UX choices: open the piano roll with double-click / right-click / `P`; quantize strength is a preset menu (25/50/75/100 %), because a raw Slider isn't `ui.perform`-able (UI-052).
  - T-056: `play()` is refused (not deferred) while assets re-convert; an export waits up to 600 s.
- New in autobuild phase 5:
  - Review the five phase-5 decisions in `docs/autobuild/DECISIONS.md` (T-052 contract and undo, T-061 contract and golden, T-055 ordering).
  - T-072's delay choices (06 "Delay semantics"): max 4 s, feedback ≤ 0.95, LP 20 kHz = off, ping-pong input as ½(L+R) on the left, defaults (sync 1/8, feedback 0.35, LP 8 kHz, mix 0.3), crossfade instead of glide.
  - DW-196: `ParamInfo` step/enum metadata (06 Interfaces change).
  - T-055 UX: the audio panel is a strip under the toolbar (not a sheet); track headers are two lines in a 220 pt column.
- New in autobuild phase 6:
  - Review the eight phase-6 decisions in `docs/autobuild/DECISIONS.md` (T-053 contract/routing/placement, T-062 contract/test plugin, T-070 registry/NaN telemetry, T-076 inserts and faders).
  - DW-206: UI-031's Instruments acceptance and 100-strip scrolling need a manual check in the real app.
  - DW-207: stereo (L/R) meters need a two-channel `MeterReading` (08 Interfaces change).
  - DW-214: consider filing Apple Feedback (nil weak bridge in `-[AUAudioUnitV2Bridge _createParameterTree]_block_invoke`; evidence in the T-070 DW-214 report section, DW-214 clarification in 10 "Contract delta (T-061)").

## Your first job
1. Run `usage.sh`; check the skill's *Stop the run* conditions.
2. `list_sessions`, pick the wave (see *Suggested next wave*), log pre-decisions in DECISIONS.md, mark the tasks `wip(...)`, commit, and start the workers with `.git/autobuild/common.txt` (edit `watch5.sh`'s glob for your tasks; it currently watches t-0{53,62,70,76}).
3. Review, trial merge, timed tests, merge, close each worker, then hand over, push and write `.git/autobuild/phase-7.done`.
