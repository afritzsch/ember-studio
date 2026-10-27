# 13 — Control Protocol, `dawctl`, `dawmcp`

**Depends on:** 07 (Commands, ProjectStore), 08 (EngineClient) · **Owns:** `Sources/DAWControl/`, `Sources/dawctl/`, `Sources/dawmcp/`, `App/macDAW/Control/` (socket server).

Agents use this to **drive and verify the DAW themselves** (D-20, D-21, D-22). There is one protocol and three transports:

```
           ┌─────────────── DAWControl (JSON-RPC 2.0 types + Dispatcher) ───────────────┐
 dawctl ───┤ headless: in-process ProjectStore + EngineClient(.offline)                  │
 dawmcp ───┤ headless: same, OR attach: Unix socket → running app's Dispatcher           │
 App    ───┤ ControlSocketServer at a per-instance socket path (CTL-032)                 │
           └──────────────────────────────────────────────────────────────────────────────┘
```

## Requirements

### Protocol
| ID | Requirement | Acceptance |
|---|---|---|
| CTL-001 | JSON-RPC 2.0, newline-delimited JSON over the transport. `DAWControl` defines request/response Codable types and a `Dispatcher` that runs on `@MainActor` against a `ProjectStore` + `EngineProtocol`. | Protocol round-trip tests |
| CTL-002 | Methods (v1): | Each has a test via the headless dispatcher |

| Method | Params | Result |
|---|---|---|
| `project.new` | `{name, sampleRate?}` | `{projectID}` |
| `project.open` / `project.save` | `{path, recover?}` / `{path?}` | `{loadReport}` / `{}` |
| `project.get` | `{path?: JSONPointer}` | project JSON (or subtree) |
| `command.apply` | `{command: {type, …}}` (MODEL-006) | `{ok, createdIDs[]}` or error |
| `command.batch` | `{commands[], atomic: bool}` | results |
| `undo` / `redo` | — | `{label}` |
| `transport.play/stop/locate/setLoop/record` | … | `TransportPOD` |
| `transport.wait` | `{untilTick? , timeoutMs}` | position (live mode) |
| `asset.import` | `{path}` | `{assetID}` (waits for load job) |
| `render.offline` | `{from, to, path, format}` | `{path, durationSec, renderTimeSec}` |
| `audio.analyze` | `{path, range?, fftSize?, bands?}` | `{peakDb[], rmsDb[], lufsIntegrated, truePeakDb, spectrum[], dcOffset, firstNonSilentSample}` |
| `audio.compare` | `{a, b, toleranceDb}` | `{nullResidualDb, maxDiffSample, offsetSamples (xcorr)}` |
| `engine.telemetry` | — | `TelemetryPOD` + per-node latency + rtViolations |
| `engine.events` | `{since}` | drained `EngineEvent`s |
| `engine.paramInfo` | `{kind}` | `ParamInfo[]` |
| `ui.state` | — | UIStateDumper JSON (attach only) |
| `ui.snapshot` | `{path?}` | `{pngPath}` (attach only) |
| `ui.perform` | `{accessibilityId, action}` | (attach only) simulate click/toggle |
| `test.fixture` | `{name}` | loads a built-in fixture project (14) |

| ID | Requirement | Acceptance |
|---|---|---|
| CTL-003 | Errors: JSON-RPC error codes with `data: {dawError, detail}` (e.g. `routingCycle` with path). | — |
| CTL-004 | Headless mode is **deterministic**: same request sequence → identical project JSON and bit-identical renders (IO-011). | Test runs twice |
| CTL-005 | Attach-only methods return `methodNotAvailableInHeadless` in headless mode. | — |

### `dawctl`
| ID | Requirement |
|---|---|
| CTL-010 | `dawctl <method> --json '<params>'` for single calls; `dawctl script file.jsonl` runs a sequence and prints results as JSONL; `dawctl repl`. |
| CTL-011 | `--attach` uses the app socket instead of headless. |
| CTL-012 | Exit code ≠ 0 on any error, so it is usable in shell tests. |

### `dawmcp`
| ID | Requirement | Acceptance |
|---|---|---|
| CTL-020 | MCP server over stdio using the official Swift MCP SDK (`modelcontextprotocol/swift-sdk`, pinned version). | Connects from Claude Code via `.mcp.json` |
| CTL-021 | Each control method is exposed as an MCP tool (`daw_project_new`, `daw_command_apply`, `daw_render_offline`, `daw_audio_analyze`, `daw_audio_compare`, `daw_engine_telemetry`, `daw_ui_snapshot`, …) with JSON Schema input generated from the Codable params. | Tool list test |
| CTL-022 | `daw_ui_snapshot` returns the PNG as MCP image content (plus the path). | — |
| CTL-023 | Mode switch tool `daw_session_mode {headless | attach}`; the default is headless. Attach launches **this worktree's** built app (not `open -a`, which could pick another worktree's build) with `--control-socket <path>` (CTL-032), and terminates it when the MCP session ends. | Two worktrees attach at the same time without interfering |
| CTL-024 | `daw_command_schema` returns the catalogue of Command types with their JSON schemas, so agents can discover edits. | — |
| CTL-025 | Project-local `.mcp.json` at repo root registers `dawmcp` through a **repo-relative** launcher (`scripts/dawmcp.sh`, which builds if needed and execs `.build/debug/dawmcp`), so each Patchbay worktree runs its own build. | Works from a worktree path |

### App socket
| ID | Requirement |
|---|---|
| CTL-030 | `ControlSocketServer` listens only when launched with `--control-socket <path>` or in Debug builds; the socket file has 0600 permissions and the server is local-only. |
| CTL-032 | Socket path is per instance (parallel worktrees, `00-conventions §9`): the `--control-socket <path>` argument, or by default `$TMPDIR/macdaw-<pid>.sock`. `dawmcp` attach passes `$TMPDIR/macdaw-<hash of worktree root>.sock`. Stale sockets are unlinked on start. |
| CTL-031 | Requests are dispatched on the main actor; long jobs (render) report progress notifications. |

## Status
| ID | status | test |
|---|---|---|
| CTL-* | todo | |
