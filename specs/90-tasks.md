# 90 — Task Breakdown & Orchestration

Each task is sized for **one agent session**. It names the module(s) the agent may edit, the requirement IDs it must satisfy, and its prerequisites. Milestones follow D-24 (engine-first vertical slices), and each one ends with something audible that can be verified through `dawmcp`.

Orchestration runs through **Patchbay** (see *Orchestrating with Patchbay* below): one lead session on `main` starts each task as a worker session in its own git worktree.

**Status values:** `todo` · `ready` (all deps merged to main) · `wip(<branch>)` · `review` · `done` (merged). **Only the lead edits this file** (on `main`), which avoids merge conflicts between worktrees.

## Lanes
Tasks in different lanes can run in parallel once their dependencies are done.

| Lane | Scope | Modules |
|---|---|---|
| **E** Engine | C++ core, time, I/O, graph | `Sources/DAWEngine/{core,time,io,graph,record}` |
| **D** DSP | Built-in processors | `Sources/DAWEngine/{dsp,nodes}` |
| **M** Model | Swift document/commands/persistence | `Sources/DAWModel` |
| **B** Bridge/Control | Facade, protocol, CLI, MCP | `Sources/DAWEngine/facade`, `include/daw`, `Sources/{DAWControl,dawctl,dawmcp}` |
| **U** UI | App | `App/` |
| **P** Plugins | Hosting + scanner | `Sources/DAWEngine/plugins`, `Sources/PluginScanner` |

## Task table

### M1 — Engine skeleton: "play a WAV through a snapshot graph, verified via MCP"
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-001 | E | Repo bootstrap, Package.swift, Xcode app stub, VST3 submodule, scripts | BUILD-001..008 | — | done |
| T-002 | E | Core utilities: `Result`, `DAW_RT`, `SpscQueue`, `AudioBufferPool` | ENG-060, ENG-061, CONV-RT-06 | T-001 | done |
| T-003 | E | RT safety trap (Debug) | ENG-030..033 | T-001 | done |
| T-004 | E | Node API, Engine::render, snapshot publish, epoch reclaim, NodePool, FTZ | ENG-001..004, 010..015, 040..042 | T-002 | ready |
| T-005 | E | ParamSlotTable + ParamSmoother | ENG-020..023 | T-002 | ready |
| T-006 | E | Telemetry snapshot | ENG-050, 051 | T-004 | todo |
| T-007 | M | TempoMap (C++ and Swift) + shared vector fixtures | TIME-001, 002, 011 | T-001 | wip(t-007-tempomap) |
| T-008 | E | Transport, TransportBlock, loop segments, playhead atomic | TIME-003..009 | T-004, T-007 | todo |
| T-009 | E | OfflineDriver + AudioFileWriter | IO-010..013, IO-035 | T-004 | todo |
| T-010 | E | AudioFileLoader, resampling, AudioAsset, peak mipmaps | IO-030..034 (IO-033 deferred to T-056) | T-002 | ready |
| T-011 | E | CoreAudioDriver, workgroup join, latency reporting | IO-001..005 | T-004 | todo |
| T-012 | E | GraphDescription, GraphBuilder (topo sort, buffer liveness, summing, master) | MIX-001..004, MIX-009 | T-004, T-005 | todo |
| T-013 | D | AudioClipPlayer + minimal ChannelStrip (gain/pan) | DSP-001, DSP-010 (partial), MIX-005 (gain/pan) | T-008, T-010, T-012 | todo |
| T-014 | B | EngineFacade v0, EngineClient, EngineProtocol, FakeEngine | BRIDGE-001..008 (transport, graph, params, assets, offline, telemetry, events) | T-006, T-009, T-012 | todo |
| T-015 | M | Project types, IDAllocator, Command protocol, UndoStack, gestures, ProjectStore, CommandRegistry | MODEL-001..004, 006, 007 | T-007 | todo |
| T-016 | M | GraphDescriptionBuilder + engine sync (structural vs param) | MODEL-020..022 | T-014, T-015 | todo |
| T-017 | B | DAWControl protocol + Dispatcher + `dawctl` (headless) | CTL-001..005, CTL-010, 012 | T-016 | todo |
| T-018 | B | `dawmcp` headless + `.mcp.json` + command schema tool | CTL-020..022, 024, 025 | T-017 | todo |
| T-019 | E | Golden harness, test-only nodes, M1 goldens, `scripts/test.sh` | TEST-001..004, BUILD-007 | T-017 | todo |

