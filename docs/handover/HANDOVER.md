Autobuild stopped: user asked to finish after phase 7. To continue, start a new run with `/autobuild` (the conductor numbers the next phase 8); its first lead reads this file. Read CLAUDE.md, then `.claude/skills/autobuild/SKILL.md`, then follow "Orchestrating with Patchbay" in specs/90-tasks.md. Use the Patchbay MCP tools for workers, never the Agent tool. The run log is `docs/autobuild/RUN.md` and the decisions taken without the user are in `docs/autobuild/DECISIONS.md`.

## State at handoff (2026-11-10, end of autobuild phase 7; main @ the "Autobuild phase 7: handover" commit, pushed; clean; no worker sessions running)
- Phase 7 merged all four wave tasks:
  - **T-082** export dialog (UI-042): `Shell/Export/ExportModel.swift` + `Views/ExportView.swift`, a strip under the toolbar opened by File > Export… (⇧⌘E). Range whole/loop/selection, file type, sample format, dither (follows the format), normalize off, tail, "Include Metronome" off (DW-177). Additive `ExportSpec.normalize` (sample peak to −0.1 dBFS, two-pass float spool in `OfflineDriver`) through the facade and `render.offline {normalize?}`; golden `export_normalize`. `export.*` ids, `ui.state` `export`; 12 "Export dialog details".
  - **T-064** host bypass / NaN guard / crash marker (PLUG-018, 020..022): undoable `SetDeviceBypass`; bypassed devices stay in the graph inside a `BypassNode` (latency-matched pass-through, bypass is a slot write, one-block crossfade; `NodeDesc::bypassParam`). Plugin nodes silence NaN/inf, count it in `nanBlocks` and emit `pluginMisbehaved{slot}` once. Running marker (`running-<pid>.json` in Application Support; `$TMPDIR` for automated launches) + safe-mode open (session-only host bypass of every plugin slot; `project.open {safeMode}`); AppDelegate hook. Golden `plugin_bypass_null`. The dialog is T-083.
  - **T-054** input monitoring (REC-020..022): `GraphDescription.monitors`, mode as a slot (`GraphNodeID.monitor`, role 6), `auto` evaluated per block on the audio thread, monitored input replaces the clip player into the insert chain (64-frame crossfade; pre-roll silent), arming is now structural (a new graph). `setMonitorInput`, telemetry `monitoringLatency`/`monitorInput`; latency line in the track header's monitor menu. Golden `input_monitoring_loopback`; `record_loopback_alignment` now sets monitoring off (reference unchanged). **M5 complete.**
  - **T-074** automation (AUTO-001..005, 008..010): model lanes on channels (`automation`, one lane per target, undoable AUTO commands, inverse `SetAutomationLane`), `Sources/DAWEngine/automation/` (`AutomationPlayer`, `AutomationSet`, `AutomationCompiler`; mapping through ParamInfo / AU ranges / VST3 identity), evaluated in `Engine::render` after `Transport::advance`, before pre-roll and nodes. Mid-block loop-wrap jump (`ParamSlotTable::afterWrap`, `ParamRamp.jumpAt/after`) for ChannelStrip and GainNode only. Goldens `automation_ramp`, `automation_loop_wrap` (+ computed VST3 lane).
- Done & merged (60): T-001..T-026, T-030..T-036, T-040..T-045, T-050..T-056, T-060..T-062, T-064, T-070..T-074, T-076, T-082, T-085..T-087.
- No `wip` tasks, no WIP branches.
- **Ready (5):** T-063 plugin editors (P+U, M6), T-075 automation recording + lane UI (U+M, M7), T-077 M7 goldens (D, M7), T-080 loop takes/comping (E+M, M8), T-083 crash recovery dialog (U, M8).
- Discovered work runs DW-001..DW-238. New this phase: DW-219..238 (render.offline dither default, export cancel, AppModel.export cleanup, Choose… manual check, UI-010 load flake; safe mode still instantiates plugins, instrument bypass hangs notes, mixer bypass toggle/safe-mode display; mixer monitor latency, pre-roll gap, input latency before input runs, feedback protection, CTL-031/REC-005 load flakes; wrap jump for other built-ins and plugins, orphaned lanes, Bus/Master `automation` key, model `automatable` flags, stopped-lane writes, a T-064 test warning). Closed: DW-098, DW-177, DW-187, DW-188, DW-195; DW-149 partial (`SetDeviceBypass`).
- Last trial merges: T-082 11/12, T-064 11/12, T-054 11/12 (only the UI-010 perf smoke each time, DW-223; alone 3× green), T-074 12/12; swift test 2× after each merge failed at most UI-010.
- Phase 7 week usage: 20% → 42% (two 5-hour pauses of ~3.7 h and ~4 h; T-082 and T-064 merged during the second).

