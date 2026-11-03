Autobuild stopped: user-authorized final phase done. The run ended after phase 5 (the user authorized it although week usage was ≥ 50%). A future lead is started by the user (`/autobuild` for a new run, which continues the phase numbering with 6, or a manual lead session). Read CLAUDE.md, then `.claude/skills/autobuild/SKILL.md` if it is an autobuild run, then follow "Orchestrating with Patchbay" in specs/90-tasks.md. Use the Patchbay MCP tools for workers, never the Agent tool. The run log is `docs/autobuild/RUN.md` (its *Summary for the user* covers phases 1–5) and the decisions taken without the user are in `docs/autobuild/DECISIONS.md`.

## State at handoff (2026-11-04, end of autobuild phase 5; main @ the "Autobuild phase 5: handover" commit, pushed; clean; no worker sessions running)
- Phase 5 merged all four wave tasks (plus follow-ups):
  - **T-052** audio recording (REC-001..005): per-track `RecordFifo`s fed through an `InputCapture` seam in the device drivers, `Recorder` + `daw.diskwrite` writing 32-bit float CAF into `<project>/Audio/Recordings/` (unsaved projects: `$TMPDIR/EmberStudio-Recordings/<uuid>-<pid>/`), latency compensation (golden `record_loopback_alignment`, exact to the sample), punch range (`transport.setPunch`), finalize on stop/device loss/arm change (DW-119). Model: `Track.inputPair`, history-exempt `ArmTrack`/`SetMonitoring`, `recordingFinalized` → one undoable "Record" (ImportAsset + AddClip) imported by `ProjectStore`. Contract deltas in 08, 09, 13.
  - **T-072** delay (DSP-032): ms or tempo-synced, ping-pong, LP in the loop, 20 ms crossfade on time/tempo changes; golden `delay_tempo_sync`; a locate keeps the tail (DW-162). Follow-up: the DW-148 autosave tests now wait on the store (`autosaveIdle()`, `afterAutosaveIO` test seam in `ProjectStore`) and MODEL-041's crash-test spin runs off the main actor, which removed most DAWModelTests wall-clock flakes (DW-172; DW-201 left).
  - **T-055** audio preferences (UI-040: device, rate, buffer, inputs, latency; `prefs.audio.*` control ids, ⌘,), session-rate UI with re-conversion progress (DW-183), device toasts with an "Audio Settings…" action, track-header arm/monitor/input controls, recording toasts, record through `EngineSync.setRecording` (DW-198), only existing input pairs (DW-200).
  - **T-061** AU hosting (PLUG-010, 012..016 for AU): `plugins/` (`AUInstance`, `AUPluginNode`, `AUPluginHost`: one AU per slot that survives node re-creation), configJSON `{identifier, state}`, facade `instantiatePlugin`/`get/setPluginState`/`pluginInfoJSON`, `engine.pluginInfo`, latency KVO → PDC, aux bus ← sidechain, render-thread param/MIDI events with 0 RT violations (no exemption needed). Golden: AUSampler nulls against AVAudioEngine at −156 dBFS (no stored reference). App and Dispatcher capture live plugin state on save (DW-143).
- Done & merged (52): T-001..T-026, T-030..T-036, T-040..T-045, T-050..T-052, T-055, T-056, T-060, T-061, T-071..T-073, T-085..T-087.
- No `wip` tasks.
- **Ready (9):** T-053 CoreMIDI + MIDI recording (E, M5), T-054 input monitoring (E, M5), T-062 VST3 hosting (P, M6), T-064 host bypass/NaN guard/crash marker (P, M6), T-070 EQ (D, M7), T-074 automation (E+M, M7), T-076 mixer view (U), T-080 loop takes/comping (E+M, M8), T-082 export dialog (U).
- Discovered work runs DW-001..DW-205. New this phase: DW-192..205 (telemetry input latency/buffer, device caps, `device.set` buffer reset, 13 `prefs.audio.*` ids, ParamInfo step/enum metadata, `locate_reset` with a real tail, inputPair validation, main-actor stalls in DAWModelTests, mixer arm/monitor controls, take-import result, plugin → model params, async AU re-instantiation).
- Last trial merge (T-061): `scripts/test.sh` 11/11. All four phase-5 merges ended with test.sh 11/11, except T-072's first merge (only DW-172 load flakes).
- Phase 5 week usage: 50% → 75% (two 5-hour pauses, a Mac sleep, and four follow-ups).

## Suggested next wave
- **T-054** input monitoring (E, M5) or **T-053** CoreMIDI (E, M5): both finish M5's recording side; one E task per wave (both touch record/ and io/).
- **T-062** VST3 hosting (P, M6): mirror T-061's design (one instance per slot, configJSON, host in `plugins/`). Unblocks T-063 (editors).
- **T-074** automation (E+M, M7): T-061 provides the AU param path (AUTO-009).
- **T-070** EQ (D, M7): the last built-in effect; then the `routing` fixture (DW-096) can run.
- Small lead items: DW-187/188/195 (spec text), DW-069/116 (04 Interfaces, user).

## Decisions taken this phase (see docs/autobuild/DECISIONS.md)
- T-052: additive contract (event, telemetry `recordDrops`, facade methods, `Track.inputPair`) pre-accepted; `ArmTrack`/`SetMonitoring` history-exempt.
- T-061: AU identifier + state in `NodeDesc.configJSON`, additive facade/protocol pre-accepted; analysis-based golden (no stored reference of a system AU).
- T-055: arm/monitor buttons after T-052 merged (it did, in the same phase).
- Not logged as user decisions (accepted at review): T-072 crossfade (not glide) on delay-time changes, with its defaults listed in 06 "Delay semantics"; T-061 maps param slot i to the AU's i-th `allParameters` entry, NaN = leave the AU's value.

## Sessions only the user can close
- In the sidebar: the "macDAW" sessions (the conductor and older sessions). Phase lead 5 closed all its own workers.
- Worktrees left on disk: removing them needs `--force` (submodules), which auto mode denies. All are merged or superseded:
  - `~/.patchbay/worktrees/macDAW/t-023-sidechain`, `t-024-metronome`, `t-025-m2-goldens`, `t-025-m2-goldens-r2`, `t-026-project-metronome`, `t-031-persistence`, `t-032-app-shell`, `t-032-app-shell-r2`, `t-033-arrange-canvas`, `t-034-toolbar-transport`, `t-035-crossfades`, `t-036-m3-goldens`, `t-042-note-commands`, `t-043-piano-roll`, `t-044-m4-goldens`, `t-045-midi-routing`, `t-056-session-rate`, `t-071-compressor`, `t-073-reverb`;
  - new this phase: `t-052-audio-recording`, `t-055-audio-prefs`, `t-061-au-hosting`, `t-072-delay`.
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

## Your first job
1. The run is stopped. If the user starts a new autobuild run, its conductor numbers the next phase 6; the phase lead runs `usage.sh` and follows the skill.
2. Otherwise (manual lead): `list_sessions`, pick the wave (see *Suggested next wave*), mark it `wip(...)`, commit, and start the workers with `.git/autobuild/common.txt` (edit `watch.sh`/`watch5.sh`'s glob for your tasks).
3. Review, trial merge, timed tests, merge, close each worker, then hand over and push.
