You are AUTOBUILD phase lead 14. Read CLAUDE.md, then `.claude/skills/autobuild/SKILL.md`, then follow "Orchestrating with Patchbay" in specs/90-tasks.md. Use the Patchbay MCP tools for workers, never the Agent tool. The run log is `docs/autobuild/RUN.md`; the decisions taken without the user are in `docs/autobuild/DECISIONS.md`.

**User overrides for this run (given to phase lead 13, still in force):** WEEK_STOP = **100**, not 50 (the user wants the whole weekly budget; a free reset follows on Mon 2026-11-23 22:00). "No ready tasks" is not a stop condition while open DW items can be grouped into tasks. Keep waves small enough to finish, merge each finished, green task as soon as it is reviewed, and **push main after every merge** so nothing is lost when the limit hits.


## New user requests (2026-11-19), read before picking work
- The user asked for an Ableton-style browser, a track-list context menu and MIDI clip creation by double-click. Spec'd by the lead with the user's answers (docs/requests/2026-11-19.md): 12 UI-017, UI-018, UI-060..UI-067; 07 MODEL-047; 08 *Contract delta (T-123), PROPOSED*.
- **Priority (user):** T-111 + T-112 first, then M9 (T-122..T-128 in 90-tasks.md, with its wave plan), then everything else.
- T-123 stays blocked until the user accepts the 08 preview delta. Don't accept it on the user's behalf.
## State at handoff (2026-11-18, end of autobuild phase 13; main @ the "Autobuild phase 13: handover" commit, pushed; clean; no worker sessions running)
- Phase 13 (a new run) first grouped open DW items into T-100..T-104 (DECISIONS "Phase 13 follow-up tasks"), then ran a small 3-worker wave. All three merged and were pushed one by one:
  - **T-100** app follow-ups 3 (DW-295, 298, 299, 227, 155, 221, 297): `ui.perform {action: "setText", text}` for text fields (toolbar tempo/signature; 13 delta accepted); audio panel shows device buffer and input latency; compact MIDI picker titles ("All", "Ch 3"); attach-mode `plugins.unblock` and scan `timeoutSeconds`; mixer strip monitor menu shows the monitoring latency (and the strip now redraws on picker/latency changes); `project.open` over the socket toasts the load report; `AppModel.export(_:to:)` removed.
  - **T-102** model follow-ups 3 (DW-296, 113, 112): AU/VST3 descriptors decode without `vendor`/`version`; `RenameBus {busID, name}` / `MoveBus {busID, index}` (07 delta accepted); `SetParam` refuses an index past a built-in kind's published params (via `ParamCatalog.builtin`).
  - **T-101** control/tooling follow-ups 3 (DW-300, 262, 238, 231, 306): dawctl keeps fd-1 writes (chatty plugins) out of its JSONL stdout; test.sh has a `swift-build-tests` warning stage; CTL-031 ProgressTests, REC-005 punch and the T-096 DW-220 cancelJob test wait on conditions instead of wall-clock.
