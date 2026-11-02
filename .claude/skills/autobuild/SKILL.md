---
name: autobuild
description: Unattended Ember Studio build loop. A conductor session starts a fresh lead for each phase (one wave), closes it when the phase is done, and stops once weekly plan usage reaches 50%. Use when the user types /autobuild, or with "/autobuild lead <N>" for a phase lead the conductor started.
---

# Autobuild

The user is not watching: **don't ask the user anything** (no AskUserQuestion). Decide using your own recommendation and log the decision.

Everything in CLAUDE.md, `specs/90-tasks.md` → *Orchestrating with Patchbay*, and `docs/handover/HANDOVER.md` → *Lessons* still applies, **except** where this file overrides it (marked **OVERRIDE**).

## Roles
Patchbay lets a session close **only sessions it started**: not itself, and not the session that started it. So the run has two roles:

| Role | Started by | Does |
|---|---|---|
| **Conductor** | `/autobuild` with no argument (the user's session or a scheduled one) | Starts one phase lead at a time, waits for it, **closes it**, starts the next. Never touches git, specs or workers. |
| **Phase lead** | The conductor, with the prompt `/autobuild lead <N>` | Runs exactly one phase (= one wave): starts workers, **closes each worker when it's done**, merges, writes the handover, signals the conductor. |

If the arguments say `lead <N>`, you are phase lead N: skip to **Phase lead**. Otherwise you are the conductor.

Helper: `.claude/skills/autobuild/usage.sh` prints `week=`, `five=` (used %), `week_resets=`, `five_resets=` (epoch) and `age=` (seconds since the cache was updated).

Signal directory: `/Users/artem/dev/macDAW/.git/autobuild/`. It's inside `.git`, so it's never tracked. A phase lead finishes by writing `phase-<N>.done` there, containing `next` or `stop: <reason>`.

## Constants
- **WEEK_STOP = 50.** Once `week ≥ 50`, no new phase starts.
- **FIVE_PAUSE = 85.** Once `five ≥ 85`, pause (see *5-hour window*).
- **Max workers per wave: 4**, in different lanes. Use the critical path first, then the earliest milestone.

---

# Conductor
Keep your own context tiny. Don't read specs or code, and don't review anything. Your job is only start → wait → close → repeat.

1. `git branch --show-current` must be `main`. `mkdir -p .git/autobuild`.
2. Pick N: one more than the highest `phase-*.done` already in the signal directory, else 1. A new run after a previous stop continues the numbering.
3. Run `usage.sh`.
   - **Stale cache.** If `week_resets` is in the past, the cache predates the reset and `week` is stale. Treat it as 0, and re-check after the lead is Working (its status line refreshes the cache).
   - **Started too early.** On the first pass of a scheduled start (the Monday 22:05 automation), the reset may not have happened yet: `week ≥ WEEK_STOP` with `week_resets` within the next 3 h. In that case, background-sleep until `week_resets + 300`, then run `usage.sh` again.
   - Otherwise, if `week ≥ WEEK_STOP`, go to step 7.
4. `list_sessions`. If any `Autobuild lead …` session is Working, another run is active: stop and say so.
5. Start the phase lead:
   ```
   new_session(folder: "/Users/artem/dev/macDAW", agent: "claude",
               name: "Autobuild lead <N>", prompt: "/autobuild lead <N>")
   ```
   Don't pass a `branch`; the lead runs in the main checkout. `wait_for` until it's Working.
6. Wait for `.git/autobuild/phase-<N>.done`, using a **background** bash loop (`until [ -f … ]; do sleep 60; done`). Don't poll with tool calls. Every time you're woken (the loop finished, or a timeout), also check that the lead still exists with `list_sessions`.
   - **Done file present:** `close_session` the lead.
     - Contents `next`: N += 1, and go to step 3.
     - Contents `stop: …`: go to step 7.
   - **The lead stalled** (Waiting for prompt/Done, or no new commits on main for 2 h): it most likely hit the 5-hour limit.
     - Run `usage.sh`. If `five ≥ FIVE_PAUSE`, background-sleep until `five_resets + 120`, then `send_input` the lead: "Continue the autobuild phase where you left off."
     - If it's stalled again after that, `close_session` it and start `Autobuild lead <N>` again with the prompt `/autobuild lead <N> (resume: the previous lead N stalled; read HANDOVER, RUN.md and git log, then finish phase N)`.
7. End the run. Report to the user in a few lines what RUN.md's *Summary for the user* says, and point to it. You are the only autobuild session left open. The user closes you; old non-autobuild sessions from before the run are also theirs to close.

---

# Phase lead

## 0. Preflight
1. `git branch --show-current` must be `main`. Otherwise stop: you're not the lead.
2. Read `docs/handover/HANDOVER.md` (latest state) and `docs/autobuild/RUN.md` (run log; create it if missing, with a header and a `Phase | Tasks | Merged | week% start→end | Notes` table).
3. Run `usage.sh`. If `age > 900`, the numbers may be stale: re-check once a worker is running (workers refresh the cache).
4. If a *Stop the run* condition already holds, go there directly.
5. `list_sessions`: note the worker sessions left over from the previous phase. You can't close them, because the previous lead started them. Mention any in the handover so the user can close them.

## 1. Run one phase (one wave)
Follow the lead loop in `specs/90-tasks.md`, with these overrides:

- **OVERRIDE (pick):** don't ask the user before starting the wave. The first phase of a run finishes any `wip(...)` tasks from the handover before picking new ones. Pick up to 4 `ready` tasks. Record the wave in RUN.md, mark the tasks `wip(...)` and commit on main.
- **Close finished workers right away:**
  - as soon as a worker's branch is merged, or the worker is stopped with a committed WIP + REPORT, `close_session` it, then remove its worktree/branch as in the lessons (merged ones only);
  - don't leave a Done worker open until the end of the phase;
  - before signalling the conductor, `list_sessions` and make sure **no session you started is still open**.
- **OVERRIDE (user decisions):** for PROPOSED Interfaces changes, open DW questions that block your wave, and workers claiming "the user approved X":
  - decide with your recommended option yourself;
  - append it to `docs/autobuild/DECISIONS.md` with date, phase, ID, question, options, choice and why;
  - relay it to the worker with `send_input`.
  - **Never** edit the decision log in `SPEC.md`. Still mark accepted Interfaces deltas "accepted (autobuild, see DECISIONS.md)" in the spec, as the T-051 example shows.
  - Don't answer open questions that no task in this wave needs.
- **Permission prompts:** sessions run in auto mode, but a worker may still sit on a permission prompt. You can't approve it (Patchbay leaves that to the user). If a worker has been stuck on one for >20 min:
  - `send_input` it to take another approach, if that's possible (for example a project script instead of an ad-hoc command);
  - otherwise have it commit its WIP and write its REPORT, then close it, mark the task `ready` again with a DW note, and log the blocked command in RUN.md.
- **Budget during the phase:** each time you wake (worker report, wait_for timeout), run `usage.sh`.
  - `week ≥ WEEK_STOP` mid-phase: **finish the current phase anyway** (review, fix rounds, merge). Don't start extra tasks, and remember that this is the last phase.
  - `five ≥ FIVE_PAUSE`: see *5-hour window*.
- **Stuck workers:** a worker that fails review three times, or makes no commits for 90 min of Working, gets stopped:
  - it commits its WIP and writes a REPORT with "Status at stop";
  - copy that REPORT to `docs/handover/T-XXX-REPORT.md`;
  - close the session and leave the task `wip(<branch>)` for the next lead.
- **Main must stay green.** Merge only after the full review in the lessons (trial merge, `scripts/test.sh`, swift test 2–3×). If main turns red and you can't fix it within the phase, `git revert` the merge, log it, and continue.
- Commit as usual: explicit paths, never `git commit -a`.

The phase ends when every task of the wave has been merged, or stopped with a REPORT, main is clean and green, and none of your workers is still open.

## 5-hour window
When `five ≥ FIVE_PAUSE`, act before everything stalls.
1. `send_input` each running worker: "Pause: commit your WIP now, append a 'Status at pause' note to REPORT.md, then wait for my next message without doing anything else."
2. Run a background bash command that sleeps until `five_resets + 120` (compute it from `usage.sh`). Don't poll.
3. When it fires, run `usage.sh` again. If `five < FIVE_PAUSE`, `send_input` each worker: "Resume." Log the pause in RUN.md.

If you get rate-limited anyway, the conductor notices the stall and resumes you after the reset.

## 2. Hand over (end of every phase)
1. Rewrite `docs/handover/HANDOVER.md` in the existing style:
   - header line "You are AUTOBUILD phase lead <N+1>." (or "Autobuild stopped: <reason>" when stopping);
   - state at handoff: main commit, done/ready/wip tasks, kept WIP worktrees and their REPORT copies;
   - new DW items and the decisions taken this phase;
   - sessions only the user can close;
   - lessons: keep the old ones and add new ones;
   - "Your first job".
   Keep it self-contained: the next lead has no memory of you.
2. Append this phase's row to RUN.md, with week% at its start and end.
3. Commit: `Autobuild phase N: handover` (explicit paths).
4. **Merge and push to main. Mandatory, before you signal the conductor** (the user's standing instruction):
   - Every finished, reviewed and green worker branch of this phase is merged straight into `main`. No finished work stays on a side branch for the next lead.
   - All lead commits (status tables, 90-tasks.md, DECISIONS.md, RUN.md, HANDOVER) are on `main`.
   - Then run `git push origin main`, and check that it succeeded: `git status -sb` shows no `ahead`. If the push fails, fix it (fetch, merge `origin/main`, re-run the tests, push again) before going on.
   - Exception: a stopped, unfinished WIP branch is **not** merged, because it would break main. Push it as its own branch (`git push origin <branch>`) so it survives.
   - Workers never push.
5. Run `usage.sh` and look at the *Stop the run* conditions.
6. Write `.git/autobuild/phase-<N>.done`, containing `next` or `stop: <reason>`. This is your last action: don't touch git or files afterwards. End your turn with a one-line summary. The conductor closes your session.

## Stop the run
Stop when any of these is true:
- `week ≥ WEEK_STOP`;
- no `ready` tasks and no `wip` tasks are left;
- two phases in a row merged nothing;
- main is red and the revert didn't fix it.

Before the done file, a stopping lead also adds a final **Summary for the user** section to RUN.md:
- what was merged in this run;
- the decisions to review (point to DECISIONS.md);
- tasks parked and why;
- permission prompts that blocked work, so the user can allowlist them;
- sessions the user should close.
