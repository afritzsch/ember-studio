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
| T-004 | E | Node API, Engine::render, snapshot publish, epoch reclaim, NodePool, FTZ | ENG-001..004, 010..015, 040..042 | T-002 | done |
| T-005 | E | ParamSlotTable + ParamSmoother | ENG-020..023 | T-002 | done |
| T-006 | E | Telemetry snapshot | ENG-050, 051 | T-004 | done |
| T-007 | M | TempoMap (C++ and Swift) + shared vector fixtures | TIME-001, 002, 011 | T-001 | done |
| T-008 | E | Transport, TransportBlock, loop segments, playhead atomic | TIME-003..009 | T-004, T-007 | done |
| T-009 | E | OfflineDriver + AudioFileWriter | IO-010..013, IO-035 | T-004 | done |
| T-010 | E | AudioFileLoader, resampling, AudioAsset, peak mipmaps | IO-030..034 (IO-033 deferred to T-056) | T-002 | done |
| T-011 | E | CoreAudioDriver, workgroup join, latency reporting | IO-001..005 | T-004 | done |
| T-012 | E | GraphDescription, GraphBuilder (topo sort, buffer liveness, summing, master) | MIX-001..004, MIX-009 | T-004, T-005 | done |
| T-013 | D | AudioClipPlayer + minimal ChannelStrip (gain/pan) | DSP-001, DSP-010 (partial), MIX-005 (gain/pan) | T-008, T-010, T-012 | done |
| T-014 | B | EngineFacade v0, EngineClient, EngineProtocol, FakeEngine | BRIDGE-001..008 (transport, graph, params, assets, offline, telemetry, events) | T-006, T-009, T-012 | done |
| T-015 | M | Project types, IDAllocator, Command protocol, UndoStack, gestures, ProjectStore, CommandRegistry | MODEL-001..004, 006, 007 | T-007 | done |
| T-016 | M | GraphDescriptionBuilder + engine sync (structural vs param); solo-in-place truth table | MODEL-020..022, MIX-006 | T-014, T-015 | done |
| T-017 | B | DAWControl protocol + Dispatcher + `dawctl` (headless) | CTL-001..005, CTL-010, 012 | T-016 | done |
| T-018 | B | `dawmcp` headless + `.mcp.json` + command schema tool | CTL-020..022, 024, 025 | T-017 | done |
| T-019 | E | Golden harness, test-only nodes, M1 goldens, `scripts/test.sh` | TEST-001..004, BUILD-007 | T-017 | done |
| T-085 | E | Engine test-support cleanup: one C++ test pattern (test-only module map), no test code in libDAWEngine, `core/`-rooted includes, isolated RT-trap counters | DW-006, 007, 014, 019 | T-003, T-007 | done |
| T-086 | E | Rename the app to **Ember Studio**: Xcode project/target/scheme/folder `EmberStudio`, bundle ID `dev.emberstudio.EmberStudio`, log subsystem `dev.emberstudio`, all text mentions (specs, CLAUDE.md, SPEC.md text outside the decision log, scripts). Module names unchanged | — | T-004, T-010 (avoid conflicts) | done |
| T-087 | E | Engine cleanup: RtTrap `LockHook::real` data race + TSan run (DW-028); leftover "macDAW" mentions (DW-045); `ErrorCode::cycle` with NodeIDs in `core/Result.h`, used by GraphBuilder (DW-050); `resetOnLocate` comment says locate only (DW-062) | DW-028, 045, 050, 062 | T-085, T-086 | done |

**M1 exit:** through `dawmcp`, an agent creates a project, imports a 44.1k WAV into a 48k session, adds an audio track and clip, renders offline, and `daw_audio_analyze` shows the expected level and frequency; `rtViolations == 0`; the sine, resample and gain-ramp goldens pass.