**M1 exit:** through `dawmcp`, an agent creates a project, imports a 44.1k WAV into a 48k session, adds an audio track and clip, renders offline, and `daw_audio_analyze` shows the expected level and frequency; `rtViolations == 0`; the sine, resample and gain-ramp goldens pass.

### M2 — Mixer & routing
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-020 | E | Full channel strip: mute/solo (solo-in-place), phase, meters; sends pre/post | MIX-005..007, DSP-010 | T-013 | todo |
| T-021 | E | PDC: path latency, delay insertion, delay-line carry-over, source pre-roll | MIX-020..025 | T-012 | todo |
| T-022 | M | Routing commands (tracks, buses, sends, outputs) + cycle rejection + validation | MODEL-005 (routing subset), MODEL-030..032 | T-016 | todo |
| T-023 | E | Sidechain edges and ports | MIX-008 | T-021 | todo |
| T-024 | D | Metronome node | TIME-010, DSP-011 | T-008 | todo |
| T-025 | E | M2 goldens: pan law, bus/send sum, PDC null | TEST (M2 set) | T-020, T-021, T-022 | todo |

### M3 — Timeline, persistence, app shell
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-030 | M | Clip + tempo/signature + loop commands | MODEL-005 (clip/tempo subset) | T-022 | todo |
| T-031 | M | Persistence: folder format, atomic save, migrations, autosave, recovery, offline assets | MODEL-040..046 | T-030 | todo |
| T-032 | U+B | App shell, window, view-model pattern, toasts, ControlSocketServer, attach mode, UI dump/snapshot | UI-001, 003, 004, 050..052, CTL-011, 023, 030, 031 | T-018 | todo |
| T-033 | U | Arrange canvas: tiles, waveforms (Metal), grid/snap, clip gestures, playhead layer | UI-010..014 | T-032, T-030 | todo |
| T-034 | U | Toolbar, transport, keyboard shortcuts | UI-002 | T-032 | todo |
| T-035 | D | Overlapping-clip crossfades | DSP-002 | T-013 | todo |
| T-036 | E | M3 goldens: clips/fades/tempo change, loop wrap mid-block | TEST (M3 set) | T-030, T-035 | todo |

### M4 — MIDI & Sampler
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-040 | D | MidiClipPlayer, hanging-note handling | DSP-003 | T-008, T-012 | todo |
| T-041 | D | Sampler (zones, Hermite, voices, ADSR, CC64, bend) | DSP-020..023 | T-040, T-010 | todo |
| T-042 | M | Note commands, instrument slot on MIDI tracks | MODEL-005 (note subset) | T-030 | todo |
| T-043 | U | Piano roll + velocity lane + audition (`previewNote` facade addition) | UI-020, 021 | T-033, T-042 | todo |
| T-044 | D | M4 goldens | TEST (M4 set) | T-041, T-042 | todo |

