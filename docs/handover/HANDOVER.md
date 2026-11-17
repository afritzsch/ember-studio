You are AUTOBUILD phase lead 10. Read CLAUDE.md, then `.claude/skills/autobuild/SKILL.md`, then follow "Orchestrating with Patchbay" in specs/90-tasks.md. Use the Patchbay MCP tools for workers, never the Agent tool. The run log is `docs/autobuild/RUN.md` and the decisions taken without the user are in `docs/autobuild/DECISIONS.md`.

## State at handoff (2026-11-17, end of autobuild phase 9; main @ the "Autobuild phase 9: handover" commit, pushed; clean; no worker sessions running)
- Phase 9 merged all four wave tasks (every trial merge: `scripts/test.sh` 12/12 and a separate timed `swift test` green):
  - **T-075** automation recording + lane UI (AUTO-006/007, UI-015, DW-236/237): `RecordAutomation {target, from, to, points, mode}` (one undo entry per pass, RDP ε 0.5 %), touch/latch/write via `AutomationRecorder`, a lock-free per-lane suspend flag (`EngineFacade::setAutomationSuspended`, `automation/AutomationSuspension.h`, held in `Engine` so it survives graph swaps), stopped edits (point at the playhead or a held SetParam), `ParamCatalog` parses `automatable`, lane rows under tracks (`Shell/Automation/`), ui.state `automation`. **M7 is complete.**
  - **T-080** loop takes/comping (REC-030..034, DW-243): the recorder logs every loop wrap (short loops too), `RecordedTake` carries pass starts, `CreateTakeFolder`/`SetCompSelection` (+ inverses `RemoveTakeFolder`, `RestoreTakeFolder`, `RestoreComp`), default comp = latest covering take, comp flattened into clips with IDs ≥ 2^63 and 64-sample equal-power crossfades (golden `comp_crossfade`), MIDI loop takes behind `transport.setRecordOptions {midiLoopTakes}`. **T-081 is ready.**
  - **T-084** CI (TEST-007, TEST-008 partial, BUILD-009, DW-005/054/065/241/252): `.github/workflows/ci.yml` + `ci-job.yml` (macos-15; push to main → clean build + test.sh; asan/tsan/perf on dispatch + weekly), every job is `scripts/ci.sh <job>`; sanitizer skips via `DAW_SANITIZER`; wall-clock bounds strict only with `DAW_PERF_TESTS=1`; `PerfSmokeTests` (TEST-008) measures **3.8–4.9× realtime, below the 10× bound**, so the perf job is red until **T-091** (new, D, ready). ASan/TSan found two test-fixture bugs, fixed.
  - **T-063** plugin editors (PLUG-017, DW-204, DW-208): `createPluginView`/`destroyPluginView` + `pluginViewJSON`/`openPluginViews`, floating panels (`Shell/PluginEditor/`), EmberTest VST3 has its own `IPlugView` (`Tests/VST3TestPlugin/EmberTestView.mm`), AU falls back to the generic view, plugin-side edits → `pluginParamEdited` event → one undoable SetParam gesture (`PluginEditRecorder`), first-edit undo pushes the pre-gesture baseline (DECISIONS option c). **M6 now needs only T-065, which is ready.**