- Done & merged (83): T-001..T-026, T-030..T-036, T-040..T-045, T-050..T-056, T-060..T-065, T-070..T-077, T-080..T-102. M1–M8 are complete.
- **Ready:** T-103 (E+P: app exports re-prepare hosted plugins offline, DW-301; EmberTest per-instance knobs, DW-302) and T-104 (E: engine test cleanups DW-009, 002, 138, 136, 161). No `wip` tasks, no WIP branches.
- Discovered work runs DW-001..DW-307. New this phase: DW-303..305 (T-100), DW-306 (lead; fixed by T-101), DW-307 (T-101). DW-307 (T-101): warning checks only see files compiled in that build (SwiftPM doesn't replay warnings of up-to-date files).
- Phase 13 week usage: 86% → ~92%. No 5-hour pause (the window went 38% → ~78%).

## Your first job (phase lead 14)
1. Run `usage.sh`. With the user's override, stop only at `week ≥ 100` (or the other *Stop the run* conditions).
2. `list_sessions`: there should be no phase-13 workers.
3. Wave 14 = T-103 and T-104 (lanes E+P and E; they overlap in `Sources/DAWEngine` and test support, so give T-104 only test files + Package.swift's DAWEngineTestSupport setting + GraphBuilder's `resetsOnLocate` line, and T-103 the facade/hosting code). A 3-task wave of small tasks cost ~6 week-%; T-103 is larger. If budget is left after them, group more DW items (candidates: DW-303 + DW-304 (B), DW-305 (spec, lead can do it), DW-286 (U+E), DW-245 (U), DW-145 (M), DW-203 (M), DW-263 (P+M)).
4. Items that need the user, not a task: DW-274 (JIT entitlements), DW-294 (expose the master limiter?), DW-293 (inverse shape of Restore commands for orphan lanes), DW-207 (stereo meters), DW-153, DW-215.

## Decisions taken this phase (see docs/autobuild/DECISIONS.md, phase 13 rows)
- Phase 13 follow-up tasks T-100..T-104; wave 13 = T-100, T-101, T-102 (small, to fit the remaining week budget).
- T-100: `ui.perform setText` shape (13 delta pre-accepted); panel/picker/plugin-manager/socket-toast shapes.
- T-101: test-target warnings fail test.sh.
- T-102: lenient descriptor decoding; bus command keys `busID`/`index` (matching the track commands); `SetParam` index refusal.

## Sessions only the user can close
- In the sidebar: the "macDAW" conductor session (it closes this lead). Phase lead 13 closed all three of its workers.
- Worktrees left on disk (removing them needs `--force` because of submodules, which auto mode denies). All are merged or superseded:
  - `~/.patchbay/worktrees/macDAW/t-023-sidechain`, `t-024-metronome`, `t-025-m2-goldens`, `t-025-m2-goldens-r2`, `t-026-project-metronome`, `t-031-persistence`, `t-032-app-shell`, `t-032-app-shell-r2`, `t-033-arrange-canvas`, `t-034-toolbar-transport`, `t-035-crossfades`, `t-036-m3-goldens`, `t-042-note-commands`, `t-043-piano-roll`, `t-044-m4-goldens`, `t-045-midi-routing`, `t-052-audio-recording`, `t-055-audio-prefs`, `t-056-session-rate`, `t-061-au-hosting`, `t-071-compressor`, `t-072-delay`, `t-073-reverb`;
  - phase 6: `t-053-coremidi`, `t-062-vst3-hosting`, `t-070-eq`, `t-076-mixer-view`.
  - phase 7: `t-054-input-monitoring`, `t-064-host-bypass`, `t-074-automation`, `t-082-export-dialog`.
  - phase 8: `t-077-m7-goldens`, `t-088-insert-chain`, `t-089-transport-followups`, `t-090-app-followups`.
  - phase 9: `t-063-plugin-editors`, `t-075-automation-recording`, `t-080-loop-takes`, `t-084-ci`.
  - phase 10: `t-065-device-chain`, `t-081-take-ui`, `t-083-crash-dialog`, `t-091-dsp-perf`.
  - phase 11: `t-092-dsp-followups`, `t-093-midi-input`, `t-094-plugin-followups`, `t-096-control-followups`.
  - phase 12: `t-095-app-followups`, `t-097-plugin-followups`, `t-098-control-followups`, `t-099-engine-model-followups`.
  - new in phase 13: `t-100-app-followups`, `t-101-control-followups`, `t-102-model-followups`.
  - Remove them with `git worktree remove --force <path>`, then `git branch -D <branch>`. The old remote WIP branches `origin/t-025-m2-goldens`, `t-031-persistence` and `t-032-app-shell` can be deleted too.

## Open questions for the user (not yet answered)
- Everything asked before phase 8 is answered (DECISIONS.md → *User review*). Still the user's:
  - Manual checks in the app:
    - DW-166: UI-010 Instruments run with 1,000 clips.
    - DW-206: UI-031 Instruments run, 100-strip scrolling.
    - DW-222: the export "Choose…" panel.
    - DW-247: the headphone jack on Apple Silicon must read 'hdpn', or the feedback guard warns falsely.
    - T-034's key check: Space, R, L, ⌘E, ⌫, ⌘T.
  - Whether to file Apple Feedback for DW-214 (evidence in the T-070 DW-214 report section).
  - Review the phase-8 to phase-11 rows in DECISIONS.md.
  - `gh` reports `afritzsch/ember-studio` as **PUBLIC** (earlier handovers said private). Pushes and CI publish the code; make it private again if that wasn't intended.
  - **New in phase 10:**
    - CI (DW-261): **resolved 2026-11-19 (PR #1).** CI runs on GitHub's `xcode-27` image (`vars.CI_RUNNER` still overrides) and the push `test` job is green. Still open in the weekly jobs: PLUG-013's rebuild under ASan/TSan (DW-359) and TEST-008 at 9.4–9.6× vs the 10× floor on some hosted runs (DW-360, a call for the user).
    - DW-274: should the app (and the embedded scanner) get the `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` entitlements? That would let the 46 plugins killed under hardened runtime (UADx, Neural DSP, soothe2, …) load. It is a security trade-off.
    - DW-281: the machine runs in **Low Power Mode**, and TEST-008 measured 10.7× there (11.4× after T-092). Re-run `scripts/ci.sh perf` with it off.
  - **New in phase 11:**
    - T-093 changes MIDI takes: with several armed MIDI tracks, a track whose filter passed no note gets no take (before, every armed track got every note). With default filters nothing changes.
    - DW-288: the > 1.5 s "Enable Plugins" delay is on the app side; a manual timing in the running app would locate it.
  - **New in phase 13:**
    - Review the phase-13 rows in DECISIONS.md.
    - T-100 behavior to check in the app: compact MIDI picker titles, the audio panel's device buffer / input latency line, the mixer strip monitor menu's latency line.
    - The machine is still in Low Power Mode (`pmset -g` → lowpowermode 1), see DW-281.
  - **New in phase 12:**
    - Review the phase-12 rows in DECISIONS.md, especially the stop decision.
    - DW-294: the model never enables the master limiter, so telemetry `clippedSamples` stays 0. Should the limiter be exposed (command/setting + UI)?
    - DW-293: `SetAutomationLane` can still make orphan lanes; closing it changes the inverse shape of `RestoreSend`/`RestoreDevice`/`RestoreInstrument`.
    - T-095 behavior to check in the app: per-slot "Enable this plugin" in safe mode, arrow-key clip nudge, editable toolbar tempo/signature (they set bar 1's values), the header layout at 220 pt.

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
- **Phase 10 additions:**
  - **Starting a phase with the 5-hour window high (82%):** prepare everything first (decisions, wip marks, briefings, watcher glob). Then background-sleep until the reset and start the workers after it. It costs a few % of the window and loses no worker time.
  - Budget: four workers took the window from 0% to 87% in ~45 min. After the ~4.4 h pause, finishing all four (one follow-up, four trial merges) took it from 0% to ~65%. The week went from 24% to ~46%.
  - `wait_for` right after `new_session` moves to the background after 120 s while the worktree setup (bootstrap + dawmcp build) runs. That's fine; wait for its notification. Starting workers one at a time again caused no setup failures.
  - A `( … ) &` inside a run_in_background command returns at once. The subshell keeps running, but you get no notification when it ends. Instead, run the test chain in the foreground of the background command (one command, `;`-separated), so its completion notifies you.
  - Known load flakes under 3–4 workers:
    - PersistenceTests MODEL-044/DW-148 (60 s time limits);
    - PluginEditorTests DW-204 (DW-276).

    Before merging, re-run the failing suite alone (`swift test --filter …`, 2–3×). Both were green alone every time.
  - GitHub-hosted macOS images lag behind Xcode releases. To probe one:
    1. Push a side branch.
    2. Run `gh workflow run ci.yml --ref <branch>`. The Xcode step lists `/Applications/Xcode*.app`.
    3. Delete the branch.
  - Answer a worker's "open points" from a pause REPORT mid-run. T-065's scanner-signing question raised the usable plugins from 29 to 107.

- **Phase 11 additions:**
  - `new_session` once failed with "<folder> isn't in a git repository" right after another worker's setup started. Retrying after ~40 s worked (likely the same transient lock as the phase-9 config lock).
  - Budget: four workers took the 5-hour window from 3% to 85% in ~55 min. The pause was ~2.2 h. After the reset, finishing three workers and three trial merges took it 0% → 40%. The week went from 46% to ~63%.
  - Merging a finished worker during the pause worked again: T-096 was trial-merged and merged while the others were paused.
  - When two branches that share add-only files (FakeEngine `Call` cases, 08/13 contract deltas) are already merged, ask the remaining worker to `git merge main` **before** its final test runs (T-094). Then its tests cover the merged result, and the lead's trial merge is conflict-free.
  - The DW follow-up tasks were well sized: each worker took 1–2 h including the pause, and none needed a follow-up round.
  - A worker measuring perf under load alternated before/after runs and waited for the load average to drop. That gave usable TEST-008 numbers even with other workers running.

- **Phase 12 additions:**
  - Budget: four workers took the 5-hour window from 42% to 88% in ~16 min (the week 62 → 69). After the reset, finishing all four (two report-and-test rounds, four trial merges) took it 0% → 85% again, and the week to 85%. A phase now costs ~23 week-%, more than earlier phases.
  - DW table rows are not in numeric order (DW-292 sits after DW-290); compute the next DW number as the max over all rows, not from the last row.
  - Unescaped `|` inside backticks breaks a Markdown table row (`clip.nudge.left|right`). Write `\|` in table cells; a cell-count check per row catches it.
  - A worker's "the RT violation is load-dependent" can be wrong: T-097's export RT violations were deterministic (clean renders 1–5, then 14 violations each) once the model held all params. Asking for the backtraces/bisect found the real cause.
  - Answering a worker's pause-REPORT note on resume (T-095's ProjectStore question, T-097's render-thread wait) avoided a review round.

- **Phase 13 additions:**
  - A new run that starts with no tasks: group DW items into lane-separated tasks, log it in DECISIONS, commit and push, then start the wave. Pre-deciding every shape in the briefings again meant no worker stopped with a question.
  - Budget: three small tasks took the 5-hour window 38% → ~78% and the week 86% → ~92% for the whole phase (workers reported within 15–30 min). Small DW tasks are cheap; the 4-task phases cost ~23 week-% because the tasks were bigger.
  - Merge each task as soon as its report is in (the user wants main pushed after every merge); keep the next trial merge going while a worker does a follow-up.
  - A trial-merge flake in another lane's test (DW-306) is a good small follow-up for the B/testing worker that's waiting for its merge.
  - `.git/autobuild/close_dw.py TASK "DW-a,DW-b" [newrows.txt]` marks a task done, closes its DW rows and appends new DW rows (checks the cell count of the rows it touches; several older rows have unescaped `|` and fail a global check).

