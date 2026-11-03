You are AUTOBUILD phase lead 4. You run in the main checkout /Users/artem/dev/macDAW on branch main. Read CLAUDE.md, then `.claude/skills/autobuild/SKILL.md` (Phase lead), then follow "Orchestrating with Patchbay" in specs/90-tasks.md with the skill's overrides. Use the Patchbay MCP tools for workers, never the Agent tool. The run log is `docs/autobuild/RUN.md` and the decisions taken without the user are in `docs/autobuild/DECISIONS.md`.

## State at handoff (2026-11-03, end of autobuild phase 3; main @ the "Autobuild phase 3: handover" commit, pushed; clean; no worker sessions running)
- Phase 3 merged all four wave tasks:
  - **T-045** MIDI edge routing (DW-099; DSP-003, MIX-001, MIX-021 for MIDI): fixed-capacity per-graph MIDI storage, a k-way stable merge, `MidiDelayLine` PDC with carry-over (05 "MIDI routing"). A MIDI track with a sampler is audible: an A5 note renders at 880 Hz through the model and dawctl.
  - **T-071** compressor (DSP-031, DSP-040/041 for it): sidechain key, GR meter on the per-node meter path (autobuild decision), golden `sidechain_compressor`. MIX-008 is done.
  - **T-026** project metronome (TIME-010 project part, DW-160): `SetMetronome` (persisted, marks dirty, outside undo history via `HistoryExemptCommand`), one metronome node straight into the master, `transport.setMetronome` + `daw_transport_set_metronome`, `render.offline {includeMetronome}` (default off), Metronome/GainNode ParamInfo.
  - **T-034** toolbar, transport and keyboard (UI-002, DW-165): one dispatch path (`KeyBindings.all` → `UIControl`), menus, the `transport.metronome` toggle, ui.state `toolbar`/`keyBindings`.
- Done & merged (44): T-001..T-026, T-030..T-036, T-040..T-042, T-045, T-050, T-051, T-060, T-071, T-085..T-087.
- No `wip` tasks.
- **Ready (9):** T-043 piano roll (U, M4), T-044 M4 goldens (D, newly ready), T-055 audio preferences + device toasts (U, M5, newly ready), T-056 session-rate change (E+M, M5), T-070 EQ, T-072 delay, T-073 reverb (D, M7), T-076 mixer view (U), T-082 export dialog (U).
- Discovered work runs DW-001..DW-181. New this phase: DW-170..181.
- `scripts/test.sh` is 11/11 on main, and timed `swift test` was green 2× after the last merge.
- Phase 3 week usage: 23% → 33%.

## Suggested next wave
Earliest milestone first; M4 can close this phase.
- **T-044** (D, M4): M4 goldens. `sampler_pitch` (DW-139, now unblocked), `midi_loop_wrap` (DW-101), `midi_tempo` through EngineClient (DW-096). Files: Tests/GoldenTests/** and fixtures; no engine edits expected.
- **T-043** (U, M4): piano roll + velocity lane + audition. It needs a `previewNote` facade addition (08 Interfaces). Pre-decide it in the briefing as an additive, defaulted `EngineProtocol` method, like T-033's `peaks`, so the worker doesn't stop. It may touch facade + DAWModel/Engine besides App/.
- **T-056** (E+M, M5): session sample-rate change (IO-033 re-convert assets, re-prepare; `SetSessionSampleRate`). It touches io/, facade and DAWModel: tell T-043 which facade lines are whose (both add-only).
- **T-073** (D, M7): reverb (FDN, deterministic). It's the same lane as T-044, but the files are disjoint (new nodes/Reverb.*, dsp/**, a BuiltinNodes.cpp line, a `paramInfoJSON` line). It unblocks DW-162 (a real tail in `locate_reset`) and moves T-077 forward.
- T-055 (U, M5) is also ready but shares App/ with T-043; run it after T-043 or give the two disjoint folders.
- Small cleanups worth folding into a worker that finishes early: DW-171 (one stale comment), DW-175 (one doc line), DW-172 (wall-clock test flakes under load).

## Decisions taken this phase (see docs/autobuild/DECISIONS.md)
- T-026 Q1: an export leaves the click out unless `includeMetronome: true` (pre-decided in the briefing).
- T-026 Q2: `SetMetronome` is persisted and marks the project dirty, but doesn't enter undo history.
- T-071: the GR meter reuses `MeterReading` (peak = deepest reduction as a linear factor in the block, rms = factor at the last frame); no Telemetry/facade change.

## Sessions only the user can close
- In the sidebar: "macDAW" sessions (the conductor and an older "push to main" session). Phase lead 3 closed all its own workers.
- Worktrees left on disk: removing them needs `--force` (submodules), which auto mode denies. All are merged or superseded:
  - `~/.patchbay/worktrees/macDAW/t-025-m2-goldens`, `t-025-m2-goldens-r2`, `t-031-persistence`, `t-032-app-shell`, `t-032-app-shell-r2`, `t-035-crossfades`, `t-042-note-commands`, `t-023-sidechain`, `t-024-metronome`, `t-033-arrange-canvas`, `t-036-m3-goldens`;
  - new this phase: `t-026-project-metronome`, `t-034-toolbar-transport`, `t-045-midi-routing`, `t-071-compressor`.
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


## Your first job
1. Run `usage.sh`, then `list_sessions`.
2. Pick the wave (see *Suggested next wave*), mark the tasks `wip(...)`, commit, and start the workers with the briefing template (`.git/autobuild/common.txt`).
   - Add to every briefing: the other workers' files ("do NOT touch"), the add-only shared files, the untracked REPORT.md, "Questions for the lead" instead of waiting for the user, "verify new commands/engine changes with a freshly built dawctl/dawmcp", and "run swift test / scripts/test.sh under `.git/autobuild/tmo.sh`".
   - Pre-decide likely Interfaces additions (T-043's `previewNote`) in the briefing and log them in DECISIONS.md.
3. Follow the skill: review, trial merge, timed tests, merge, close each worker, then hand over and push.
