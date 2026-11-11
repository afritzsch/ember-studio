Autobuild stopped: weekly usage reached the 50% limit (61% at the end of phase 8). To continue, start a new run with `/autobuild` once the week resets (the conductor numbers the next phase 9); its first lead reads this file. Read CLAUDE.md, then `.claude/skills/autobuild/SKILL.md`, then follow "Orchestrating with Patchbay" in specs/90-tasks.md. Use the Patchbay MCP tools for workers, never the Agent tool. The run log is `docs/autobuild/RUN.md` and the decisions taken without the user are in `docs/autobuild/DECISIONS.md`.

## State at handoff (2026-11-11, end of autobuild phase 8; main @ the "Autobuild phase 8: handover" commit, pushed; clean; no worker sessions running)
- Phase 8 merged all four wave tasks (trial merges: every one `scripts/test.sh` 12/12 and `swift test` 2× green):
  - **T-077** M7 goldens: `eq_response`, `effects_silence_nan_guard`, `builtin_bypass_null`, `effect_param_steps`, `m7_scene` (`M7GoldenTests`, oracles from 06); 14's golden table has the M7 rows. `GoldenEngine.telemetry` now copies `nanBlocks`. No DSP bug found. **M7 now needs only T-075.**
  - **T-089** transport/export follow-ups (user answers): tempo edits keep the playhead's tick (DW-061); loops shorter than a block render in passes (DW-125, golden `loop_short_multiwrap`); offline renders reset every node first, so exports on one engine are bit-identical (DW-063; built-in effects' `reset()` returns them to their prepared state; live locate keeps TIME-008); `play()` during re-conversion is queued (`playPending`, stop cancels). `gain_ramp_smoothing`, `send_ramps`, `locate_reset`, `midi_locate_no_stuck_notes` reworked/regenerated under DW-063 (DECISIONS "T-089 goldens").
  - **T-090** app follow-ups: one live engine per app, the front window holds it and background windows park offline engines (DW-156, `AppModel` "One live engine", `EngineBroker`); monitoring feedback guard for built-in mic → built-in speakers (DW-230, toast with "Monitoring Off", `ui.state.feedbackWarning`, additive `DeviceInfoPOD.isBuiltIn/outputIsHeadphones/isDefaultInput`); "Include Metronome" starts in the metronome's state; UI-010 perf smoke strict only with `DAW_PERF_TESTS=1` (DW-223).
  - **T-088** insert-chain commands: `InsertDevice`/`RemoveDevice`/`RestoreDevice`/`MoveDevice` on tracks, buses and the master (DW-149); removing a send/device/instrument (or a bus's incoming sends) removes the lanes that target it in one undo step (DW-234); velocity-0 notes repaired to 1 on open (DW-150); SetLoop's 4096-sample minimum dropped (DW-125).
- Lead housekeeping (delegated by the user): DW-004 (`.patchbay.json` setup is now `scripts/bootstrap.sh && scripts/dawmcp.sh --build-only`; the phase-8 workers were still set up the old way), DW-008, 012, 069, 080, 116, 122, 135 done in the specs; DW-015, 066, 153, 196, 207 decided and scheduled (DECISIONS "Spec housekeeping").
- Done & merged (64): T-001..T-026, T-030..T-036, T-040..T-045, T-050..T-056, T-060..T-062, T-064, T-070..T-074, T-076, T-077, T-082, T-085..T-090.
- No `wip` tasks, no WIP branches.
- **Ready (5):** T-063 plugin editors (P+U, M6), T-075 automation recording + lane UI (U+M, M7), T-080 loop takes/comping (E+M, M8), T-083 crash recovery dialog (U, M8), T-084 sanitizer CI / perf smoke / GitHub Actions (E, M8; newly ready after T-077).
- Discovered work runs DW-001..DW-252. New this phase: DW-239..252 (golden table rows for non-M7 fixtures, GoldenEngine telemetry drift, wall-clock flakes; plugin `reset()` no-ops, recorder sees only the last pass of a short-loop block (T-080), 02 render-order text, `playPending` in the UI; `unloadAsset`, headphone-jack manual check, attach-mode second realtime engine, `file.new` control; editable mixer inserts (T-065), insert-kind validation, ENG-050 flake). Closed: DW-004, 008, 012, 061, 063, 069, 080, 116, 122, 125, 135, 149, 150, 156, 223, 230, 234.
- Phase 8 week usage: 43% → 61% (one 5-hour pause of ~4.2 h).

## Suggested next wave (for a new run)
- **T-075** automation recording + lane UI (U+M, completes M7): read DW-236 (only automatable params) and DW-237 (stopped writes) first.
- **T-080** loop takes/comping (E+M, M8): read DW-243 (recorder and short-loop passes). E+M overlaps T-075's M part: give them a strict file split or run one per wave.
- **T-084** sanitizer CI / perf job (E): fold in DW-241/DW-252 (wall-clock flakes into the perf job), DW-054/065 (sanitizer skips), DW-005 (clean builds).
- **T-063** plugin editors (P+U, M6): needs vstgui4 or an own `IPlugView` test plugin (DW-208) and the plugin → model param path (DW-204). Then T-065 (also DW-250: editable inserts, DW-015/DW-196 from the housekeeping decisions).
- **T-083** crash recovery dialog (U): T-064's marker API and DW-224/226 are ready.
- Small lead items: DW-066 (rename the package to "EmberStudio" when no worker owns Package.swift), DW-239, DW-244.
- Backlog the user chose: a per-track MIDI input/channel picker, DW-232 (wrap jump for the other built-ins).

## Decisions taken this phase (see docs/autobuild/DECISIONS.md, phase 8 rows)
- Wave 8 = the user's follow-ups (three new tasks T-088..T-090) + T-077.
- T-088: `InsertDevice {channel, index?, device}` addresses the master by its ID; the lane cascade covers RemoveSend, RemoveDevice, RemoveInstrument and RemoveBus's sends.
- T-089: queued play (stop cancels); only offline renders reset all nodes; four goldens reworked under DW-063.
- T-090: background windows keep offline engines; the feedback guard warns with a one-click fix (also for `on` monitoring without an arm, accepted at review); the perf smoke is strict only with `DAW_PERF_TESTS=1`.
- Spec housekeeping delegated by the user (one row listing each item).

## Sessions only the user can close
- In the sidebar: the "macDAW" conductor session (it closes this lead). Phase lead 8 closed all four of its workers.
- Worktrees left on disk (removing them needs `--force` because of submodules, which auto mode denies). All are merged or superseded:
  - `~/.patchbay/worktrees/macDAW/t-023-sidechain`, `t-024-metronome`, `t-025-m2-goldens`, `t-025-m2-goldens-r2`, `t-026-project-metronome`, `t-031-persistence`, `t-032-app-shell`, `t-032-app-shell-r2`, `t-033-arrange-canvas`, `t-034-toolbar-transport`, `t-035-crossfades`, `t-036-m3-goldens`, `t-042-note-commands`, `t-043-piano-roll`, `t-044-m4-goldens`, `t-045-midi-routing`, `t-052-audio-recording`, `t-055-audio-prefs`, `t-056-session-rate`, `t-061-au-hosting`, `t-071-compressor`, `t-072-delay`, `t-073-reverb`;
  - phase 6: `t-053-coremidi`, `t-062-vst3-hosting`, `t-070-eq`, `t-076-mixer-view`.
  - phase 7: `t-054-input-monitoring`, `t-064-host-bypass`, `t-074-automation`, `t-082-export-dialog`.
  - new in phase 8: `t-077-m7-goldens`, `t-088-insert-chain`, `t-089-transport-followups`, `t-090-app-followups`.
  - Remove them with `git worktree remove --force <path>`, then `git branch -D <branch>`. The old remote WIP branches `origin/t-025-m2-goldens`, `t-031-persistence` and `t-032-app-shell` can be deleted too.


## Open questions for the user (not yet answered)
- Everything asked before phase 8 is answered (DECISIONS.md → *User review*). Still the user's:
  - Manual checks in the app: DW-166 (UI-010 Instruments run with 1,000 clips), DW-206 (UI-031 Instruments, 100-strip scrolling), DW-222 (export "Choose…" panel), DW-247 (headphone jack on Apple Silicon reads 'hdpn', else the feedback guard warns falsely), T-034's key check (Space, R, L, ⌘E, ⌫, ⌘T).
  - Whether to file Apple Feedback for DW-214 (evidence in the T-070 DW-214 report section).
  - Review the phase-8 rows in DECISIONS.md.

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

- **Budget (phase 7):** four workers took the 5-hour window from 63% to 87% in ~13 min (it was already high at the start); after the reset, two big workers plus the lead took it 0% → 86% in ~53 min. The week went 20% → 42%. Starting a wave with the window above ~50% buys only minutes of work before the pause.
- **Merging finished workers during a pause works (phase 7 again):** T-082 and T-064 were trial-merged and merged while the other two were paused; only tool calls of the lead count against the window.
- **UI-010's perf smoke now fails in most full runs (phase 7, DW-223)**, even with the workers paused, when the user's other apps load the machine. Judge it by running `swift test --filter ArrangeModelTests` alone (3× green each time).
- **Merge order for E-lane overlap:** T-054 and T-074 both edited `RenderGraph`, `Engine.cpp`, `GraphBuilder` and `GraphDescription.h`. Merging one, then having the other worker `git merge main` (it resolved and checked the render order itself), was clean.
- **Workers read briefings from `.git/autobuild/brief-T-XXX.txt`:** a short new_session prompt pointing at the file keeps list_sessions output small and works (a scratchpad path outside the worktree also worked).
- **Phase 8 additions:**
  - Pass the briefing as a file: write `.git/autobuild/brief-T-XXX.txt` and start the worker with a one-line prompt pointing at it. That avoids quoting problems in `new_session`.
  - `watch5.sh` touches its marker when it fires, so a second worker's report written just before that is missed. After each wake, also check `list_sessions`: a worker in "Done" with no new watcher hit may already have reported.
  - A lead decision that changes semantics other goldens rely on (DW-063: reset before every offline render) breaks fixtures that used a second render as a "locate" stand-in. Expect it, and decide fast (DECISIONS "T-089 goldens").
  - When one task's model change depends on another's engine change (T-088's SetLoop minimum vs T-089's short loops), merge the engine task first.
  - The UI-010 perf smoke is load-tolerant since T-090 (`DAW_PERF_TESTS=1` for the strict bound), so trial merges read 12/12 again. Other wall-clock flakes remain (DW-241, DW-252).

## Your first job
1. This run stopped at the weekly limit. A new run starts with `/autobuild` after the week resets; its first lead is phase 9.
2. Run `usage.sh`; check the skill's *Stop the run* conditions.
3. `list_sessions`, pick the wave (see *Suggested next wave*), log pre-decisions in DECISIONS.md, mark the tasks `wip(...)`, commit, and start the workers with `.git/autobuild/common.txt` (write each briefing to `.git/autobuild/brief-T-XXX.txt` and start the worker with a one-line prompt pointing at it; edit `watch5.sh`'s glob for your tasks; it currently watches t-0{77,88,89,90}).
4. Review, trial merge, timed tests, merge, close each worker, then hand over, push and write `.git/autobuild/phase-9.done`.
