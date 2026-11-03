You are AUTOBUILD phase lead 5. You run in the main checkout /Users/artem/dev/macDAW on branch main. Read CLAUDE.md, then `.claude/skills/autobuild/SKILL.md` (Phase lead), then follow "Orchestrating with Patchbay" in specs/90-tasks.md with the skill's overrides. Use the Patchbay MCP tools for workers, never the Agent tool. The run log is `docs/autobuild/RUN.md` and the decisions taken without the user are in `docs/autobuild/DECISIONS.md`.

## State at handoff (2026-11-03, end of autobuild phase 4; main @ the "Autobuild phase 4: handover" commit, pushed; clean; no worker sessions running)
- Phase 4 merged all four wave tasks. **M4 (MIDI & Sampler) is complete.**
  - **T-044** M4 goldens: `sampler_pitch`, `midi_loop_wrap`, `midi_locate_no_stuck_notes` (per-sample oracle from 06), and `midi_tempo` through EngineClient (`MidiTempoEngineTests`, DW-096 for MIDI). Test-only.
  - **T-073** reverb (DSP-033): 8-line FDN with Hadamard mixing, deterministic float math, silence snaps to exact 0; golden `reverb_determinism` (two fresh engines, bit-identical). ParamInfo via `paramInfoJSON`.
  - **T-056** session-rate change (IO-033, `SetSessionSampleRate`): the facade's `AssetReloader` re-converts assets on `daw.loader` with `reload` progress on `assetsReloaded` events; play is refused while a pass runs, exports wait (≤ 600 s). `SetSessionSampleRate` is history-exempt and rescales clip offsets/zone loops; the document follows engine-side rate changes (DW-130). `loadAsset` takes a peak-cache dir (DW-077). Contract deltas in 08 and 13.
  - **T-043** piano roll (UI-020) + audition (UI-021): `previewNote(source, pitch, velocity, on)` into the track's MIDI clip player through a lock-free `MidiPreviewInbox`; releaseAll on stop/locate/offline. Open with double-click, right-click → Open in Piano Roll, or `P`. Arrange now drops peaks once per rate-change pass.
- Done & merged (48): T-001..T-026, T-030..T-036, T-040..T-045, T-050, T-051, T-056, T-060, T-071, T-073, T-085..T-087.
- No `wip` tasks.
- **Ready (13):** T-052 audio recording (E, M5), T-053 CoreMIDI + MIDI recording (E, M5), T-055 audio preferences + device toasts (U, M5), T-061 AU hosting (P, M6), T-062 VST3 hosting (P, M6), T-070 EQ (D, M7), T-072 delay (D, M7), T-076 mixer view (U), T-082 export dialog (U).
  - T-052, T-053, T-061 and T-062 were left `todo` by earlier leads although all their dependencies were done; phase 4 marked them `ready`.
- Discovered work runs DW-001..DW-191. New this phase: DW-182..191 (T-056: rate-change golden, rate UI, a blocking control wait, restore JSON keys, rejected-graph-at-new-rate; T-043: two spec-text items, headless `engine.previewNote`, preview retrigger on graph rebuild, piano-roll perf + per-asset peak refresh). DW-172 now notes that DW-148 also fails ~1 in 4–5 runs on base: fix it first.
- `scripts/test.sh` on the last trial merge was 10/11 (only the DW-172 flakes DW-148 and CTL-031 in the swift-test step); plain `swift test` was green after every merge.
- Phase 4 week usage: 34% → 49%.

## Suggested next wave
Critical path / earliest milestone first (M5 recording, then M6 plugins):
- **T-052** (E, M5): audio recording. The core of M5; T-054 and T-080 depend on it.
- **T-061** (P, M6): AU hosting. Unblocks T-063/T-064/T-074 (automation, AUTO-009). T-062 (VST3, P) is the same lane; run one P task per wave or give them disjoint folders.
- **T-055** (U, M5): audio preferences + device toasts. Can also take DW-183 (session-rate UI + progress).
- **T-070** or **T-072** (D, M7): EQ or delay. T-072 also lets `routing` (DW-096) and DW-162 move; both are needed for T-077 with T-074.
- Small items worth folding into a worker that finishes early: DW-172/DW-148 (autosave poll flake, the most frequent), DW-187/188 (spec text), DW-189 (headless previewNote).

## Decisions taken this phase (see docs/autobuild/DECISIONS.md)
- T-043: `previewNote` added to the facade (additive, defaulted protocol method), pre-decided in the briefing.
- T-056: `SetSessionSampleRate` is history-exempt (like `SetMetronome`) and also applied when the engine changes rate by itself (DW-130).
- T-056: additive progress events / facade method pre-accepted; it shipped `reload` fields on `assetsReloaded` and `assetsReloadPending` in telemetry (no new event type).
- Not logged as a user decision: T-073 changed one token in `Tests/DAWEngineTestSupport/FacadeChecks.cpp` and one in `EngineClientTests.swift` (their "kind with no params" checks used `reverb`, which now has params); accepted at review.

## Sessions only the user can close
- In the sidebar: "macDAW" sessions (the conductor and an older "push to main" session). Phase lead 4 closed all its own workers.
- Worktrees left on disk: removing them needs `--force` (submodules), which auto mode denies. All are merged or superseded:
  - `~/.patchbay/worktrees/macDAW/t-023-sidechain`, `t-024-metronome`, `t-025-m2-goldens`, `t-025-m2-goldens-r2`, `t-026-project-metronome`, `t-031-persistence`, `t-032-app-shell`, `t-032-app-shell-r2`, `t-033-arrange-canvas`, `t-034-toolbar-transport`, `t-035-crossfades`, `t-036-m3-goldens`, `t-042-note-commands`, `t-045-midi-routing`, `t-071-compressor`;
  - new this phase: `t-043-piano-roll`, `t-044-m4-goldens`, `t-056-session-rate`, `t-073-reverb`.
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

## Your first job
1. Run `usage.sh`. If `week ≥ 50`, don't start a phase: write the stop handover (skill *Stop the run*).
2. Otherwise `list_sessions`, pick the wave (see *Suggested next wave*), mark it `wip(...)`, commit, and start the workers with `.git/autobuild/common.txt` (edit `watch.sh`'s glob for your tasks).
3. Follow the skill: review, trial merge, timed tests, merge, close each worker, then hand over and push.
