# Ember Studio — Specification Index

Ember Studio is a linear-timeline DAW for macOS (audio + MIDI tracks), built as a **learning project**: correctness and clean real-time architecture matter more than feature count.

This file is the entry point. Detailed requirements live in `specs/`. Work is broken into agent-sized tasks in [`specs/90-tasks.md`](specs/90-tasks.md). 

## How to use these specs

1. Every agent reads **this file**, [`specs/00-conventions.md`](specs/00-conventions.md), the spec(s) its task references, and the **Interfaces** sections of the specs it depends on.
2. Requirements have stable IDs (`ENG-012`). Code comments, tests and commit messages cite them.
3. A spec's **Interfaces** section is a contract. Changing it means following the change protocol in `00-conventions.md §6` first.
4. A task is done when the acceptance criteria of every requirement it claims pass (see `00-conventions.md §5`).
5. Orchestration uses **Patchbay**: a lead session on `main` starts one worker session per task in its own git worktree (see `specs/90-tasks.md` → *Orchestrating with Patchbay*).

## Spec map

| File | Area | Req prefix | Depends on |
|---|---|---|---|
| [00-conventions](specs/00-conventions.md) | Coding, RT rules, DoD, change protocol | `CONV` | — |
| [01-build-layout](specs/01-build-layout.md) | Packages, targets, build, CI | `BUILD` | 00 |
| [02-engine-core](specs/02-engine-core.md) | Node API, RenderGraph, snapshots, param slots, reclaim, RT trap | `ENG` | 00, 01 |
| [03-time-transport](specs/03-time-transport.md) | Ticks, tempo map, transport, loop | `TIME` | 02 |
| [04-audio-io-devices](specs/04-audio-io-devices.md) | CoreAudio I/O, offline driver, hot-swap, xruns, file import/resample | `IO` | 02, 03 |
| [05-mixer-routing-pdc](specs/05-mixer-routing-pdc.md) | Tracks, buses, sends, sidechain, GraphBuilder, PDC | `MIX` | 02 |
| [06-dsp-builtins](specs/06-dsp-builtins.md) | Gain/pan/meter, Sampler, EQ, Comp, Delay, Reverb | `DSP` | 02 |
| [07-model-commands](specs/07-model-commands.md) | Document model, Commands, undo, persistence, autosave | `MODEL` | 03, 05 |
| [08-bridge-facade](specs/08-bridge-facade.md) | Swift↔C++ facade, GraphDescription | `BRIDGE` | 02, 05, 07 |
| [09-recording](specs/09-recording.md) | Audio/MIDI recording, monitoring, takes, comping | `REC` | 04, 07, 08 |
| [10-plugin-hosting](specs/10-plugin-hosting.md) | AU + VST3 hosting, scanning, state, GUI | `PLUG` | 02, 05, 08 |
| [11-automation](specs/11-automation.md) | Automation lanes, block-rate evaluation, smoothing | `AUTO` | 02, 03, 07 |
| [12-ui](specs/12-ui.md) | SwiftUI shell, timeline/piano roll canvases, mixer | `UI` | 07, 08 |
| [13-control-mcp](specs/13-control-mcp.md) | JSON control protocol, `dawctl`, `dawmcp`, app socket | `CTL` | 07, 08 |
| [14-testing](specs/14-testing.md) | Unit, golden render, RT-safety, MCP-driven verification | `TEST` | 01, 13 |
| [90-tasks](specs/90-tasks.md) | Task breakdown, dependencies, parallel lanes, milestones | — | all |

```
00 ─ 01 ─ 02 ┬─ 03 ─┬─ 04 ──────────┐
             ├─ 05 ─┼─ 07 ─ 08 ─┬─ 09
             ├─ 06  │           ├─ 10
             │      └─ 11       ├─ 12
             │                  └─ 13 ─ 14
```

## Decision log

These were decided in the design interview. Don't revisit one without the user.

| # | Decision | Choice | Rationale / consequence |
|---|---|---|---|
| D-01 | Ambition | Learning project | Clean architecture over breadth; no licensing or distribution work |
| D-02 | Stack | C++20 engine + Swift model + SwiftUI app | Full RT control; native UI |
| D-03 | Workflow | Linear timeline, audio + MIDI tracks | No clip launcher |
| D-04 | Plugins | AU (v2/v3) + VST3 | VST3 is in-process and can crash the host → D-07 |
| D-05 | UI→engine state | Immutable RenderGraph snapshots, atomic swap | Old graphs freed on reclaim thread |
| D-06 | Time | Integer ticks @ 960 PPQ + tempo map | Audio clips move but don't stretch on tempo change |
| D-07 | Plugin crash safety | In-process + autosave/recovery | No sandbox in v1 |
| D-08 | v1 hard features | PDC, sends/buses/sidechain, offline export, automation | All in scope |
| D-09 | Continuous params | Shared atomic param slots referenced by snapshots | Faders don't rebuild the graph |
| D-10 | Audio reading | Decode whole files into RAM | Disk streaming is v2 |
| D-11 | Undo/persistence | Command pattern + JSON project folder | Same Commands for UI and MCP |
| D-12 | Edge cases handled | Device hot-swap, SR mismatch, CPU overload, feedback loops | See 04, 05 |
| D-13 | Automation rate | Block-rate evaluation + per-block linear ramps | No sub-block splitting |
| D-14 | Feedback loops | Rejected at edit time | Graph is always a DAG |
| D-15 | Rendering | Single audio thread | Multicore is v2; snapshot design keeps it possible |
| D-16 | Recording | Audio, MIDI, input monitoring, loop/take comping | All v1 |
| D-17 | UI rendering | SwiftUI shell + AppKit/CALayer/Metal canvases | SwiftUI alone can't handle timeline scale |
| D-18 | Bridge | Swift 5.9+ C++ interop via narrow facade | No templates or exceptions across the boundary |
| D-19 | Built-ins | Gain/pan/meter, Sampler, EQ, Comp, Delay, Reverb | No built-in synth; MIDI → Sampler or plugin |
| D-20 | Verification | Offline golden tests + an MCP server so agents can test the app | See 13, 14 |
| D-21 | MCP architecture | Headless (in-process engine) + attach (app Unix socket) | Same JSON protocol both ways |
| D-22 | MCP capabilities | Commands, render+analyze, telemetry, UI snapshot/state | — |
| D-23 | Target | macOS 15+, Apple Silicon only | — |
| D-24 | Milestones | Engine-first vertical slices | See 90-tasks |
| D-25 | Model home | UI-free Swift package `DAWModel` | `dawctl`/`dawmcp` run the real model |
| D-26 | Device hot-swap | Stop → fall back to default device → re-prepare → toast | No seamless continue |
| D-27 | SR mismatch | Keep original file; resample into RAM at load | Session-rate change re-converts |
| D-28 | Build | SwiftPM packages + thin Xcode app project | VST3 SDK vendored as C++ target |

## Non-goals (v1)
Clip launcher, time-stretching, multicore rendering, plugin sandboxing, disk streaming, Intel/Rosetta, built-in synth, video, notation, collaboration, licensing.