## Suggested next wave (for a new run)
- **User answers on 2026-11-10 (DECISIONS.md → User review → Older open questions):** new work to schedule: DW-061 playhead keeps ticks on tempo edits; DW-063 exports reset nodes; DW-125 transport handles sub-block loops; DW-156 one engine per app; velocity-0 notes repaired on open (DW-150); export dialog's metronome checkbox follows the metronome; play waits for re-conversion (T-056). Spec housekeeping DWs are yours to decide.
- **User review after phase 7 (see DECISIONS.md → User review):** all phase 6–7 decisions confirmed. Schedule early: DW-149 insert-chain commands, DW-234 (delete lanes with their send/device, one undo step), DW-230 feedback guard for monitoring. Backlog: per-track MIDI input picker, DW-232.
- **T-075** automation recording + lane UI (U+M, M7): read DW-236 (only automatable params) and DW-237 (stopped writes) first.
- **T-077** M7 goldens (D): could also take DW-232 (wrap jump for the other built-ins).
- **T-063** plugin editors (P+U, M6): needs vstgui4 or an own `IPlugView` test plugin (DW-208) and the plugin → model param path (DW-204). U overlaps T-075; pick one U task per wave, or run T-063 with a strict file split.
- **T-080** loop takes/comping (E+M, M8) or **T-083** crash recovery dialog (U, M8; T-064's marker API and DW-224/226 are ready).
- Expect UI-010's perf smoke to fail in every full run under load (DW-223): fixing its threshold would make trial merges read 12/12 again.

## Decisions taken this phase (see docs/autobuild/DECISIONS.md)
- T-054: additive contract (monitors, `setMonitorInput`, `monitoringLatency`); `auto` evaluated per block on the audio thread.
- T-064: undoable `SetDeviceBypass`, bypassed devices stay in the graph; running marker + session-only safe mode; additive `pluginMisbehaved` event.
- T-074: 11 Interfaces as written, lanes on channels, `AddAutomationPoints` creates lanes, all AUTO commands undoable; small core/nodes edits allowed for the AUTO-003 wrap jump.
- T-082: additive `normalize` (−0.1 dBFS); selection = selected clips' span.
- Not logged as user decisions (accepted at review): T-054 arming is now structural (a new graph) and the default `auto` monitors an armed track while recording; T-064 reports `pluginMisbehaved` once per node instance; T-082's always-listed toggle is `export.dialog`.

## Sessions only the user can close
- In the sidebar: the "macDAW" conductor session (it closes this lead). Phase lead 7 closed all its own workers.
- Worktrees left on disk (removing them needs `--force` because of submodules, which auto mode denies). All are merged or superseded:
  - `~/.patchbay/worktrees/macDAW/t-023-sidechain`, `t-024-metronome`, `t-025-m2-goldens`, `t-025-m2-goldens-r2`, `t-026-project-metronome`, `t-031-persistence`, `t-032-app-shell`, `t-032-app-shell-r2`, `t-033-arrange-canvas`, `t-034-toolbar-transport`, `t-035-crossfades`, `t-036-m3-goldens`, `t-042-note-commands`, `t-043-piano-roll`, `t-044-m4-goldens`, `t-045-midi-routing`, `t-052-audio-recording`, `t-055-audio-prefs`, `t-056-session-rate`, `t-061-au-hosting`, `t-071-compressor`, `t-072-delay`, `t-073-reverb`;
  - phase 6: `t-053-coremidi`, `t-062-vst3-hosting`, `t-070-eq`, `t-076-mixer-view`.
  - new this phase: `t-054-input-monitoring`, `t-064-host-bypass`, `t-074-automation`, `t-082-export-dialog`.
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

- **Budget (phase 7):** four workers took the 5-hour window from 63% to 87% in ~13 min (it was already high at the start); after the reset, two big workers plus the lead took it 0% → 86% in ~53 min. The week went 20% → 42%. Starting a wave with the window above ~50% buys only minutes of work before the pause.
- **Merging finished workers during a pause works (phase 7 again):** T-082 and T-064 were trial-merged and merged while the other two were paused; only tool calls of the lead count against the window.
- **UI-010's perf smoke now fails in most full runs (phase 7, DW-223)**, even with the workers paused, when the user's other apps load the machine. Judge it by running `swift test --filter ArrangeModelTests` alone (3× green each time).
- **Merge order for E-lane overlap:** T-054 and T-074 both edited `RenderGraph`, `Engine.cpp`, `GraphBuilder` and `GraphDescription.h`. Merging one, then having the other worker `git merge main` (it resolved and checked the render order itself), was clean.
- **Workers read briefings from `.git/autobuild/brief-T-XXX.txt`:** a short new_session prompt pointing at the file keeps list_sessions output small and works (a scratchpad path outside the worktree also worked).

## Open questions for the user (not yet answered)
**Answered by the user on 2026-11-10:** DW-061, DW-063, DW-125, DW-156, DW-230, DW-234, every decision row in DECISIONS.md (phases 1–7) and the UX choices below. See DECISIONS.md → *User review*. The spec-housekeeping DWs below are delegated to the lead. What's still the user's: the manual checks in the app (DW-166, DW-206, DW-222, T-034's key check) and whether to file Apple Feedback (DW-214).

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
- New in autobuild phase 7:
  - Review the eight phase-7 decisions in `docs/autobuild/DECISIONS.md` (T-054 contract/auto, T-064 bypass/crash marker/NaN event, T-074 contract/wrap jump, T-082 normalize).
  - DW-222: the export dialog's "Choose…" (NSSavePanel) needs a manual check in the app.
  - DW-230: monitoring has no feedback protection (a speaker → mic setup howls when `auto` monitors an armed track while recording).
  - Answered by the user after phase 7: the eight phase-6 and eight phase-7 decisions are confirmed; DW-230 → add a feedback guard; DW-234 → delete lanes with their target in one undoable step (see DECISIONS.md → User review).

## Your first job
1. This run stopped because the user asked. A new run starts with `/autobuild`; its first lead is phase 8.
2. Run `usage.sh`; check the skill's *Stop the run* conditions.
3. `list_sessions`, pick the wave (see *Suggested next wave*), log pre-decisions in DECISIONS.md, mark the tasks `wip(...)`, commit, and start the workers with `.git/autobuild/common.txt` (write each briefing to `.git/autobuild/brief-T-XXX.txt`; edit `watch5.sh`'s glob for your tasks; it currently watches t-0{54,64,74,82}).
4. Review, trial merge, timed tests, merge, close each worker, then hand over, push and write `.git/autobuild/phase-8.done`.
