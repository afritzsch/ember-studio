You are AUTOBUILD phase lead 2. You run in the main checkout /Users/artem/dev/macDAW on branch main. Read CLAUDE.md, then `.claude/skills/autobuild/SKILL.md` (Phase lead), then follow "Orchestrating with Patchbay" in specs/90-tasks.md with the skill's overrides. Use the Patchbay MCP tools for workers, never the Agent tool. The run log is `docs/autobuild/RUN.md` and the decisions taken without the user are in `docs/autobuild/DECISIONS.md`.

## State at handoff (2026-11-02, end of autobuild phase 1; main @ the "Autobuild phase 1: handover" commit, pushed; clean; no worker sessions running)
- Phase 1 merged all four wave tasks:
  - **T-035** overlapping-clip crossfades (DSP-002): later clip by (start, clipID) wins, with 64-sample equal-power crossfades; golden `clip_overlap_crossfade`.
  - **T-025** M2 goldens: `pan_law`, `bus_send_sum`, `pdc_alignment_null`, `send_ramps`, each with per-sample reference checks.
  - **T-042** note commands + MIDI instrument slot + sampler zones (DW-127, DW-140), plus the MODEL-044 autosave race fix (DW-148).
  - **T-032** app shell + attach mode: AppKit windows, File menu, view models in a new `EmberStudioShell` SwiftPM target, toasts, ui.state/perform/snapshot, ControlSocketServer/Client, `dawctl --attach`, `daw_session_mode`, progress notifications. It also fixed DW-146.
- Done & merged (38): T-001..T-022, T-025, T-030..T-032, T-035, T-040..T-042, T-050, T-051, T-060, T-085..T-087.
- No `wip` tasks.
- **Ready (12):** T-023 sidechain (E), T-024 metronome (D), T-033 arrange canvas (U), T-034 toolbar/transport (U), T-036 M3 goldens (E, test-only files), **T-045 MIDI edge routing (E, new: DW-099; makes MIDI + sampler audible; T-044 depends on it)**, T-056 session-rate change (E+M), T-070 EQ, T-072 delay, T-073 reverb (D), T-076 mixer view (U), T-082 export dialog (U).
- Discovered work runs DW-001..DW-157. New this phase: DW-146..157 (most are closed or small; see the table).
- `scripts/test.sh` is 11/11 on main, and `swift test` was green 2× after every merge. The CoreAudio device test passes; no skip is needed.

## Suggested next wave
Earliest milestone first:
- T-023 (E, M2)
- T-024 (D, M2)
- T-033 (U, M3; the critical UI path; note DW-154 for Metal snapshots)
- T-045 (E, unblocks M4)

T-023 and T-045 are both E lane but touch different areas: T-023 is sidechain ports in graph/ (MIX-008), and T-045 is MIDI data in RenderGraph/GraphBuilder. They overlap in `Sources/DAWEngine/graph`, so either run them one after another or give them disjoint file lists. If you'd rather not split them, pair T-023 with T-036 (goldens, Tests/GoldenTests only) and push T-045 to the next phase.

## Sessions only the user can close
- In the sidebar: "macDAW" sessions (the conductor and an older "push to main" session). Phase lead 1 closed all its own workers.
- Worktrees left on disk, because removing them needs `--force`, which auto mode denies. All are merged or superseded:
  - `~/.patchbay/worktrees/macDAW/t-025-m2-goldens`, `t-025-m2-goldens-r2`, `t-031-persistence`, `t-032-app-shell`, `t-032-app-shell-r2`, `t-035-crossfades`, `t-042-note-commands`.
  - Remove them with `git worktree remove --force <path>`, then `git branch -D <branch>`. The old remote WIP branches `origin/t-025-m2-goldens`, `t-031-persistence` and `t-032-app-shell` can be deleted too.

## Environment note: CoreAudio
- On 2026-10-28 CoreAudio delivered no IO cycles for a while (environmental). On 2026-11-02 `swift test --filter CoreAudioDriverTests` passed on main.
- Only if it fails with 0 cycles, use `DAW_SKIP_DEVICE_TESTS=1` and say so in merge commits.

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

## Your first job
1. Run `usage.sh`, then `list_sessions`.
2. Pick the wave (see *Suggested next wave*), mark the tasks `wip(...)`, commit, and start the workers with the briefing template.
   - Add to every briefing: the other workers' files ("do NOT touch"), the add-only shared files, the untracked REPORT.md, "Questions for the lead" instead of waiting for the user, and "verify new commands/engine changes with a freshly built dawctl/dawmcp".
3. Follow the skill: review, trial merge, test, merge, close each worker, then hand over and push.