### M5 — Recording & devices
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-050 | E | FakeDeviceDriver (loopback, scripted events) | TEST-005 | T-011 | todo |
| T-051 | E | DeviceMonitor, hot-swap sequence, xrun detection, EngineEvents | IO-020..023 | T-050 | todo |
| T-052 | E | Audio recording: FIFOs, disk writer, latency comp, finalize, punch | REC-001..005 | T-050, T-009 | todo |
| T-053 | E | CoreMIDI input + MIDI recording | REC-010..012 | T-040 | todo |
| T-054 | E | Input monitoring modes | REC-020..022 | T-052 | todo |
| T-055 | U | Audio preferences, device toasts, arm/monitor buttons | UI-040, UI-004 | T-051, T-034 | todo |
| T-056 | E+M | Session sample-rate change (re-convert assets, re-prepare) | IO-033, MODEL-005 (`SetSessionSampleRate`) | T-051 | todo |

### M6 — Plugins
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-060 | P | PluginScanner + cache + blocklist | PLUG-001..004 | T-001 | done |
| T-061 | P | AU hosting node (FX + instrument), params, state, latency | PLUG-010, 012..016 (AU) | T-021, T-014 | todo |
| T-062 | P | VST3 hosting node + build SDK `again` test plugin | PLUG-011..016 (VST3) | T-021, T-014 | todo |
| T-063 | P+U | Plugin editor windows (AU view controller, VST3 IPlugView) | PLUG-017 | T-061, T-062, T-032 | todo |
| T-064 | P | Host bypass, NaN guard, crash marker + safe-mode open | PLUG-018, 020..022 | T-061 | todo |
| T-065 | U | Device chain view (generic UI from ParamInfo), plugin manager | UI-032, UI-041 | T-063 | todo |

### M7 — Effects & automation
DSP effects (T-070..073) depend only on the Node API and can be **pulled forward** into any idle D-lane slot after T-005.

| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-070 | D | EQ | DSP-030, 040, 041 | T-005 | todo |
| T-071 | D | Compressor (+ sidechain) | DSP-031, 040, 041 | T-005, T-023 | todo |
| T-072 | D | Delay (tempo sync) | DSP-032, 040, 041 | T-008 | todo |
| T-073 | D | Reverb (FDN, deterministic) | DSP-033, 040, 041 | T-005 | todo |
| T-074 | E+M | Automation lanes model + AutomationPlayer + plugin param path | AUTO-001..005, 008..010 | T-030, T-061/T-062 (for AUTO-009) | todo |
| T-075 | U+M | Automation recording (touch/latch/write) + lane UI | AUTO-006, 007, UI-015 | T-074, T-033 | todo |
| T-076 | U | Mixer view + meters + routing pickers | UI-030, 031, 033 | T-022, T-032 | todo |
| T-077 | D | M7 goldens | TEST (M7 set) | T-071, T-073, T-074 | todo |

### M8 — Comping, export, hardening
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-080 | E+M | Loop recording takes, TakeFolder, comp model, flattening | REC-030..034 | T-052, T-035 | todo |
| T-081 | U | Take folder / comp editing UI | UI-016 | T-080, T-033 | todo |
| T-082 | U | Export dialog | UI-042 | T-009, T-032 | todo |
| T-083 | U | Crash recovery dialog | UI-043 | T-031, T-064 | todo |
| T-084 | E | Sanitizer CI jobs, perf smoke, GitHub Actions | TEST-007, 008, BUILD-009 | T-077 | todo |

## Critical path
`T-001 → T-002 → T-004 → T-012 → T-014 → T-016 → T-017 → T-018` unlocks agent self-testing. Prioritize it; everything else fans out from there.

## Suggested parallel waves (max ~4 Patchbay workers)
| Wave | Agents |
|---|---|
| 1 | T-001 (solo) |
| 2 | T-002 · T-003 · T-007 |
| 3 | T-004 · T-005 · T-010 · T-015 |
| 4 | T-006 · T-008 · T-009 · T-012 |
| 5 | T-011 · T-013 · T-014 · T-060 |
| 6 | T-016 · T-070 · T-073 |
| 7 | T-017 → T-018 → T-019 (B lane), plus D/M lanes pick from M2 |
| … | Pick any `ready` task, preferring the critical path, then the earliest milestone |

## Orchestrating with Patchbay