**M1 exit met (2026-10-28, main @ e556bde):** a 44.1 kHz WAV imported into a 48 kHz session via `asset.import` + `AddTrack` + `AddClip` renders 24000 frames, peak −12.04 dBFS, spectrum peak 1000.18 Hz, `rtViolations` 0 (dawctl, same Dispatcher as dawmcp; through the dawmcp binary in T-018's `DawToolsTests`); goldens `sine_through_graph`, `wav_playback_resampled`, `gain_ramp_smoothing` pass in `scripts/test.sh`.

### M2 — Mixer & routing
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-020 | E | Full channel strip: mute (slot; solo resolved by the model, T-016), phase, meters; sends pre/post | MIX-005, MIX-007, DSP-010 | T-013 | done |
| T-021 | E | PDC: path latency, delay insertion, delay-line carry-over, source pre-roll | MIX-020..025 | T-012 | done |
| T-022 | M | Routing commands (tracks, buses, sends, outputs) + cycle rejection + validation | MODEL-005 (routing subset), MODEL-030..032 | T-016 | done |
| T-023 | E | Sidechain edges and ports | MIX-008 | T-021 | done |
| T-024 | D | Metronome node | TIME-010, DSP-011 | T-008 | done |
| T-025 | E | M2 goldens: pan law, bus/send sum, PDC null | TEST (M2 set) | T-020, T-021, T-022, T-019 (harness) | done |
| T-026 | M+B | Project metronome: `Project.metronome {enabled, level, accent}` (persisted), `SetMetronome` command, GraphDescriptionBuilder emits one metronome node straight into the master (not soloed/muted with tracks; toggles are slot writes), `transport.setMetronome` + dawmcp tool, facade `paramInfoJSON` publishes `Metronome::kParamInfo` (and `GainNode`). Open for the user (T-024 Qs): export includes the click? (recommended: no, unless `includeMetronome: true`); toggle undoable? (recommended: a command that doesn't enter undo history). Toolbar button: T-034 | TIME-010 (project part), DW-160 | T-024 | done |

### M3 — Timeline, persistence, app shell
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-030 | M | Clip + tempo/signature + loop commands | MODEL-005 (clip/tempo subset) | T-022 | done |
| T-031 | M | Persistence: folder format, atomic save, migrations, autosave, recovery, offline assets | MODEL-040..046 | T-030 | done |
| T-032 | U+B | App shell, window, view-model pattern, toasts, ControlSocketServer, attach mode, UI dump/snapshot | UI-001, 003, 004, 050..052, CTL-011, 023, 030, 031 | T-018 | done |
| T-033 | U | Arrange canvas: tiles, waveforms (Metal), grid/snap, clip gestures, playhead layer | UI-010..014 | T-032, T-030 | done |
| T-034 | U | Toolbar, transport, keyboard shortcuts | UI-002 | T-032 | done |
| T-035 | D | Overlapping-clip crossfades | DSP-002 | T-013 | done |
| T-036 | E | M3 goldens: clips/fades/tempo change, loop wrap mid-block | TEST (M3 set) | T-030, T-035 | done |

### M4 — MIDI & Sampler
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-040 | D | MidiClipPlayer, hanging-note handling | DSP-003 | T-008, T-012 | done |
| T-041 | D | Sampler (zones, Hermite, voices, ADSR, CC64, bend) | DSP-020..023 | T-040, T-010 | done |
| T-042 | M | Note commands, instrument slot on MIDI tracks | MODEL-005 (note subset) | T-030 | done |
| T-043 | U | Piano roll + velocity lane + audition (`previewNote` facade addition) | UI-020, 021 | T-033, T-042 | done |
| T-044 | D | M4 goldens | TEST (M4 set) | T-041, T-042, T-045 | done |
| T-045 | E | MIDI edge routing in RenderGraph/GraphBuilder: player → instrument MIDI data, frame-ordered merge, fixed-capacity storage, MIDI delay for PDC; makes a MIDI track with a sampler audible | DW-099 (DSP-003, MIX-001, MIX-021 for MIDI) | T-040, T-041 | done |

### M5 — Recording & devices
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-050 | E | FakeDeviceDriver (loopback, scripted events) | TEST-005 | T-011 | done |
| T-051 | E | DeviceMonitor, hot-swap sequence, xrun detection, EngineEvents | IO-020..023 | T-050 | done |
| T-052 | E | Audio recording: FIFOs, disk writer, latency comp, finalize, punch | REC-001..005 | T-050, T-009 | todo |
| T-053 | E | CoreMIDI input + MIDI recording | REC-010..012 | T-040 | todo |
| T-054 | E | Input monitoring modes | REC-020..022 | T-052 | todo |
| T-055 | U | Audio preferences, device toasts, arm/monitor buttons | UI-040, UI-004 | T-051, T-034 | ready |
| T-056 | E+M | Session sample-rate change (re-convert assets, re-prepare) | IO-033, MODEL-005 (`SetSessionSampleRate`) | T-051 | done |

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
| T-070 | D | EQ | DSP-030, 040, 041 | T-004, T-005 | ready |
| T-071 | D | Compressor (+ sidechain) | DSP-031, 040, 041 | T-005, T-023 | done |
| T-072 | D | Delay (tempo sync) | DSP-032, 040, 041 | T-008 | ready |
| T-073 | D | Reverb (FDN, deterministic) | DSP-033, 040, 041 | T-004, T-005 | done |
| T-074 | E+M | Automation lanes model + AutomationPlayer + plugin param path | AUTO-001..005, 008..010 | T-030, T-061/T-062 (for AUTO-009) | todo |
| T-075 | U+M | Automation recording (touch/latch/write) + lane UI | AUTO-006, 007, UI-015 | T-074, T-033 | todo |
| T-076 | U | Mixer view + meters + routing pickers | UI-030, 031, 033 | T-022, T-032 | ready |
| T-077 | D | M7 goldens | TEST (M7 set) | T-071, T-073, T-074 | todo |

### M8 — Comping, export, hardening
| Task | Lane | Title | Requirements | Depends on | Status |
|---|---|---|---|---|---|
| T-080 | E+M | Loop recording takes, TakeFolder, comp model, flattening | REC-030..034 | T-052, T-035 | todo |
| T-081 | U | Take folder / comp editing UI | UI-016 | T-080, T-033 | todo |
| T-082 | U | Export dialog | UI-042 | T-009, T-032 | ready |
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
You are a worker on Ember Studio task T-XXX (<title>), in your own git worktree on branch t-xxx-<slug>.
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
| DW-001 | T-001 | Golden stage in `test.sh` only counts fixtures; harness must expose `fixtures/`+`references/` as GoldenTests resources and run real comparisons | E (T-019) | done (T-019) |
| DW-002 | T-001 | `test.sh` engine-objects check relies on `daw_build_rt_trap_enabled` in `Sources/DAWEngine/BuildConfig.cpp` (defined only under `DAW_RT_TRAP`) to prove BUILD-005 — keep the symbol or update the check | E (T-003) | todo |
| DW-003 | T-001 | `include/module.modulemap` exposes only placeholder `daw/EngineFacade.h`; bridge task must keep the module map pointing at it | B (T-014) | done (T-014) |
| DW-004 | T-001 | `.patchbay.json` setup runs `git submodule update --init --recursive`, pulling VSTGUI/docs/tutorials the build excludes; `scripts/bootstrap.sh` alone fetches only what's needed | lead | todo |
| DW-005 | T-001 | "No warnings" check only sees recompiled files; CI should do clean builds | E (T-084) | todo |
| DW-006 | T-002 | C++ test-support target (Package.swift target + test-only module map) to replace the extern "C" self-test pattern in `core/CoreUtilsSelfTests.cpp`, which currently ships inside libDAWEngine.a | E (T-019 or earlier) | done (T-085) |
| DW-007 | T-002, T-007 | Add `.headerSearchPath(".")` to DAWEngine so `#include "core/X.h"` / `"time/TempoMap.h"` work from any subfolder | E (lead) | done (T-085) |
| DW-008 | T-002 | CONV-RT-06 wording: `DAW_RT` must expand to `noexcept [[clang::nonblocking]]` (clang warns on non-noexcept nonblocking, -Werror fails) — spec text needs updating | spec (user/lead) | todo |
| DW-009 | T-002 | Run SpscQueue/AudioBufferPool RT paths inside the RT trap scope and assert rtViolations == 0. Cheap since T-085: run `rtRoundTrip` (`Tests/DAWEngineTestSupport/CoreUtilsChecks.cpp`) inside an `RtScope` and return `scope.violations()` | E (after T-003) | todo |
| DW-010 | T-002 | Generate compile_commands.json so editor diagnostics use the package's C++20 flags; also cover `DAWEngineTestSupport` (needs `-I Sources/DAWEngine`) | lead (low) | todo |
| DW-011 | T-003 | Wire the trap: `RtTrap::install()` at Engine construction + `daw::RtScope` in `Engine::render` (T-004); `Telemetry::rtViolations` from `RtTrap::violationCount()` and expose `RtTrap::firstViolation()` via telemetry/dawmcp (T-006) | E (T-004, T-006) | done (T-004, T-006) |
| DW-012 | T-003 | ENG-031 says "interpose"; dyld `__interpose` doesn't apply to the test executable or dlopen'd bundles, so the trap uses `malloc_logger` + GOT rebinding. Gaps: locks inside system libraries and `dispatch_*` aren't counted; allocations invisible under ASan (matters for TEST-007). Spec wording needs a clarification note | spec (user/lead) | todo |
| DW-013 | T-003 | Optional: `test.sh` engine-objects stage could also assert the trap is absent from Release. `_daw_rt_trap_install` no longer exists (T-085), so retarget to `RtTrap::install`'s mangled name or close | E (T-019) | done (T-019: `RtTrap::install` present in Debug, absent in Release) |
| DW-014 | T-003 | Unify C++ test binding styles (T-002 `@_silgen_name` via SelfTest.h vs T-003 `dlsym`); fold into DW-006 test-support target | E (with DW-006) | done (T-085) |
| DW-015 | T-060 | App can't use the scanner yet: embed `PluginScanner` in macDAW.app as an auxiliary executable, and expose `PluginCatalog` to the app — via a new library product (changes 01-build-layout Interfaces product list → needs approval) or through DAWModel | U + lead (with T-065) | todo |
| DW-016 | T-060 | dawctl/dawmcp commands: scan, list plugins, list/reset blocked | B (after T-017) | todo |
| DW-017 | T-060 | Convert Swift `PluginDescriptor` → `PluginDescriptorPOD` for `instantiatePlugin` | P/B (T-014/T-061) | done (T-014) |
| DW-018 | T-060 | Optional: scan candidates in parallel (each hanging plugin costs up to 10 s serially) | P (later) | todo |
| DW-019 | T-007 | RT-trap violation counters are process-wide; RtTrapTests violate on purpose while other suites run in parallel, so "0 violations" checks can be polluted (T-007 measured deltas + retried 3×). Needs per-scope counters or serialized RT tests | E (T-003 follow-up / T-006) | done (T-085) |
| DW-020 | T-007 | `TempoMap.sampleRate` duplicates `Project.sessionSampleRate` — choose one source of truth; `SetSessionSampleRate` must rebuild the map | M (T-015) | done (T-015) |
| DW-021 | T-007 | Map Swift `TempoMapError` into `DAWError` once it exists | M (T-015) | done (T-015) |
| DW-022 | T-007 | Swift interop can't call `daw::Result::value()` (ref-qualified overloads); T-007 used an inline helper — facade will hit the same | B (T-014) | done (T-014) |
| DW-023 | T-085 | `test.sh` BUILD-002 check treats every target reaching DAWEngine as Swift; `DAWEngineTestSupport` carries a no-op `swiftSettings: cxxInterop` to pass. The check should skip C-family targets | E (T-084 / T-019) | done (T-019: BUILD-002 check skips C-family targets; the no-op cxxInterop on DAWEngineTestSupport can go → DW-136) |
| DW-024 | T-085 | Telemetry `rtViolations` is process-wide, so in-process engine tests asserting on it (e.g. TEST-004 AllocatingNode) see RtTrapTests' deliberate violations. Nest such tests in `RtTrapTests`, or have the Engine count from its render `RtScope::violations()` — possibly an ENG-032 clarification | E (T-004 / T-006) + spec | done (T-006) |
| DW-025 | lead | `scripts/bootstrap.sh` can exit 141 under `pipefail`: `xcodebuild -version \| awk '… exit'` (and `\| head -n 1`) close the pipe early, so the producer gets SIGPIPE. It made T-015's worktree setup fail once, and the `bootstrap` stage of `test.sh` fail once in T-004's review | E (T-084) / lead | done (T-086) |
| DW-026 | T-005 | Golden `gain_ramp_smoothing` for ENG-022 | E (T-019) | done (T-019) |
| DW-027 | T-005 | ENG-023 "fader sweep → 0 publishes" test needs Engine + GraphBuilder | E/B (T-012 / T-014) | done (T-014) |
| DW-028 | T-005 | RtTrap data race: `LockHook::real` (RtTrap.cpp ~146-154) is a plain static written by `install()` while hooked locks read it on other threads; TSan flags it and one TSan run hung (malloc_logger/GOT rebinding vs TSan interceptors, unconfirmed). Make it atomic or set once (`std::call_once`). Blocks TEST-007's TSan job | E (T-003 follow-up) | done (T-087; TSan run: no hang, 0 races; see DW-065) |
| DW-029 | T-005 | Free a node's ParamIDs only after the last graph referencing them is retired (a freed slot is reused at once, so an old graph could read another param for a block) | B / M (T-014, MODEL-022) | done (T-014) |
| DW-030 | T-005 | `ParamSlot.generation` (counts writes, for PLUG-015) isn't in 02; record its meaning in the spec. Out-of-range ParamIDs are only `DAW_RT_ASSERT`ed (compiled out in Release), so GraphBuilder must validate IDs | spec (lead) + E (T-012) | done (T-012) |
| DW-031 | T-015 | MODEL-032: run `Project.validate()` after every command in Debug (hook in `UndoStack.perform`); decoding should also move the ID allocator past the largest ID in the file | M (T-022 / T-031) | done (T-022; Debug hook throws, project unchanged; validate on open → DW-111) |
| DW-032 | T-015 | Change detection diffs the whole project after every command and gesture step; may need tuning for large projects / fast drags | M (T-016) | done (T-016: measured; diff ~6.8 ms/step on 144 tracks, 12.8k clips, release; optional speed-up in DW-098) |
| DW-033 | T-015 | `Project.init` uses a random UUID; headless `project.new` should pass a fixed id so runs are deterministic | B (T-017, CTL-004) | done (T-017: headless project.new n → UUID 00000000-0000-0000-0000-<n hex>) |
| DW-034 | T-004 | ENG-011/012 wording: as built, `renderEpoch` is odd while a block runs and even when idle (so graphs replaced while idle free at once), with seq_cst on both sides rather than "acquire". Record in the spec | spec (lead) | todo |
| DW-035 | T-004 | 00-conventions §3 gives no QoS for `daw.reclaim`; T-004 used `QOS_CLASS_UTILITY`. Record in the spec | spec (lead) | todo |
| DW-036 | T-004 | GraphBuilder: a `NodeDesc.configVersion` bump must `NodePool::put` a new prepared instance (a node a live graph may render can't be re-prepared in place). RenderGraph doesn't route MIDI yet (`midiIn` empty, `midiOut` capacity 0) | E (T-012), D (T-040) | done (T-012) |
| DW-037 | T-004 | Telemetry: fill the seam in `Engine::render`; count oversize blocks (rendered as silence) and RetireQueue-full; DW-024 can use the render `RtScope` count | E (T-006) | done (T-006) |
| DW-038 | T-004 | `time/TransportBlock.h` was created by T-004 verbatim from 03 Interfaces; T-008 owns it and fills the "advance transport" seam | E (T-008) | done (T-008) |
| DW-039 | T-004 | LSan isn't supported on macOS; TEST-007 leak checks need `leaks --atExit` or similar | E (T-084 / T-019) | todo |
| DW-040 | T-010 | Reclaim API gaps: no non-RT retire path (RetireQueue is audio-thread-only; Reclaimer takes only graphs/nodes from other threads), and no Release-safe "am I the render thread?" query (`RtTrap::inRealtimeContext()` is false in Release, not nonblocking). So asset retirement is an explicit call, not automatic | E (T-004 follow-up) | todo |
| DW-041 | T-010 | Something must own the `AudioFileLoader` (daw.loader) and forward its completions as EngineEvents | E/B (T-014) | done (T-014) |
| DW-042 | T-010 | Rule for asset-playing nodes: on the audio thread drop a reference only via `AudioAssetRef::retire(engine.retireQueue())`; if it returns false keep it and retry next block. Never destroy a handle on the audio thread | D (T-013, T-041) | done for AudioClipPlayer (T-013: refs held for the node's life, released on reclaim); applies again to T-041 |
| DW-043 | T-010 | ImportAsset command should call `AudioImporter::importFile` and persist `projectRelativePath` | M (T-030) | done (T-030: import stays outside the command; facade `importFile` → DW-124) |
| DW-044 | T-010 | IO-033 (T-056): per-request progress events still needed; the peak cache already handles stale rates | E (T-056) | done (T-056: `reload` progress per asset on `assetsReloaded`) |
| DW-045 | T-086 | Product-name leftovers in files that wave-4 workers own: `core/Denormals.h:16` (`#error "macDAW targets arm64 only"`), `io/AudioFileLoader.cpp:24` (`os_log_create("dev.macdaw", "io")` → `dev.emberstudio`), `Tests/DAWEngineTestSupport/TestAudio.cpp:22` (temp prefix `macdaw-t010-`). Fix after T-006/T-008/T-009/T-012 merge | E (lead, small) | done (T-087) |
| DW-046 | T-086 | The built app is now `Ember Studio.app` (path contains a space); CTL-023's attach-mode launcher must quote it. The Swift package name stays `macDAW` (01 doesn't constrain it); the repo folder `/Users/artem/dev/macDAW` is unchanged. Plugin cache moved to `~/Library/Application Support/Ember Studio/` (no migration; a rescan) | B (T-018/T-032), lead | done (T-032: launcher uses Process with an argument array; tested at a path with spaces) |
| DW-047 | T-006 | RenderGraph should carry a per-node latency table + total PDC latency for `Telemetry::publishNodeLatencies` (audio thread copies on graph change), and the `GraphDescription.version` so telemetry can report which applyGraph version is rendering (natural thing for dawmcp to wait on) | E (T-012 / T-021), B (T-014) | done (T-014) |
| DW-048 | T-006 | GraphBuilder hands out MeterIDs (≤ `Telemetry::kMaxMeters` = 4096) to channel strips, which call `writeMeter(id, peak, rms)` from `process()`; the 300 ms window is the strip's job | E/D (T-012 follow-up, T-013/T-020) | done (T-013: `NodeKindInfo::meters`, `NodeCreateInfo::meter`, `GraphBuilder::meterOf`); facade NodeID→MeterID map in DW-071 |
| DW-049 | T-006 | Driver calls `Telemetry::countXrun()` (IO-023) and `setDeviceOutputLatency()` (IO-005); overruns are detectable from `lastBlockLoadPercent > 100`. Facade copies `TelemetrySnapshot` field by field into `TelemetryPOD`; `firstViolation()` is non-RT and allocates | E (T-011/T-051), B (T-014) | done (T-011 driver, T-014 TelemetryPOD + `overload` event on xrun growth) |
| DW-050 | T-012 | No `ErrorCode::cycle` in `core/Result.h` though MIX-002 names `Error::cycle`; builder returns `invalidArgument` "cycle: <NodeIDs>". Add the code (ideally with a structured ID list) and map it to `DAWError.routingCycle` | E (core) + B (T-014) | done (T-014) |
| DW-051 | T-012 | Clip/note delivery: node factories get a node's clips and notes only when an instance is created (new node or kind/configVersion/param range change). Either clip edits bump `configVersion`, or clip players get per-graph clip data | D (T-013) / M (T-016) | decided (T-013): clips/assets fixed per instance; model bumps configVersion on clip edits and asset load (DW-072) |
| DW-052 | T-012 | PDC (MIX-021) belongs in `RenderGraph::feed()`; migrate T-004's EngineChecks off the old summing path, then remove it. `MasterNode::clippedSamples()` should reach telemetry | E (T-021), E (T-006 follow-up) | PDC/feed part done (T-021); `clippedSamples` → telemetry in DW-083 |
| DW-053 | T-012 | Facade: `applyGraph` submits to `GraphCompiler`; `EngineFacade.h` includes `daw/GraphDescription.h` | B (T-014) | done (T-014) |
| DW-054 | T-012, lead | Under ASan the RT trap sees no allocations (DW-012), so the RtTrap suite and the Telemetry rtViolations tests (DW-011/024) fail with `--sanitize=address`. The TEST-007 sanitizer job must exclude or skip them | E (T-019 / T-084) | todo |
| DW-055 | T-009 | Fill the marked seam in `OfflineDriver::render`: `transport.locate(from)` + `play()` before the loop, `stop()` after. Rendering twice on one engine is bit-identical only for stateless nodes, so the pre-render locate must reset timeline nodes even when stopped (TIME-008 covers locate while playing), or IO-011 needs an engine-level reset | E (T-009 follow-up after T-008) | done (T-009) |
| DW-056 | T-009 | `ExportSpec.blockSize` can't be checked against the published graph's `maxBlock` (Engine doesn't expose it); an oversize block renders silence silently. Add a non-RT `Engine::currentMaxBlock()` or check in the facade. `ExportSpec`/`ProgressFn` were undefined in the specs; T-009 defined them in `io/ExportSpec.h` (carries the TempoMap; now that `RenderGraph::tempoMap()` exists, reconsider) | E / B (T-014) | done (T-014) |
| DW-057 | T-009 | Facade: map `ExportSpecPOD` → `daw::ExportSpec`, run offline render on a job thread with the device driver stopped, turn `OfflineProgress` into job status. Cancellation would need `ErrorCode::cancelled` | B (T-014) | done (T-014) |
| DW-058 | T-008 | Goldens `loop_wrap_midblock` (TIME-005) and locate/no-stuck-voices (TIME-008) | E (T-019) | done (T-036: `loop_wrap_midblock`, `locate_reset`; MIDI no-stuck-notes golden is DW-101) |
| DW-059 | T-008 | Driver calls `Engine::transport().setOutputLatency(samples)`; facade `TransportPOD` maps from `TransportPlayhead` | E (T-011), B (T-014) | done (T-014) |
| DW-060 | T-008 | Loops shorter than a block (< 4096 samples) play once then leave a gap (contract allows 2 segments). Model should enforce a minimum loop length | M (T-030 SetLoop) | done in the model (T-030: enabled loops ≥ largest block); tempo edits can still shrink a loop → DW-125 |
| DW-061 | T-008 | Product question: on a tempo edit the playhead keeps its sample position, so its musical position shifts. Keeping the tick instead needs a decision | user | todo |
| DW-062 | T-008 | 03 clarifications: a segment's [startTick, endTick) is exactly the ticks whose events sound in it; a stopped/0-frame block has 0 segments and seg[0] carries the position; past the loop end plays on; loop wraps don't reset nodes. Also `RenderStepDesc::resetOnLocate` comment in `core/RenderGraph.h` says "locate or loop jump" — should say locate only | spec (lead) + E (small) | done (T-087) |
| DW-063 | T-009 | Effect tails survive a locate (TIME-008), so a reverb/delay tail from earlier playback carries into an export on the same engine. Fully repeatable exports need an engine-level "reset all nodes" before offline renders — spec question | user / spec | todo; T-073: two renders on one engine with a reverb null at −121.5 dBFS but aren't bit-identical (first render's tail), so `reverb_determinism` compares fresh engines |
| DW-064 | T-009 | Facade passes the map it built the current graph from as `ExportSpec.tempo`, and disarms recording before an export (the driver doesn't touch the recording flag) | B (T-014) | done (T-014) |
| DW-065 | T-087 | Under TSan (like ASan, DW-054) malloc is replaced, so the RT-trap allocation tests (RtTrap ENG-031/032, DW-019, Telemetry DW-011/024, OfflineDriver IO-013) fail; Swift Testing exit tests always SIGABRT under TSan whatever their body (so ENG-032's abort test passes only by accident); IO-010 "60 s in < 10 s" is too slow. The TEST-007 TSan job must skip these. TSan otherwise clean (0 reports, 12.7 s) | E (T-019 / T-084) | todo |
| DW-066 | T-087 | `Package.swift` still has `name: "macDAW"` (package name, not a module). Rename when no worker owns Package.swift | lead (small) | todo |
| DW-067 | T-011 | Facade: publish graphs prepared for at least `driver.current().bufferFrames` (shorter → silence, counted in oversizeBlocks); stop the driver before an offline render (DW-057); enabling input (record/monitor armed) means restarting the driver with `inputEnabled` — no live input switch | B (T-014) | done (T-014) |
| DW-068 | T-011 | IO-023 rest: overruns from render time vs block duration, `EngineEvent.overload`; one processor-overload notification often arrives right at start, so ignore a short window after start | E (T-051) | done (T-051: render overruns per IO cycle, 0.25 s start grace window) |
| DW-069 | T-011 | 04 Interfaces names `DriverConfig` and `DeviceLatency` without defining them; T-011 defined them in `io/DriverConfig.h` / `io/DeviceLatency.h` (like `ExportSpec`). Add them to the Interfaces block | spec (lead) | todo |
| DW-070 | T-011 | FakeDeviceDriver can reuse `DeviceRenderer` (device-independent IO cycle) and `publishDeviceLatency()`. Device start/stop/config/latency not reachable via dawctl/dawmcp until the facade + control exist | E (T-050), B (T-017/T-018) | done (T-050, T-051, T-018: dawctl/dawmcp device methods) |
| DW-071 | T-013 | Facade/telemetry need the NodeID → MeterID map (today only `GraphBuilder::meterOf`, compile thread): publish it with each graph or through GraphCompiler | B (T-014 / T-020) | done (T-014) |
| DW-072 | T-013 | DW-051 decision: the model must bump a clip player's `configVersion` whenever its track's clips change and when an asset they use finishes loading (facade emits `assetLoaded`) | M (T-016) | done (T-016) |
| DW-073 | T-013 | Goldens: two adjacent clips with fades (DSP-001), loop wrap mid-block through the clip player (TIME-005/006), locate reset (TIME-008), pan hard-left/centre/right (MIX-005, done T-025 `pan_law`) | E (T-036) | done (T-036: `clips_fades_tempo_change`, `loop_wrap_midblock`, `locate_reset`) |
| DW-074 | T-013 | DSP-041: `dsp/ParamInfo.h` and `ChannelStrip::kParamInfo` exist but no registry publishes param tables. Gain slot holds linear amplitude, labelled with a dB curve for display | D/E | todo |
| DW-075 | T-013 | Clip edits during playback swap in a new player instance with no crossfade (can click; fix = per-graph clip data, touches graph/); stop cuts audio with no declick; DSP-040 (NaN guard, silence-tail) not done for clip player / strip | D (later) | todo |
| DW-076 | T-014 | `DAWError` has no case for engine I/O / out-of-memory / internal errors; `EngineClient` maps them to `.invalidArgument("i/o: …")`. Add `.engine(code:detail:)` | M | done (T-016: `DAWError.engine(code:detail:)`) |
| DW-077 | T-014 | `loadAsset` takes no peak-cache directory, so IO-034 peaks aren't computed through the facade | B (with T-056) | done (T-056: `loadAsset(id, path, peakCacheDir)`; EngineSync uses the project's Cache/) |
| DW-078 | T-014 | `NodeKindInfo` has no param-info hook; facade `paramInfoJSON` names `ChannelStrip::kParamInfo` directly, other kinds return "[]" (see DW-074) | E/D | todo |
| DW-079 | T-014 | `setDevice` with a different session rate returns `unsupported` until IO-021/IO-033 | E (T-051 / T-056) | done (T-051: setDevice with a new rate rebuilds the graph at that rate; assets wait for T-056) |
| DW-080 | T-014 | Facade adds a `daw.export` thread for offline jobs; not in the CONV §3 thread table | spec (lead) | todo |
| DW-081 | T-014 | `GraphCompiler::Status` keeps only the latest error: two builds finishing between polls can lose the earlier `graphRejected` event (`waitForGraph` is still right) | E | todo |
| DW-082 | T-021 | Expose `GraphCompiler::takeEvents()` (latency change, MIX-024) as `EngineEventType::latencyChanged`; needs a PROPOSED delta to 08 events (`include/daw/`) | B | todo |
| DW-083 | T-021 | `MasterNode::clippedSamples()` → telemetry: new Telemetry counter + `TelemetryPOD` field | E (core) + B | todo |
| DW-084 | T-021 | Goldens `pdc_alignment_null` (MIX-021) and click-on-beat-1 behind a latent master insert (MIX-023); need T-019's harness + a test-only FakeLatencyNode in golden builds | E (T-019 / T-025) | done (T-025 `pdc_alignment_null`) |
| DW-085 | T-021 | Metronome is already a timeline node (scheduled `latency` ahead); T-024 should confirm and decide whether it resets on locate | D (T-024) | done (T-024: timeline node, latency ahead; resets on locate by detecting non-continuing segments, 64-frame fade) |
| DW-086 | T-021 | Pre-roll renders `latency` frames inside the first block of a run: a CPU spike that can overrun a live callback when latency is large; a mid-run latency change jumps timeline nodes with no new pre-roll. Consider spreading pre-roll over blocks (output silent) | E | todo |
| DW-087 | T-021 | `Engine.cpp` duplicates the `makeSegment` helper (from `time/TransportSegments.h`); dawmcp check on `graphLatency` once a latent node is reachable over the protocol | E (small), B (T-018+) | telemetry part done (T-018: `graphLatency`/`nodeLatencies` in `daw_engine_telemetry`); no latent node reachable over the protocol yet; `makeSegment` duplicate todo |
| DW-088 | T-050 | Move `RunningConfig` from `io/CoreAudioDriver.h` to `io/DriverConfig.h` (FakeDeviceDriver includes CoreAudioDriver.h only for it) | E (small, T-051) | done (T-051) |
| DW-089 | T-050 | dawctl/dawmcp can't pick the fake device: `EngineFacade::create` realtime always uses CoreAudio. Needs a facade option/mode (`include/daw/`) | B (T-017/T-018) | todo: needs a facade driver option (`DriverConfigPOD.driver = coreAudio | fake` + fake options), then `device.list/set/start/stop`, device latency in telemetry, `project.new {engine: offline|realtime}` (T-017 notes) |
| DW-090 | T-050 | CoreAudio property listeners (T-051, IO-020) should emit the same `io/DeviceNotification.h` notifications so DeviceMonitor reads either source; render-time overruns stay with T-051 (DW-068) | E (T-051) | done (T-051: `io/CoreAudioDeviceListener`) |
| DW-091 | lead | Flaky under full-suite load (~1 in 15–35 runs): "TIME-009: a reader thread never sees a torn playhead" (T-008, TransportTests.swift:69) (T-050's scripted-events flake was a test race, fixed in 69ea8bf). A torn playhead would be a real bug, so investigate before calling it a test issue | E | done (T-051: test race, not a torn playhead; seqlock correct; test waits for the first block and asserts ≥ 1000 published blocks) |
| DW-092 | T-020 | Facade `paramInfoJSON(.gain)` should return `GainNode::kParamInfo` (level, mute); then update EngineClientTests.swift (expects "[]" for `.gain`). Same hook as DW-078 | B | todo |
| DW-093 | T-020 | Goldens: bus_send_sum with pre- and post-fader sends; strip mute ramp; phase-invert null; gain-node level step; muted track with sends goes silent and fades back | E (T-019 / T-025) | done (T-025 `bus_send_sum`, `send_ramps`; strip mute ramp/phase null covered by `ChannelStripTests`) |
| DW-094 | T-016 | Real `SetParam` command needs a param-target design (likely shared with 11's `ParamTarget`); MODEL-032 must check model IDs ≤ `GraphNodeID.maxModelID` (2^56−1), since NodeIDs carry a role in the top 8 bits | M (T-022) | done (T-022: `ParamTarget` in `DAWModel/Project/ParamTarget.swift`, strip/sendLevel/device; spec 11 can adopt it) |
| DW-095 | T-016 | Control layer: `EngineSync.flush()` before offline render/export; `EngineSync.pollEvents()` as the single engine-event drain (so `assetLoaded` reaches DW-072 bumps); map engine NodeIDs back with `GraphNodeID.owner(of:)`; master limiter is `runtime.masterLimiterParam(master.id)` | B/M (T-017/T-018) | done (T-017; master limiter unused until a control method sets it) |
| DW-096 | T-016 | eq, compressor, reverb, delay, sampler, midiClipPlayer have no engine factories yet, so projects using them (fixture `routing`) are rejected by the real engine. Run `routing` through EngineClient once registered | D/E (T-040, T-041, T-070..073) | done for MIDI (T-044: `MidiTempoEngineTests` runs `midi_tempo` through EngineClient); `routing` still needs eq/delay (T-070, T-072; reverb registered by T-073) |
| DW-097 | T-016 | Nothing in the model calls `loadAsset` for a project's assets on open/import yet | M (T-031 / ImportAsset) | done (T-031: `ProjectStore.loadAssets()` / `EngineSync.loadAssets(_:folder:)` on open) |
| DW-098 | T-016 | Bypassed devices are left out of the graph until host bypass (PLUG-018): bypass is a rebuild and the device loses state. Optional: `ProjectChange` diff could skip entities with unchanged storage (main per-step cost on huge projects) | P (T-064), M (optional) | todo |
| DW-099 | T-040 | MIDI routing in RenderGraph/GraphBuilder: MIDI edges carry no data (player `midiOut` capacity 0, instrument `midiIn` empty). Needs per-step MIDI storage of fixed capacity that never shrinks between blocks (no-hanging-notes guarantee) and MIDI edge delay for PDC (05 "PDC semantics") | E (T-045) | done (T-045: pulled MIDI storage of fixed capacity per graph, k-way stable merge, `MidiDelayLine` PDC with carry-over; 05 "MIDI routing") |
| DW-100 | T-040 | Sampler should handle CC 123 (All Notes Off): a re-created MidiClipPlayer (DW-051 note edit while playing) sends it on all 16 channels. DSP-023 lists only CC64 and pitch bend | D (T-041) | done (T-041) |
| DW-101 | T-040 | DSP-003 golden (`midi_loop_wrap`) once the golden harness, MIDI routing and a sampler exist | D/E (T-019, T-041) | done (T-044: golden `midi_loop_wrap`) |
| DW-102 | T-040 | Flaky "ENG-014: RT-retired objects are freed on daw.reclaim" (EngineChecks.cpp:743, `rtRetireQueue`): waits for `destroyed`, then reads `rtObjectsFreed()`, which the reclaimer bumps only after the destructor returns. Wait on `rtObjectsFreed() == 1` instead | E | done (T-019) |
| DW-103 | T-040 | MidiClipPlayer must chase notes (user decision): playback starting inside a note (play, locate, loop start) sounds it from that frame for its remaining length. T-040 shipped without chase; keep the no-hanging-notes guarantee and the capacity reservation | D (with T-041) | done (T-041: sample-exact chase; fuzz requires held == sounding) |
| DW-104 | T-040 | `BuiltinNodes.h` doc comment doesn't list midiClipPlayer | D (small) | done (T-041) |
| DW-105 | T-017 | `ImportAsset` command `{"type": "ImportAsset", "asset": AssetRef}` (reserve `asset.id`, append; inverse removes). `asset.import` loads into the engine under `project.ids.next`, then performs it; returns `notImplemented` until registered | M (T-030) | done (T-030) |
| DW-106 | T-017 | `SetLoop` command so `Project.loop` follows `transport.setLoop` (today it only drives the engine) | M (T-030) | done in the model (T-030: `SetLoop`); dispatcher/EngineSync push → DW-123 |
| DW-107 | T-017 | `project.open/save` are wired to `ProjectStore.open/save` (`notImplemented`). The dispatcher creates an engine at the project's rate, loads assets relative to the folder and reports `loadReport.offlineAssets`; T-031's `ProjectLoadReport` should replace that shape | M (T-031) | done (T-031: `project.open` returns `ProjectLoadReport` as `loadReport`; headless dispatchers don't autosave) |
| DW-108 | T-017 | For T-018/T-019: `ControlMethod.paramsType` is ready for CTL-021 schemas; `Dispatcher.call(_:_:)` is the in-process headless entry; `ControlUIProvider` is the attach hook (T-032). GoldenTests can run fixtures in-process with `ControlScript(contentsOf:)` + `Dispatcher.handle(_:)` | B/E (T-018, T-019) | done (T-018 schemas from `paramsType`; T-019 in-process fixtures) |
| DW-109 | T-022 | C++ interop batch-compile trap: an unapplied `String.init` in any DAWModel file sharing a batch job with `EngineClient.swift` hides CxxStdlib's `String(std.string)`, so clean builds fail ("no exact matches in call to initializer"). Fixed once in `DAWError.swift` (d9eb9d5); can recur when files are added. Wrap EngineClient's std::string → String conversions in one helper that avoids overloaded `String(_:)`; CI clean builds (DW-005) | B (lead) | todo |
| DW-110 | T-022 | `Track.clips` is documented "sorted by start" but `validate()` doesn't enforce it (test stand-in clip commands don't keep order). Decide with the real clip commands | M (T-030) | done (T-030: clips sorted by (start, id), checked in validate()) |
| DW-111 | T-022 | `ProjectStore.open` should run `validate()` on the decoded project and report/repair failures (decoding only reserves IDs and rejects IDs > maxModelID) | M (T-031) | done (T-031: open validates; unsorted clips/notes repaired and reported, other broken invariants are errors) |
| DW-112 | T-022 | `SetParam` on a device param index ≥ the kind's published ParamInfo count (or a kind without ParamInfo, e.g. FakeEngine) grows the slot range → structural rebuild instead of a slot write. Goes away once every kind publishes ParamInfo; otherwise cap indices | M/B (with DW-092) | todo |
| DW-113 | T-022 | No `RenameBus`/`MoveBus` (RenameTrack/MoveTrack take tracks only); the mixer UI (UI-030) will likely want them | M (before T-076) | todo |
| DW-114 | T-022 | Once dawmcp exists: run a routing scenario (AddBus/AddTrack/AddSend/SetTrackOutput, cycle rejection → CTL-003 `routingCycle` data, render + analyze) | B (T-018) | done (T-018: routing scenario through the dawmcp tools) |
| DW-115 | T-051 | dawctl/dawmcp device methods: create the engine with `DriverConfig(driver: .fake)` (Dispatcher's `EngineFactory` takes only a sample rate today), `device.list`, `device.set` (`setDevice`), `device.simulate` (`simulateDeviceEvent`), `deviceChanged` with its `DeviceChange` in `engine.events`; then a dawmcp check of a scripted loss | B (T-018) | done (T-018: `device.list/set/simulate`, realtime engines default to the fake driver) |
| DW-116 | T-051 | Add `io/DeviceMonitor.h` (`DeviceMonitorHost`, `DeviceSwap`) to the 04 Interfaces block, with DW-069 (Interfaces change → user) | spec (user/lead) | todo |
| DW-117 | T-051 | `GraphCompiler` fixes its sample rate at construction, so a session-rate change replaces the compiler and maps tickets via `ticketBase`; `GraphCompiler::setSampleRate` would be simpler | E (small) | todo |
| DW-118 | T-051 | After a session-rate change, loaded assets keep their load rate; the facade posts `assetsReloaded` with `unsupported`. The facade doesn't keep asset paths, so T-056 must (see DW-077) | E+M (T-056) | done (T-056: facade `AssetReloader` keeps paths; placeholder removed) |
| DW-119 | T-051 | IO-021 (2) "finalize recordings" only disarms recording (`DeviceHost::finalizeRecordings`, `Impl::stopForDeviceChange`) | REC (09) | todo |
| DW-120 | T-051 | A device lost during an export: notifications are dropped while the export pauses the device; a failed restart afterwards reports `startFailed` and recovers on the next notification, with no fallback to the default | E (small) | todo |
| DW-121 | T-051 | FakeDeviceDriver `start()` with an explicit rate doesn't move the fake device's nominal rate (CoreAudioDriver's does), so fake runs never produce the "rate set back" notification | E (small) | todo |
| DW-122 | T-051 | Document `DAW_DEVICE_EVENT_TESTS=1` in 14 next to `DAW_DEVICE_INPUT_TESTS` / `DAW_SKIP_DEVICE_TESTS` | lead | todo |
| DW-123 | T-030 | `transport.setLoop` should also perform `SetLoop` (`{"type":"SetLoop","loop":{start,end,isEnabled}}` or `"loop": null`), and `EngineSync` should push `project.loop` to `engine.setLoop` after each command, undo/redo and attach (an undone SetLoop doesn't reach the transport today); on open (T-031) too | B (T-018) + M | done (T-018 dispatcher; T-031 EngineSync pushes `project.loop` on attach, after commands and undo/redo, and on open) |
| DW-124 | T-030 | Swift can't call `AudioImporter::importFile` (io/, not in include/). Add a facade `importFile(path, projectFolder, mode) → {path, projectRelativePath, copied}` mirrored in EngineProtocol/EngineClient/FakeEngine (08 Interfaces change → user); `asset.import` calls it before `loadAsset`. T-031's save copies assets outside the folder into `Audio/` and rewrites paths | B + M (T-031) | save part done (T-031: save copies outside audio into `Audio/`, renames on a clash); facade `importFile` (08 Interfaces change → user) todo |
| DW-125 | T-030 | A tempo edit after `SetLoop` can shrink an enabled loop below 4096 samples (the model doesn't refuse tempo edits). Either the transport handles loops shorter than a block, or tempo edits get refused (user decision) | E / user | todo |
| DW-126 | T-030 | `SetSessionSampleRate` not implemented: `AudioClip.sourceOffsetSamples` is in session-rate samples, so a rate change must rescale every clip offset | M (T-056) | done (T-056) |
| DW-127 | T-030 | After a left trim (`ResizeClip`), MIDI notes can have negative relative starts or lie past the clip end (kept so trimming back restores them; the builder clips to the window). Note commands must accept that | M (T-042) | done (T-042) |
| DW-128 | T-030 | `ControlTestImportAsset` in `Tests/DAWControlTests/Support/ControlTestSupport.swift` is dead now; `ControlTestAddAudioClip` etc. can become `AddClip`/`RemoveClip` | B (T-018, small) | done (T-018) |
| DW-129 | T-018 | Claude Code lists `.mcp.json` servers as "Pending approval" until approved, so workers don't get dawmcp tools. Option: `"enabledMcpjsonServers": ["dawmcp"]` in a project `.claude/settings.json`; and have briefings run `scripts/dawmcp.sh --build-only` first (a fresh worktree's first build is slower than the MCP client's startup wait) | user/lead | done (user: `.claude/settings.json` enables dawmcp; `.patchbay.json` setup builds it with `scripts/dawmcp.sh --build-only` before the agent starts) |
| DW-130 | T-018 | After a device fallback or `device.set` changes the engine's session rate (Fake Device B is 44.1 kHz only), `project.sessionSampleRate` still says 48000: nothing makes the document follow an engine-side rate change | M (T-055/T-056) | done (T-056: EngineSync applies SetSessionSampleRate when the engine rate differs) |
| DW-131 | T-018 | Schema probe can't see through tagged unions with a private `Kind` enum or non-`CaseIterable` string enums; new ones need a `JSONSchemaDescribing` entry in `Sources/DAWControl/Schema/ModelSchemas.swift` or the enum made `CaseIterable` (`SchemaTests` fails naming the type). Suggest `CaseIterable` on DAWModel wire enums (`SignalTap`, `Track.Kind`/`Monitoring`, `ParamTarget.StripParam`, `ExportSpec.FileType`/`SampleFormat`, `DeviceDriverKind`, `DeviceEvent.Kind`) | M (small) | todo |
| DW-132 | T-018 | `dawctl` keeps its own copy of the fixture-folder lookup; use `ControlFixtures.defaultDirectories()` (DAWControl) | B (small) | todo |
| DW-133 | T-018 | CTL-031 progress notifications for long renders aren't sent over MCP yet; `daw_session_mode` (CTL-023) and attach stay with T-032 | B (T-032) | done (T-032) |
| DW-134 | T-019 | `EngineClient` can't take a facade built elsewhere, so GoldenTests has `GoldenEngine` (an `EngineProtocol` copy of EngineClient using its `description(for:)`/`error(_:)` via `@testable`). Add `@_spi(Testing) init(facade:mode:)` to EngineClient and delete the copy; until then every `EngineProtocol` change must update `Tests/GoldenTests/GoldenEngine.swift` | M/B (small) | todo |
| DW-135 | T-019 | dawctl/dawmcp run golden fixtures but lack the test-only nodes, so `@node` fixtures render silence there. Document in 14's recipe, or offer a test-node engine in a test-only dawmcp build | B / lead (14) | todo |
| DW-136 | T-019 | Drop `DAWEngineTestSupport`'s no-op `swiftSettings: cxxInterop` (and comment) now that the BUILD-002 check skips C-family targets | E (small, Package.swift) | todo |
| DW-137 | T-019 | Real-device `DeviceDriverTests` sine test depends on the machine's audio output; with `DAW_SKIP_DEVICE_TESTS=1` it reports "no default output device", misleading when the device exists but delivers no IO cycles. Detect a device that doesn't pull and skip with that reason, or move hardware tests to a non-blocking stage | E (T-084) | todo |
| DW-138 | T-019 | `TelemetryChecks` (AllocatingNode) and `PdcChecks` (FakeLatencyNode/SourceNode) keep private test-node copies; switch to `TestNodes.h` | E (small) | todo |
| DW-139 | T-041 | Golden `sampler_pitch` (DSP-021: A4 root, play A5 → 2× freq) once MIDI routing (DW-099) and sampler zone config in the model (DW-140) exist; DW-101 `midi_loop_wrap` now also covers chase at the loop start | D/E (T-044) | done (T-044: golden `sampler_pitch`) |
| DW-140 | T-041 | Model: `DeviceSlot` has no place for the sampler's zone config and nothing emits its `configJSON` (06 "Sampler semantics" format); needs a configVersion bump when zones change or their assets load (DW-051/072) and zone-edit commands | M (T-042 or later) | done (T-042: `DeviceSlot.zones`, `SetSamplerZones`, configJSON in 06 format, bumps) |
| DW-141 | T-041 | `EngineFacade::paramInfoJSON` publishes only channelStrip, so the model gives the sampler `numParams` 0 (default ADSR). Publish `Sampler::kParamInfo` (and GainNode's), ideally via `NodeRegistry::paramInfo` (DSP-041) | E/B | todo |
| DW-142 | T-041 | DSP-040 NaN guard: Telemetry has no NaN counter for processors; the sampler doesn't guard against a NaN asset yet | E (core), then D | todo; the compressor counts NaN blocks locally (`Compressor::nanBlocks()`), ready to forward (T-071) |
| DW-143 | T-031 | MODEL-043 rest: instantiate hosted plugins on open, then `store.restorePluginStates()` with `store.pluginStateProvider = EnginePluginStates(engine:)`; real facade `getPluginState` and a round trip through a real plugin | P | todo |
| DW-144 | T-031 | App: offer recovery when `loadReport.recoveryAvailable` (reopen with `recover: true`), call `close()` on a clean quit, show `offlineAssets` and `repairs` | U (T-032 / T-083) | done (T-032 app part: recovery toast, close() on window close/quit; T-083 dialog still todo) |
| DW-145 | T-031 | A project that was never saved has no folder and isn't autosaved; crash safety for it needs an autosave location such as Application Support | M | todo |
| DW-146 | T-035, T-025 | dawmcp/dawctl `test.fixture` resolves a fixture's relative `asset.import` paths against the server's cwd, not the fixture's folder, so every fixture that imports an asset (`wav_playback_resampled`, `pan_law`, `bus_send_sum`, `pdc_alignment_null`, `clip_overlap_crossfade`) fails in dawmcp unless an `assets` symlink exists | B (T-032 or later) | done (T-032: fixture-relative inputs resolve against the fixture folder) |
| DW-147 | T-035 | A dawmcp server started by the MCP client keeps the engine it was built with; `scripts/dawmcp.sh` rebuilds only at launch, so an agent can't verify engine changes through `daw_render_offline` without a client restart. Add a `--rebuild`/restart hint to the CTL-025 tooling | B | todo |
| DW-148 | T-035, T-025, lead | Flake: `PersistenceTests` "MODEL-044: an edit is autosaved after the debounce…" times out (30 s `eventually`, 30 ms debounce) under full-suite load; seen 3× on 2026-11-02. Likely cooperative-pool starvation or a race in `ProjectStore.scheduleDebouncedAutosave`/`serialized`, not plain slowness | M | done (T-042: race in `ProjectStore.autosave()` bookkeeping, fixed; stress tests) |
| DW-149 | T-025, T-042 | Insert-chain commands `InsertDevice`/`RemoveDevice`/`MoveDevice`/`SetDeviceBypass` (MODEL-005) have no task, and nothing places a master insert (no `RestoreMaster`). Fixtures place inserts through `RestoreTrack`/`RestoreBus` with hand-written IDs; MIX-023's golden uses a bus as the "latent master insert". Could share helpers with T-042's `SetInstrument` | M | todo |
| DW-150 | T-042 | `validate()` now rejects note velocity 0 (06 clamps to 1…127), so an old `project.json` with a velocity-0 note fails to open with `invalidProject`. If such files ever exist, add an open-time repair 0 → 1 (autobuild decision, see docs/autobuild/DECISIONS.md) | M | todo |
| DW-151 | T-042 | dawmcp started at worktree setup doesn't know commands the worker adds (`unknownCommandType`); same root as DW-147. Note it in 14's *Agent verification recipe* or let dawmcp restart when its binary is stale | B / lead (14) | todo |
| DW-152 | T-042 | 07 *Persistence*: say that autosave bookkeeping follows the queue order of file operations and that an edit made during a save still gets its debounced autosave (DW-148 fix) | lead (07) | todo |
| DW-153 | T-032 | `EmberStudioShell` is a SwiftPM target with no product; the Xcode app compiles the same files through its synchronized group, so they build twice. A library product the app links would change 01's product list (Interfaces) | lead/user (01) | todo |
| DW-154 | T-032 | UI-051: once the arrange canvas has its `CAMetalLayer`, `WindowSnapshotter` needs the offscreen Metal path (`cacheDisplay` doesn't capture Metal layers) | U (T-033) | done (T-033: offscreen Metal render composited by `WindowSnapshotter`) |
| DW-155 | T-032 | `project.open` through the app's socket swaps the document but doesn't toast its load report (recovery available, offline assets); File > Open does | U | todo |
| DW-156 | T-032 | Every project window gets its own engine; with `--engine coreAudio` several windows each open the device. Needs a policy (one live engine for the main window, others offline?) | lead/user | todo |
| DW-157 | T-032 | Quitting the real app (SIGTERM, parent exit, menu) is verified by hand only; an automated test needs the built app, e.g. a `scripts/test.sh` stage after xcodebuild | B / test | todo |
| DW-160 | T-024 | Project-level metronome wiring (model setting, command, graph node into master, `transport.setMetronome`, paramInfoJSON for `Metronome`/`GainNode` slots); proposal in T-024's report | M+B (T-026) | done (T-026) |
| DW-161 | T-024 | Optional: add `NodeKind::metronome` to GraphBuilder's `resetsOnLocate` for consistency (the node already self-detects locates) | E | todo |
| DW-162 | T-036 | TIME-008 "effects keep their tails" with a real tailed effect (delay feedback / reverb) once T-072/T-073 exist; today `locate_reset` uses a SineNode insert's state | D (T-072/T-073 or T-077) | todo; T-073: `ReverbTests` checks a locate keeps a real reverb tail through the Engine (unit level); the `locate_reset` golden could switch to the reverb (T-077) |
| DW-163 | T-036 | dawmcp over stdio answered a pipelined `tools/call` (render.offline) before an earlier `daw_test_fixture` call finished, so the render failed; one at a time works. A pipelined script over dawmcp would race | B | todo |
| DW-164 | T-036 | Fixtures can't locate mid-render (only at a render's start). If a golden ever needs it, add a scripted transport event to render.offline | E/B | todo |
| DW-165 | T-033 | Keyboard: ⌫ delete and ⌘E split at the playhead aren't bound yet; bind them to `ArrangeModel.deleteSelection` / `splitSelection(at:)` (controls `edit.delete` / `edit.split`) | U (T-034) | done (T-034) |
| DW-166 | T-033 | UI-010's 60 fps with 1,000 clips on M1 still needs an Instruments run on the real app (only a debug smoke test was measured) | U / user | todo |
| DW-167 | T-033 | Trimming with snap on can shrink a clip to 1 tick; a minimum of one grid step may feel better (UX choice) | U | todo |
| DW-158 | T-023 | Golden `@node` doesn't know the `sidechainMix` test node yet (`TestNodeType::sidechainMix` is in GoldenEngineSupport.h); adding it lets a fixture prove MIX-008 through the model before T-071 | E (T-071 / GoldenTests) | won't do (T-071: the real-compressor golden `sidechain_compressor` proves MIX-008 through the model) |
| DW-159 | T-023 | PLUG-014 says "expose sidechain port 1" while MIX-004 says sidechain edges use `toPort` 0: clarify that "1" is the plugin's aux input bus, fed from the node's NodeIO sidechain (graph `toPort` 0) | spec (lead) | todo |
| DW-168 | lead (phase 2) | `swift test` hung 4 h+ in AttachTests.dawctlAttach: `waitUntilExit()` after `await`s in async tests waits on a run loop that never gets the exit event | B / test | done (T-023: `waitForExit` polls `isRunning`; no `waitUntilExit()` left in DAWControlTests/DawmcpTests) |
| DW-169 | lead (phase 2) | EACCES flakes in DAWControlTests ($TMPDIR dirs created without x bit): ControlSocketServer narrowed the process-wide umask while binding; app autosave could hit it too | B | done (T-023: no umask; chmod 0600 + lstat check before listen) |
| DW-170 | T-045 | MIDI events dropped by a full `MidiDelayLine` are counted per line (`dropped()`) but not in Telemetry: add `midiEventsDropped` to `core/Telemetry` / `TelemetryPOD` / `engine.telemetry`, summed by `Engine::render` (additive 08 delta) | E+B | todo |
| DW-171 | T-045 | Stale comment `Tests/DAWEngineTestSupport/MidiClipPlayerChecks.cpp:498` ("MIDI isn't routed yet…"); the player now writes into real storage | test (any) | done (T-044) |
| DW-172 | lead (phase 3) | Wall-clock tests fail under 4-worker load in `scripts/test.sh`'s swift-test step (pass alone and in plain `swift test` runs): UI-010 perf smoke (`perFrame < 16 ms`, ArrangeModelTests:411), MODEL-044 autosave debounce (PersistenceTests:311), DW-148 autosave poll (PersistenceTests:353), CTL-031 progress pacing, DW-032 sync cost (SyncCostTests:113, T-044). Longer polls or deterministic clocks/hooks | M/U/B | todo; T-056: DW-148 fails ~1 in 4–5 DAWModelTests runs on the base commit too — fix first |
| DW-173 | T-071 | DSP-041 names `NodeRegistry::paramInfo(NodeKind)`, but it doesn't exist; the facade's `paramInfoJSON` hard-codes kinds (strip, compressor, metronome, gain). Add `paramInfo` to `NodeKindInfo`/`NodeRegistry` and have `paramInfoJSON` read it | E | todo |
| DW-174 | T-071 | Meters (strip post-fader, compressor GR) can't be read through the control protocol: `dawctl`/`dawmcp` have no meter method, only the facade's `meter(node)` / `EngineProtocol.meter`. Add one (13 delta); a typed GR reading could come with it | B | todo |
| DW-175 | T-071 | `nodes/BuiltinNodes.h` doc comment lists the registered kinds but not `compressor` (one line) | D | done (T-073) |
| DW-176 | T-071 | TEST-008 perf (64 × EQ + Comp ≥ 20× realtime): the compressor does a per-sample `log10` + `exp` in double, unmeasured. If too slow, add a below-knee fast path | D (T-077 / T-084) | todo |
| DW-177 | T-026 | Export dialog (T-082) must leave the click out by default: go through `render.offline` (which does it) or set `store.engineSync?.isMetronomeSuppressed = true` around `renderOffline`; an "Include metronome" checkbox maps to `includeMetronome` | U (T-082) | todo |
| DW-178 | T-026 | `paramInfoJSON(.gain)` now publishes GainNode's 2 slots, so a device slot of built-in kind `.gain` gets level/mute slots (it had none). Sends are unaffected (`ParamLayout.Send`). Check when insert chains land (DW-149) | M | todo |
| DW-179 | T-034 | Arrow keys aren't bound to `clip.nudge.left|right|up|down`; `KeyChord` drops function keys today (UX choice) | U | todo |
| DW-180 | T-034 | Toolbar tempo/signature are display only; editing them (`SetTempoEvent` / `SetTimeSignature`) from the toolbar is a possible follow-up | U | todo |
| DW-181 | T-034 | The NSEvent → `KeyMonitor` path has no automated test (posting key events needs Accessibility); manual check in the app: Space, R, L, ⌘E, ⌫, ⌘T | U / user | todo |
| DW-182 | T-056 | Golden for a session-rate change (CONV §5.4 gap; checks live in `SessionRateTests`/`SessionRateControlTests`); `GoldenEngine.swift` doesn't map the `reload` event or `assetsReloadPending` | D/test | todo |
| DW-183 | T-056 | App has no UI to change the session rate or show re-conversion progress | U (T-055 or later) | todo |
| DW-184 | T-056 | Control: a method or `wait` flag on `command.apply` that blocks until re-conversion finishes, with CTL-031 progress (today clients poll `engine.telemetry.assetsReloadPending`) | B | todo |
| DW-185 | T-056 | `RestoreSessionSampleRate` JSON requires `clipOffsets`/`zoneLoops` even when empty (hand-written scripts must pass `[]`) | M (minor) | todo |
| DW-186 | T-051/T-056 | If the latest graph description is rejected during a rate change, the old-rate graph keeps rendering until the next accepted description | E | todo |
| DW-187 | T-043 | 06 MidiClipPlayer "Capacity": the writer reserve now includes held preview notes (`numActive + numPreviewOn + 2`) and the player merges `MidiPreviewInbox` events at frame 0 | spec (lead) | todo |
| DW-188 | T-043 | 13 `ui.*` paragraph should list the `pianoRoll.*` control ids and `ui.state.windows[].pianoRoll` (documented in 12 *Piano roll details*) | spec (lead) | todo |
| DW-189 | T-043 | Headless `engine.previewNote` in dawctl/dawmcp so agents can check instruments without the app (today only `ui.perform pianoRoll.key.<n>` in attach mode) | B | todo |
| DW-190 | T-043 | A held preview note is cut and retriggered when its player is re-created (graph rebuild while a key is held); no hang | E (low) | todo |
| DW-191 | T-043 | Piano roll 60 fps check with Instruments on a dense clip; per-asset peak refresh during a re-conversion pass (today waveforms update once at `finished`) | U | todo |
