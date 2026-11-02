# Autobuild run log

Unattended phases started by `/autobuild` (see `.claude/skills/autobuild/SKILL.md`). Decisions taken without the user are in `DECISIONS.md`.

| Phase | Tasks | Merged | week% start→end | Notes |
|---|---|---|---|---|
| 1 | T-032, T-025, T-042, T-035 | all 4 (T-035, T-025, T-042, T-032) | 0 → 10 | Resumed T-025/T-032 on `-r2` branches; one 5-hour pause (~27 min); DW-148 autosave race fixed; T-045 added |

## Phase notes

### Phase 1 (2026-11-02)
- Wave: T-032 app shell (U+B, resume of `t-032-app-shell`), T-025 M2 goldens (E, resume of `t-025-m2-goldens`), T-042 note commands + instrument slot (M, new), T-035 crossfades (D, new).
- Start: week 0%, five-hour window 26%.
- `git worktree remove` on the merged `t-031-persistence` worktree needs `--force` (it contains submodules), and auto mode denied that. The worktree is left for the user to remove.
- Patchbay can't start a session on a branch whose worktree still exists, and removing those worktrees needs `--force` (submodules), which auto mode denied. So T-025 and T-032 resume on new branches `t-025-m2-goldens-r2` and `t-032-app-shell-r2`, based on the old WIP branches. The old worktrees `t-025-m2-goldens`, `t-031-persistence` and `t-032-app-shell` are left for the user to remove.
- T-035 merged (b5ce53e), then T-025 (898e1b0). The MODEL-044 autosave test flaked 3× under load (DW-148); T-042's worker took it as a follow-up.
- 5-hour window hit 85% at ~1793655150 (epoch). T-032 and T-042 were paused until the reset at 1793656800 + 120 s.
- Resumed both workers at 1793656923 (five-hour window back to 0%).
- T-042 merged (2641e0e), including the DW-148 autosave race fix. Added T-045 (MIDI routing, DW-099) as a ready E-lane task.
- T-032 merged (1bb0c7d). Phase over: 4/4 merged, main green (test.sh 11/11, swift test 2× green), no worker session left open.