Patchbay is the default orchestrator. Its MCP tools (`list_sessions`, `new_session`, `wait_for`, `read_output`, `send_input`, `close_session`) are available only to Claude sessions **running inside Patchbay**. Start the lead there, in `/Users/artem/dev/macDAW` on `main`. Don't use the Agent/subagent tool for task work: Patchbay sessions show up in the user's sidebar and keep separate worktrees.

### Roles
| Role | Where | Does |
|---|---|---|
| **Lead** | Main checkout `/Users/artem/dev/macDAW`, branch `main` | Picks `ready` tasks, starts workers, reviews, merges, updates Status tables + this file, records discovered work |
| **Worker** | `~/.patchbay/worktrees/macDAW/t-xxx-<slug>`, branch `t-xxx-<slug>` | Implements one task, commits on its branch, ends with a report. Never merges or edits `90-tasks.md` |

### Loop (lead)
1. **Pick** up to ~4 `ready` tasks in different lanes. Critical path first, then the earliest milestone. Mark them `wip(<branch>)` and commit on `main`. Workers branch from `main`, so every dependency must be **merged** before a dependent starts.
2. **Start** each worker:
   ```
   new_session(folder: "/Users/artem/dev/macDAW", agent: "claude",
               name: "T-012 GraphBuilder", branch: "t-012-graphbuilder", base: "main",
               prompt: <briefing below>)
   ```
   `.patchbay.json` runs the worktree setup (submodules + bootstrap) before the agent starts.
3. **Follow:** `wait_for(session, timeout: 1800)` in turn for each worker; `read_output` when one stops. If it asks a question, answer with `send_input`. **Permission prompts are the user's to answer**, so never try to bypass them.
4. **Review** a finished worker:
   - `git diff main...t-012-graphbuilder` stays within the task's modules.
   - Run `scripts/test.sh` in the worktree; it must pass.
   - The report claims every requirement ID with a test.
   - `rtViolations == 0`.
   - Interface changes marked `PROPOSED` → stop and ask the user before merging.
   - If anything is missing, `send_input` the gaps to the worker and go back to step 3.
5. **Merge** on `main`: `git merge --no-ff t-012-graphbuilder`, run `scripts/test.sh` on `main`, then update the spec Status tables and this file (`done`, newly `ready` tasks, *Discovered work* from the report). Commit `T-012: merge (MIX-001..004)`.
6. **Close** the worker with `close_session` (Patchbay keeps the worktree). Remove it later with `git worktree remove` once merged. Then return to step 1.

Conflicts: lanes own separate folders, so merges should be clean. If two branches conflict, merge the earlier task first, then `send_input` the later worker to `git merge main` and resolve.

### Worker briefing (prompt for `new_session`)
```
You are a worker on macDAW task T-XXX (<title>), in your own git worktree on branch t-xxx-<slug>.
Read: CLAUDE.md, SPEC.md, specs/00-conventions.md, specs/<owning spec>.md, and the "Interfaces" sections of: <dep specs>.
Requirements to satisfy: <IDs>. You may edit only: <modules>.
Do not edit specs/90-tasks.md or any spec Status table — the lead does that on merge.
If an "Interfaces" section must change, mark it PROPOSED in the spec, explain why, and stop.
Commit on your branch as you go (messages start with "T-XXX:"). Do not merge, rebase onto, or push main.
Done = specs/00-conventions.md §5. Verify with scripts/test.sh and the dawmcp server (once it exists).
Finish with a report in this exact shape:
  ## T-XXX report
  - Requirements: <ID → test name, …>
  - Tests: <command + pass/fail summary>
  - RT violations: <n>
  - Interface proposals: <none | spec §, summary>
  - Discovered work: <none | bullets with proposed lane>
  - Notes for reviewer: <…>
```

## Discovered work
Recorded by the lead from worker reports.

