# macDAW — Agent Instructions

This repo is **spec-driven**. The spec is the source of truth; code implements it.

## Orchestration: Patchbay
Multi-agent work runs through **Patchbay** (the terminal app this session may be running in). Its MCP tools are `new_session`, `wait_for`, `read_output`, `send_input`, `close_session` and `list_sessions`. Don't use the Agent/subagent tool for task work.
- **Lead:** runs in the main checkout on `main`. Follow *Orchestrating with Patchbay* in `specs/90-tasks.md`.
- **Worker:** runs in a Patchbay worktree on branch `t-xxx-<slug>`. Follow the briefing you were given and the rules below.

To check your role, run `git branch --show-current`: `main` means lead, `t-…` means worker.

## Before you start (worker)
1. Read `SPEC.md` (index + decision log) and `specs/00-conventions.md`.
2. Read your task's owning spec in full and the **Interfaces** sections of the specs it depends on.

## While working
- Edit only the modules your task lists (`00-conventions §7`). Put out-of-scope findings under *Discovered work* in your final report.
- Workers don't edit `specs/90-tasks.md` or spec Status tables; the lead updates them when merging.
- Cite requirement IDs in tests and comments where behavior is spec-driven (`// MIX-021`).
- Real-time code obeys `00-conventions §2`. Debug builds trap allocations and locks on the audio thread.
- **Interfaces are contracts.** If one must change, mark it `PROPOSED` in the spec, list the affected tasks, and stop (`00-conventions §6`).
- Don't change the decision log in `SPEC.md`; only the user does that.
- Commit on your own branch; never merge into, rebase or push `main`.

## Verifying your work
- `scripts/test.sh` is the single test entry point.
- Use the `dawmcp` MCP server (registered in `.mcp.json`, built from your own worktree) to drive the DAW yourself: build a scenario with commands, render offline, analyze or compare audio, and check telemetry (`rtViolations` must be 0). For UI work, use attach mode with `daw_ui_state`, `daw_ui_perform` and `daw_ui_snapshot`. See `specs/14-testing.md` → *Agent verification recipe*.
- Never regenerate golden references just to make a test pass without explaining why in the commit.

## Finishing
- Meet `00-conventions §5` (Definition of Done).
- Commit messages start with the task ID: `T-012: GraphBuilder topo sort + buffer liveness (MIX-001..004)`.
- End with the `## T-XXX report` block from the worker briefing in `specs/90-tasks.md`.
