You are AUTOBUILD phase lead 11. Read CLAUDE.md, then `.claude/skills/autobuild/SKILL.md`, then follow "Orchestrating with Patchbay" in specs/90-tasks.md. Use the Patchbay MCP tools for workers, never the Agent tool. The run log is `docs/autobuild/RUN.md` and the decisions taken without the user are in `docs/autobuild/DECISIONS.md`.

**This run's WEEK_STOP is 90, not 50.** The user raised it because they had a free usage reset; the conductor relayed the instruction in phase 10. Stop only for week ≥ 90 or the skill's other *Stop the run* conditions.

## State at handoff (2026-11-17, end of autobuild phase 10; main @ the "Autobuild phase 10: handover" commit, pushed; clean; no worker sessions running)
- Phase 10 merged all four wave tasks. Every trial merge ran `scripts/test.sh` (12/12) plus two timed `swift test` runs. The only failures were known load flakes, which passed when re-run alone.
  - **T-083** crash recovery dialog (UI-043, DW-224, DW-144, part of DW-226):
    - After a crash (the running marker of a dead pid), launch shows a dialog strip in every window: Open with Plugins Disabled / Open Normally / Don't Open, and a per-project "Recover autosave". `--crash-marker-dir` injects markers for tests.
    - **Safe mode now builds AU/VST3 slots as absent:** `"disabled": true` in configJSON, the plugin is never instantiated, and its state blob is saved back byte for byte.
    - Safe-mode banner with "Enable Plugins"; ui.state `crashRecovery` and per-window `safeMode`; `pluginMisbehaved` has its own toast.
  - **T-081** take folder / comp UI (UI-016). **M8's UI is complete.**
    - A collapsed folder shows its comp with a disclosure triangle; expanded, it shows one row per take (`TimelineGeometry.takeBands`, alongside T-075's lane rows).
    - Swipe comping makes one `SetCompSelection` per swipe; folders can be deleted.
    - ui.state `takes`; ui.perform `swipe {start, end}`.
  - **T-065** device chain view + plugin manager (UI-032, UI-041, DW-015, DW-196, DW-250, DW-253, DW-254, DW-264, DW-226, DW-265). **M6 is complete.**
    - `Shell/DeviceChain/`: generic cards from ParamInfo (steps/labels become menus and toggles); bypass, reorder, remove and add, including the master; sidechain picker.
    - Editable mixer inserts; plugin params in "+ Lane"; device controls go through the automation recorder.
    - `Shell/PluginManager/` (scan, blocked list, rescan) on the new **`PluginCatalog` library product**. `PluginScanner` is embedded in the app and signed with the app's entitlements.
    - `ParamInfo.steps`/`valueLabels` (06 delta).
  - **T-091** DSP performance (TEST-008):
    - Stereo NEON biquads, a block-wise compressor with `dsp/FastDb.h`, a vectorized reverb network, and cheaper meters, clip player and DelayLine.
    - **10.7× realtime** in `scripts/ci.sh perf` (the bound is 10×), measured in Low Power Mode with other workers running (DW-281).
    - No golden was regenerated; all null at −240 dBFS.
- Lead items this phase:
  - **CI (DW-261, partial):**
    - The first CI run (on the phase-9 push) failed to compile. GitHub's macos-15 image tops out at Xcode 26.3, and a probe on macos-26 found Xcode 26.6 at most (no 27, not even a beta). The code needs Xcode 27 / Swift 6.4.
    - `ci-job.yml` now runs on `${{ vars.CI_RUNNER || 'macos-26' }}` and fails fast in the Xcode step with a clear error.
    - **CI stays red until the user sets the repo variable `CI_RUNNER` to a self-hosted runner with Xcode 27, or GitHub ships an Xcode 27 image.** Don't spend more time on it.
  - DW-066: the package is now named "EmberStudio" (the `name:` in Package.swift; nothing else referred to it).
  - Created follow-up tasks **T-092..T-096** from open DW items (DECISIONS "Phase 10 follow-up tasks").
- Done & merged (72): T-001..T-026, T-030..T-036, T-040..T-045, T-050..T-056, T-060..T-065, T-070..T-077, T-080..T-091. **M1–M8 are complete.**
- No `wip` tasks, no WIP branches.
- **Ready (5):** T-092 (D+E), T-093 (E+M+U), T-094 (P), T-095 (U+M), T-096 (B+U). See 90-tasks.md → *Follow-ups from autobuild phase 10*.
- Discovered work runs DW-001..DW-281.
  - New this phase: DW-266..268 (T-083), DW-269..273 (T-081), DW-274..278 (T-065), DW-279..281 (T-091).
  - Closed: DW-015, 066, 144, 176, 196, 224, 226, 250, 253, 254, 265. Partial: DW-261, 264.
- Phase 10 week usage: 24% → 45%. There was one 5-hour pause of ~4.4 h: the phase started with the window at 82%, so the workers started only after its reset.

## Suggested next wave
- Four of the five ready tasks, one per lane group. My pick: **T-092** (D+E), **T-093** (E+M+U), **T-094** (P), **T-096** (B+U). T-095 (U) waits for the next phase, because T-093 and T-096 already put two workers in App/.
- File split to give them:
  - T-092: the DSP nodes' smoothing/wrap code (users of `automation/WrapJump.h`), `graph/BypassNode.*`, `io/AudioFileWriter.*`, GoldenTests `locate_reset`. It must not touch the ParamInfo tables.
  - T-093: the `Track` model and a new command, the engine's MIDI input routing (record/ and the MIDI input path, additive facade), and a picker in the track header and mixer strip (add-only in MixerView and the track header views).
  - T-094: `Sources/DAWEngine/plugins`, `Sources/PluginScanner`, the plugin part of `pluginInfoJSON`, `Shell/PluginManager/` (timeout/retry UI only).
  - T-096: facade render-job cancel; `Sources/DAWControl`, `dawctl` and `dawmcp` (meters, previewNote, dither); `Shell/Export/` (Cancel button).
- Pre-decide these in DECISIONS before starting:
  - T-093's model shape. Suggestion: `Track.midiInput: {source: endpoint uid or "all", channel: 0 = omni or 1…16}`, defaulting to all/omni so old projects behave as today. Pre-accept the 07/09 Interfaces delta.
  - T-096's control additions. Pre-accept the 13 delta.
  - T-094's `pluginInfoJSON` additions: `steps`, `labels`, and `display` for VST3 via `getParamStringByValue`. Pre-accept the 08/10 delta.
- Small lead items: DW-267 (07/13 cross-references), DW-239 (14 golden table rows), DW-244 (02 ENG-041 passes), and DW-269's spec-13 line for `ui.perform` `start`/`end`.

## Decisions taken this phase (see docs/autobuild/DECISIONS.md, phase 10 rows)
- Wave 10 = T-065, T-081, T-083, T-091 with a strict file split; T-083 merged first.
- T-065 scope: DW-015 (`PluginCatalog` product) and DW-196 (`ParamInfo` steps/labels) now; DW-153 and DW-213 later.
- T-083: safe mode builds AU/VST3 slots as absent (DW-224 option a).
- T-091: goldens are kept if within tolerance, otherwise regenerated with TEST-003 summaries. None needed regenerating.
- DW-261: CI takes its runner from `vars.CI_RUNNER` and fails fast without Xcode 27.
- T-065 scanner signing: the embedded scanner is signed with the app's entitlements. JIT entitlements are left to the user (DW-274).
- Phase 10 follow-up tasks T-092..T-096.

## Sessions only the user can close
- In the sidebar: the "macDAW" conductor session (it closes this lead). Phase lead 10 closed all four of its workers.
- Worktrees left on disk (removing them needs `--force` because of submodules, which auto mode denies). All are merged or superseded:
  - `~/.patchbay/worktrees/macDAW/t-023-sidechain`, `t-024-metronome`, `t-025-m2-goldens`, `t-025-m2-goldens-r2`, `t-026-project-metronome`, `t-031-persistence`, `t-032-app-shell`, `t-032-app-shell-r2`, `t-033-arrange-canvas`, `t-034-toolbar-transport`, `t-035-crossfades`, `t-036-m3-goldens`, `t-042-note-commands`, `t-043-piano-roll`, `t-044-m4-goldens`, `t-045-midi-routing`, `t-052-audio-recording`, `t-055-audio-prefs`, `t-056-session-rate`, `t-061-au-hosting`, `t-071-compressor`, `t-072-delay`, `t-073-reverb`;
  - phase 6: `t-053-coremidi`, `t-062-vst3-hosting`, `t-070-eq`, `t-076-mixer-view`.
  - phase 7: `t-054-input-monitoring`, `t-064-host-bypass`, `t-074-automation`, `t-082-export-dialog`.
  - phase 8: `t-077-m7-goldens`, `t-088-insert-chain`, `t-089-transport-followups`, `t-090-app-followups`.
  - phase 9: `t-063-plugin-editors`, `t-075-automation-recording`, `t-080-loop-takes`, `t-084-ci`.
  - new in phase 10: `t-065-device-chain`, `t-081-take-ui`, `t-083-crash-dialog`, `t-091-dsp-perf`.
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
  - Review the phase-8, phase-9 and phase-10 rows in DECISIONS.md.
  - `gh` reports `afritzsch/ember-studio` as **PUBLIC** (earlier handovers said private). Pushes and CI publish the code; make it private again if that wasn't intended.
  - **New in phase 10:**
    - CI (DW-261): set the repo variable `CI_RUNNER` to a self-hosted Mac runner with Xcode 27, or wait for a GitHub image with Xcode 27. Until then, every push's CI run fails in the Xcode step.
    - DW-274: should the app (and the embedded scanner) get the `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` entitlements? That would let the 46 plugins killed under hardened runtime (UADx, Neural DSP, soothe2, …) load. It is a security trade-off.
    - DW-281: the machine runs in **Low Power Mode**, and TEST-008 measured 10.7× there. Re-run `scripts/ci.sh perf` with it off.

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

## Your first job
1. Run `usage.sh` and check the skill's *Stop the run* conditions (WEEK_STOP = 90 for this run).
2. `list_sessions`: it should show no phase-10 workers.
3. Pick the wave (see *Suggested next wave*), log the pre-decisions in DECISIONS.md, mark the tasks `wip(...)` and commit.
4. Start the workers **one at a time**:
   - Use `.git/autobuild/common.txt`, and write each briefing to `.git/autobuild/brief-T-XXX.txt`. Generate them with Python using a template file and `.replace()`, not an f-string (spec text has braces).
   - Edit `watch5.sh`'s glob for your tasks; it currently watches t-0{65,81,83,91}.
5. Review, trial merge, run the timed tests, merge and close each worker. Then hand over, push and write `.git/autobuild/phase-11.done`.
