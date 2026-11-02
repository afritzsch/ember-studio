You are the LEAD for Ember Studio, taking over from a previous lead session. You run in the main checkout /Users/artem/dev/macDAW on branch main. Read CLAUDE.md, then follow "Orchestrating with Patchbay" in specs/90-tasks.md. Use the Patchbay MCP tools (new_session, wait_for, read_output, send_input, close_session, list_sessions) for workers, never the Agent tool.

## State at handoff (2026-10-28; main clean; no worker sessions running)
- **M1 is complete** (exit verified and recorded under "M1 exit met" in specs/90-tasks.md).
- Done & merged (33): T-001..T-022, T-030, T-040, T-041, T-050, T-051, T-060, T-085, T-086, T-087. Last session merged T-017, T-022, T-040, T-051, T-030, T-018, T-019, T-041.
- Discovered work runs DW-001..DW-142 in specs/90-tasks.md.
- Stale sessions in the sidebar (older leads, e.g. "Ember Studio lead", "Ember Studio lead 2") can't be closed by you; only the user can.
- New since last handoff:
  - `.claude/settings.json` enables the `.mcp.json` dawmcp server (user decision, DW-129).
  - `.patchbay.json` setup now ends with `scripts/dawmcp.sh --build-only`, so worktree setup takes a few minutes longer; wait_for ~400 s for "Working".
  - The app's `Package.resolved` is committed (swift-sdk 0.12.1).

## Stopped mid-work (the user ended the session at the weekly limit); three worktrees kept
Each worker committed its work and wrote a "## Status at stop" section at the top of its report. **Read the reports before anything else**; they contain exact next steps. Permanent copies are in this folder: `docs/handover/T-031-REPORT.md`, `T-032-REPORT.md` and `T-025-REPORT.md`. The originals are untracked `REPORT.md` files in each worktree, if those still exist. The tasks are still `wip(<branch>)` in specs/90-tasks.md.

All branches are pushed to the private GitHub repo `afritzsch/ember-studio` (remote `origin`): `main` and the three WIP branches. If a worktree is gone, `git fetch origin` and start the worker from `origin/<branch>`.

1. **T-031 persistence** (`~/.patchbay/worktrees/macDAW/t-031-persistence`, branch `t-031-persistence` @ 9d8ac25). Code complete, including the lead-approved DAWControl part:
   - `Dispatcher.projectOpen` returns `ProjectLoadReport`; headless runs don't autosave.
   - The stale `DispatcherMethodTests` open/save test is fixed; there's a dawctl `--recover` test.
   - Only the final `scripts/test.sh` at 9d8ac25 wasn't run.
   - Next: run it there. If green, review and merge (MODEL-040..042, 044..046; MODEL-043 is a seam only).
   - Its DW items to record on merge are in its REPORT (plugin state restore for P, recovery UI for U, autosave location for never-saved projects).
2. **T-032 app shell** (`t-032-app-shell` @ 9098a3f): early WIP.
   - Committed: ControlSocketServer/Client, socket paths, progress notifications (CTL-030/031/032).
   - Not started: the app window and view models, toasts, UI dump/snapshot, `dawctl --attach`, `daw_session_mode`.
   - Merge T-031 first, then resume T-032 with `git merge main`. Expect small conflicts in `Sources/DAWControl/Dispatcher.swift` around `projectOpen`/`install`; T-032 deliberately didn't touch them.
3. **T-025 M2 goldens** (`t-025-m2-goldens` @ 31dd787): early WIP and **not green**.
   - Committed: the `pan_law` fixture with no reference yet, M2 assets, and a per-channel `# @expect` option.
   - Its REPORT holds the full plans for `bus_send_sum` and `pdc_alignment_null`. PDC goes through `RestoreTrack`/`RestoreBus` with builtin insert kinds + `@node fakeLatency`.
   - Resume by giving a new worker that REPORT's next steps.

**How to resume a stopped worker:**
- `new_session(branch: "<same branch>")` checks out the existing branch.
- If Patchbay refuses because the worktree already exists: copy REPORT.md somewhere safe (it's untracked), then `git worktree remove --force <path>` (the branch keeps its commits) and start again.
- Put the REPORT's "Status at stop" into the new briefing, plus the usual template.

T-035 crossfades was stopped before its agent started; it's back to `ready` and its branch is deleted.

## Ready now
T-023 sidechain (E), T-024 metronome (D), T-035 crossfades (D), T-042 note commands + instrument slot (M; start after T-031 merges, same lane), T-056 session-rate change (E+M), T-070 EQ, T-072 delay, T-073 reverb (D).
- Ask the user before starting a wave. Last time they approved waves one at a time, via AskUserQuestion.
- T-035's briefing from last session is a good template:
  - It owns `nodes/AudioClipPlayer.*` and `dsp/`, plus its own golden fixture/reference files.
  - It must define "later clip wins" precisely in 06 (clips are sorted by (start, id) since T-030).
  - Its golden uses `asset.import` + `AddClip` with `# @expect`.

## Environment note: CoreAudio
- Midday on 2026-10-28, CoreAudio on this Mac delivered no IO cycles: the real-device test "IO-001/002/003/005: plays a sine…" got 0 cycles even on commits that had passed. It's environmental, not code (it reproduced on 5fe1631).
- The user said they'd fix it themselves. T-031 later reported that test passing again.
- First run `swift test --filter CoreAudioDriverTests` on main. Only if it fails with 0 cycles, use `DAW_SKIP_DEVICE_TESTS=1` and say so in merge commits (as 7fd6550, 48c843a, 04cf18a, e556bde did).

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
- **Remote:** `origin` is the private repo `afritzsch/ember-studio`. Push only when the user asks (they asked at the end of the 2026-10-28 session). Workers never push.
- **Cleanup:** after a merge, close_session, `git worktree remove --force <path>`, `git branch -d <branch>`.
- **Merge order:**
  - When a dependency merges while another worker still runs, send_input that worker to commit, `git merge main`, and wire up the real thing.
  - If merging A would break B's tests (e.g. a stub test asserting `notImplemented`), give the small fix to whichever worker is free with explicit scope, rather than leaving main red.
- **Known false states:**
  - A "Done" status whose footer says "1 shell still running" means the worker is waiting on its own background job.
  - Ignore unsent prompt suggestions in a worker's input line.
- **C++ tests:** use the specs/14-testing.md "C++ unit tests" pattern. RT checks use RtScope::violations(). Under ASan/TSan the RT-trap allocation tests fail by design (DW-054, DW-065).

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

## Your first job
1. Read docs/handover/T-031-REPORT.md, T-032-REPORT.md and T-025-REPORT.md.
2. Finish and merge T-031: run `scripts/test.sh` in its worktree, or have a resumed worker do it.
3. Then tell the user the state and ask which of T-032 (resume), T-025 (resume), T-042, T-035 and the other ready tasks to run next.