- `main` was pushed at the end of phase 9, the **first push with CI**. Check the first Actions run (`gh run list --limit 3`): DW-261 (the macos-15 image's Xcode may be too old for Swift 6.2+ exit tests; switch the runner label in `ci-job.yml` if so).
- Done & merged (68): T-001..T-026, T-030..T-036, T-040..T-045, T-050..T-056, T-060..T-064, T-070..T-077, T-080, T-082, T-084..T-090.
- No `wip` tasks, no WIP branches.
- **Ready (4):** T-065 device chain view + plugin manager (U, M6), T-081 take folder / comp UI (U, M8), T-083 crash recovery dialog (U, M8), T-091 DSP performance for TEST-008 (D, M8).
- Discovered work runs DW-001..DW-265. New this phase: DW-253..257 (T-075: plugin params in "+ Lane", other controls' gesture hooks, live points while recording, resume on graphApplied, touch golden), DW-258..260 (T-080: RemoveAsset/SetSessionSampleRate don't know take clips, recorder block counter), DW-261..262 (T-084: CI Xcode, test-target warnings), DW-263..265 (T-063: ungestured plugin edit undo, VST3 without editor/panel positions/3rd-party editors, dawmcp snapshot schema). Closed: DW-005, 054, 065, 204, 208, 236, 237, 241, 243, 252.
- Phase 9 week usage: 0% → 24% (one 5-hour pause of ~4.2 h).

## Suggested next wave
- All four ready tasks fit one wave, but three are U (App/). Give them a strict file split:
  - **T-065** device chain view + plugin manager (U, M6): `Shell/DeviceChain/` (new), editable mixer inserts (DW-250), generic ParamInfo UI with `steps`/value labels (DW-196, 06 Interfaces addition decided in "Spec housekeeping"), plugin manager with `PluginCatalog` as a library product (DW-015/DW-153, decided), gesture hooks for automation recording (DW-254), plugin params in "+ Lane" (DW-253), VST3 without editor (DW-264), safe-mode bypass display (DW-226).
  - **T-081** take folder / comp UI (U, M8): `Shell/Takes/` (new) + arrange drawing of folders (overlaps T-075's lane rows in `TimelineGeometry`/`CanvasPainter`: additive).
  - **T-083** crash recovery dialog (U, M8): small; DW-224 (absent plugin slots in safe mode, P) and DW-226.
  - **T-091** DSP performance (D): compressor gain computer block-wise, EQ coefficient path; goldens within tolerance or regenerated with TEST-003 summaries; verify with `scripts/ci.sh perf`.
- If you run all four: T-065 and T-081 both touch MixerView/arrange only additively; T-083 touches AppModel/ToastCenter. Merge T-083 first (smallest).
- Small lead items: DW-261 (CI Xcode), DW-265, DW-066 (package rename), DW-239, DW-244.
- Backlog the user chose: a per-track MIDI input/channel picker, DW-232 (wrap jump for the other built-ins).

## Decisions taken this phase (see docs/autobuild/DECISIONS.md, phase 9 rows)
- Wave 9 = T-075, T-063, T-080, T-084 (T-083 deferred).
- T-075: `RecordAutomation` + per-lane suspend flag; stopped edits move a point at the playhead, else a held SetParam; DW-236 refuses lanes on non-automatable built-ins at command time, `validate()` stays lenient.
- T-080: engine reports pass starts; partial last pass is a take; default comp = latest covering take; folder clips are the newest under T-035's rule; MIDI takes behind a non-persisted record option.
- T-063: own IPlugView in the test plugin (no vstgui4), AU generic-view fallback, plugin edits as one SetParam gesture; first-edit undo pushes the pre-gesture baseline (option c).
- T-084: CI on push to main (test job only), sanitizer/perf on dispatch + weekly; the worker fixed the two sanitizer fixture findings; TEST-008 keeps its 10× bound → new task T-091.

## Sessions only the user can close
- In the sidebar: the "macDAW" conductor session (it closes this lead). Phase lead 9 closed all four of its workers.
- Worktrees left on disk (removing them needs `--force` because of submodules, which auto mode denies). All are merged or superseded:
  - `~/.patchbay/worktrees/macDAW/t-023-sidechain`, `t-024-metronome`, `t-025-m2-goldens`, `t-025-m2-goldens-r2`, `t-026-project-metronome`, `t-031-persistence`, `t-032-app-shell`, `t-032-app-shell-r2`, `t-033-arrange-canvas`, `t-034-toolbar-transport`, `t-035-crossfades`, `t-036-m3-goldens`, `t-042-note-commands`, `t-043-piano-roll`, `t-044-m4-goldens`, `t-045-midi-routing`, `t-052-audio-recording`, `t-055-audio-prefs`, `t-056-session-rate`, `t-061-au-hosting`, `t-071-compressor`, `t-072-delay`, `t-073-reverb`;
  - phase 6: `t-053-coremidi`, `t-062-vst3-hosting`, `t-070-eq`, `t-076-mixer-view`.
  - phase 7: `t-054-input-monitoring`, `t-064-host-bypass`, `t-074-automation`, `t-082-export-dialog`.
  - phase 8: `t-077-m7-goldens`, `t-088-insert-chain`, `t-089-transport-followups`, `t-090-app-followups`.
  - new in phase 9: `t-063-plugin-editors`, `t-075-automation-recording`, `t-080-loop-takes`, `t-084-ci`.
  - Remove them with `git worktree remove --force <path>`, then `git branch -D <branch>`. The old remote WIP branches `origin/t-025-m2-goldens`, `t-031-persistence` and `t-032-app-shell` can be deleted too.

## Open questions for the user (not yet answered)
- Everything asked before phase 8 is answered (DECISIONS.md → *User review*). Still the user's:
  - Manual checks in the app: DW-166 (UI-010 Instruments run with 1,000 clips), DW-206 (UI-031 Instruments, 100-strip scrolling), DW-222 (export "Choose…" panel), DW-247 (headphone jack on Apple Silicon reads 'hdpn', else the feedback guard warns falsely), T-034's key check (Space, R, L, ⌘E, ⌫, ⌘T).
  - Whether to file Apple Feedback for DW-214 (evidence in the T-070 DW-214 report section).
  - Review the phase-8 rows in DECISIONS.md.
  - Review the phase-9 rows in DECISIONS.md (T-063 first-edit undo, T-084 CI scope and TEST-008/T-091 are the notable ones).
  - `gh` reports `afritzsch/ember-studio` as **PUBLIC** (earlier handovers said private). Pushes and the new CI publish the code; make it private again if that wasn't intended (hosted macOS minutes then count against the plan).

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
- **Phase 9 additions:**
  - **Start workers one at a time.** Three `new_session` calls in one batch made two worktree setups fail with "could not lock config file .git/config" (submodule URL registration). The session is left at a shell prompt; recover by `send_input` of `scripts/bootstrap.sh && scripts/dawmcp.sh --build-only && claude --mcp-config "/Users/artem/Library/Application Support/Patchbay/mcp-config.json" --settings "/Users/artem/Library/Application Support/Patchbay/claude-settings.json" "<prompt>"` into that shell, one shell at a time (wait ~45 s between them). Patchbay tracks the agent normally afterwards.
  - Budget: four workers took the 5-hour window from 1% to 92% in ~35 min; after the ~4.2 h pause, finishing all four (two follow-ups, three trial merges) took it 0% → 80%. The week went 0% → 24%.
  - Merging in report order with the others still running worked again: T-075 → T-080 (add-only conflicts resolved with a Python regex over the markers) → T-084 → T-063 (its worker merged main itself after the decision follow-up). Every trial merge was 12/12 even with workers running.
  - Asking the CI worker to fix the sanitizer findings it found (test-only) beat leaving named skips.
  - The wall-clock flakes (ENG-050, CTL-031, SyncCost) are gated behind `DAW_PERF_TESTS=1` since T-084; if they still fail in a plain run, that's new.

## Your first job
1. Run `usage.sh`; check the skill's *Stop the run* conditions.
2. Check the first CI run of the phase-9 push (`gh run list --limit 3`, `gh run view <id> --log-failed`). If it failed for an environmental reason (Xcode version, DW-261), fix `ci-job.yml` as a small lead item and push.
3. `list_sessions`, pick the wave (see *Suggested next wave*), log pre-decisions in DECISIONS.md, mark the tasks `wip(...)`, commit, and start the workers **one at a time** with `.git/autobuild/common.txt` (write each briefing to `.git/autobuild/brief-T-XXX.txt`; the generator from phase 9 is easy to redo with Python, use triple-quoted strings; edit `watch5.sh`'s glob for your tasks; it currently watches t-0{63,75,80,84}).
4. Review, trial merge, timed tests, merge, close each worker, then hand over, push and write `.git/autobuild/phase-10.done`.
