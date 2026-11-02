# Autobuild run log

Unattended phases started by `/autobuild` (see `.claude/skills/autobuild/SKILL.md`). Decisions taken without the user are in `DECISIONS.md`.

| Phase | Tasks | Merged | week% start→end | Notes |
|---|---|---|---|---|

## Phase notes

### Phase 1 (2026-11-02)
- Wave: T-032 app shell (U+B, resume of `t-032-app-shell`), T-025 M2 goldens (E, resume of `t-025-m2-goldens`), T-042 note commands + instrument slot (M, new), T-035 crossfades (D, new).
- Start: week 0%, five-hour window 26%.
- `git worktree remove` on the merged `t-031-persistence` worktree needs `--force` (it contains submodules), and auto mode denied that. The worktree is left for the user to remove.
- Patchbay can't start a session on a branch whose worktree still exists, and removing those worktrees needs `--force` (submodules), which auto mode denied. So T-025 and T-032 resume on new branches `t-025-m2-goldens-r2` and `t-032-app-shell-r2`, based on the old WIP branches. The old worktrees `t-025-m2-goldens`, `t-031-persistence` and `t-032-app-shell` are left for the user to remove.