| ID | Found by | Description | Proposed lane | Status |
|---|---|---|---|---|
| DW-001 | T-001 | Golden stage in `test.sh` only counts fixtures; harness must expose `fixtures/`+`references/` as GoldenTests resources and run real comparisons | E (T-019) | todo |
| DW-002 | T-001 | `test.sh` engine-objects check relies on `daw_build_rt_trap_enabled` in `Sources/DAWEngine/BuildConfig.cpp` (defined only under `DAW_RT_TRAP`) to prove BUILD-005 — keep the symbol or update the check | E (T-003) | todo |
| DW-003 | T-001 | `include/module.modulemap` exposes only placeholder `daw/EngineFacade.h`; bridge task must keep the module map pointing at it | B (T-014) | todo |
| DW-004 | T-001 | `.patchbay.json` setup runs `git submodule update --init --recursive`, pulling VSTGUI/docs/tutorials the build excludes; `scripts/bootstrap.sh` alone fetches only what's needed | lead | todo |
| DW-005 | T-001 | "No warnings" check only sees recompiled files; CI should do clean builds | E (T-084) | todo |
| DW-006 | T-002 | C++ test-support target (Package.swift target + test-only module map) to replace the extern "C" self-test pattern in `core/CoreUtilsSelfTests.cpp`, which currently ships inside libDAWEngine.a | E (T-019 or earlier) | todo |
| DW-007 | T-002 | Add `.headerSearchPath(".")` to DAWEngine so `#include "core/X.h"` works from any subfolder | E (lead) | todo |
| DW-008 | T-002 | CONV-RT-06 wording: `DAW_RT` must expand to `noexcept [[clang::nonblocking]]` (clang warns on non-noexcept nonblocking, -Werror fails) — spec text needs updating | spec (user/lead) | todo |
| DW-009 | T-002 | Run SpscQueue/AudioBufferPool RT paths inside the RT trap scope and assert rtViolations == 0 | E (after T-003) | todo |
| DW-010 | T-002 | Generate compile_commands.json so editor diagnostics use the package's C++20 flags | lead (low) | todo |
| DW-011 | T-003 | Wire the trap: `RtTrap::install()` at Engine construction + `daw::RtScope` in `Engine::render` (T-004); `Telemetry::rtViolations` from `RtTrap::violationCount()` and expose `RtTrap::firstViolation()` via telemetry/dawmcp (T-006) | E (T-004, T-006) | todo |
| DW-012 | T-003 | ENG-031 says "interpose"; dyld `__interpose` doesn't apply to the test executable or dlopen'd bundles, so the trap uses `malloc_logger` + GOT rebinding. Gaps: locks inside system libraries and `dispatch_*` aren't counted; allocations invisible under ASan (matters for TEST-007). Spec wording needs a clarification note | spec (user/lead) | todo |
| DW-013 | T-003 | Optional: `test.sh` engine-objects stage could also assert `_daw_rt_trap_install` is absent from Release | E (T-019) | todo |
| DW-014 | T-003 | Unify C++ test binding styles (T-002 `@_silgen_name` via SelfTest.h vs T-003 `dlsym`); fold into DW-006 test-support target | E (with DW-006) | todo |
| DW-015 | T-060 | App can't use the scanner yet: embed `PluginScanner` in macDAW.app as an auxiliary executable, and expose `PluginCatalog` to the app — via a new library product (changes 01-build-layout Interfaces product list → needs approval) or through DAWModel | U + lead (with T-065) | todo |
| DW-016 | T-060 | dawctl/dawmcp commands: scan, list plugins, list/reset blocked | B (after T-017) | todo |
| DW-017 | T-060 | Convert Swift `PluginDescriptor` → `PluginDescriptorPOD` for `instantiatePlugin` | P/B (T-014/T-061) | todo |
| DW-018 | T-060 | Optional: scan candidates in parallel (each hanging plugin costs up to 10 s serially) | P (later) | todo |
