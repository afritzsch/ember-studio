# 13 — Control Protocol, `dawctl`, `dawmcp`

**Depends on:** 07 (Commands, ProjectStore), 08 (EngineClient) · **Owns:** `Sources/DAWControl/`, `Sources/dawctl/`, `Sources/dawmcp/`, `App/EmberStudio/Control/` (socket server).

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
| `command.schema` | `{type?}` | `{commands: [{type, schema}]}` (CTL-024) |
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

**Protocol details (clarified in T-017).** The code is the reference: `Sources/DAWControl/ControlParams.swift` (params/results), `ControlError.swift` (codes).
- *Wire:* named params only (an object; missing = `{}`); a request without `id` is a notification; a JSON array is a JSON-RPC batch. Relative paths resolve against the dispatcher's working directory (dawctl: its cwd).
- *Errors (CTL-003):* `data = {dawError, detail, …}`. Codes: -32700 `parseError`, -32600 `invalidRequest`, -32601 `methodNotFound`, -32602 `invalidParams`, -32603 `internalError`, -32000 any `DAWError` (`data.dawError` is its case, `data.error` its JSON, a cycle adds `data.path` in model IDs; engine NodeIDs are mapped back with `GraphNodeID.owner(of:)`), -32001 `methodNotAvailableInHeadless`, -32002 `noProject`, -32003 `timeout`. Batch and fixture failures add `index`/`results` or `line`.
- *Determinism (CTL-004, DW-033):* headless `project.new` number *n* gets project ID `00000000-0000-0000-0000-<n in hex>`; headless engine sync applies structural changes synchronously (debounce 0).
- *`command.apply`* returns `createdIDs`: the entity IDs present after and not before. *`command.batch`* `atomic: true` is one `CompositeCommand` (all or nothing); `atomic: false` (default) performs each as its own undo entry and stops at the first failure.
- *`transport.*`* act on the engine. `transport.setLoop {enabled, start?, end?}` also performs `SetLoop` first (DW-123; one undo entry, SetLoop's checks apply, a refused loop never reaches the engine), so `project.loop` follows; `enabled: false` without a range clears it (`loop: null`). The dispatcher also sets the engine directly; since T-031 engine sync pushes `project.loop` on every change too (DW-123), so the engine may get the same loop twice. `transport.wait` needs a realtime engine; headless is offline, so it returns `invalidArgument` there.
- *`asset.import`* loads the file into the engine under the next model ID, waits for the job, then performs `{"type": "ImportAsset", "asset": AssetRef}` (MODEL-005); until that command exists it returns `notImplemented`.
- *`project.save` / `project.open` (T-031, DW-107):* `project.save {path?}` writes the project folder (MODEL-040). `path` is used as given; the default is where the project was opened or last saved, and a new project without one gets `invalidArgument`. Audio outside the folder is copied into `Audio/` (DW-124). `project.open {path, recover?, engine?}` opens the folder, installs the engine, loads every asset relative to the folder (`ProjectStore.loadAssets`) and returns `{loadReport}`, DAWModel's `ProjectLoadReport`: `{offlineAssets, migratedFrom?, recovered, recoveryAvailable, repairs}`. `recover: true` opens a newer autosave (MODEL-045); dawctl passes it as the param, as in `dawctl project.open --json '{"path": …, "recover": true}'`, not as a separate flag. File errors are `fileIO`; files that are unreadable, from a newer format or invalid are `invalidProject`. Headless stores don't autosave (`autosavePolicy = nil`), so dawctl and dawmcp leave no `autosave/` behind. Attach mode keeps the app's policy.
- *`render.offline`* `{from, to, path, format? (wav|caf|aiff), sampleFormat? (float32|int24|int16), tail? = true, blockSize? = 512}` flushes pending engine sync and waits for the graph build first (DW-095); a rejected build is an error. The result adds `sampleRate`, `frames`, `rtViolations`, `clippedSamples`.
- *`audio.analyze`* `range` is file frames `{start, end}`; silence reads -240 dB (JSON has no -∞); LUFS is BS.1770-4 with every channel weighted 1; true peak is 4× oversampled; `spectrum` is `bands` (default 32) log bands of `{lowHz, highHz, db}` from 20 Hz, a full-scale sine reading 0 dB, plus `spectrumPeakHz`; `dcOffset` is the largest channel mean; `firstNonSilentSample` is -1 when silent (threshold `silenceThresholdDb`, default -120).
- *`audio.compare`* `nullResidualDb` is the peak |a − b| in dBFS (shorter file zero-padded), `pass = nullResidualDb ≤ toleranceDb` (default -100, TEST-002); `offsetSamples > 0` means b is later than a (search ±`maxOffset`, default 1 s, first 2^20 frames).
- *`engine.telemetry`* `rtViolations` = engine render scope + every offline render's own scope (also reported apart); `nodeLatencies` carry `owner` and `role`; `graph` is the build status. *`engine.events`* `{since}` → `{events: [{seq, event}], next}`; events are drained once, before every request.
- *`test.fixture`* runs `<name>.jsonl` from the fixture folders (dawctl: `--fixtures`, `$DAWCTL_FIXTURES`, then `Tests/GoldenTests/fixtures` of its checkout), skipping `render.offline`, `audio.*` and nested `test.fixture` lines.
- *Engines and devices (DW-115, T-018):* `project.new`/`project.open` take `engine?: {mode? (offline|realtime, default offline), driver? (fake|coreAudio, default fake), outputDevice?, bufferFrames? = 256}`; realtime runs at the project's session rate through `Configuration.makeRealtimeEngine` (`makeEngine` still makes offline engines). `device.list` → `{devices, outputDeviceID, driver}` (driver null offline). `device.set {outputDevice?, inputDevice?, sampleRate?, bufferFrames?}` calls `setDevice` with the engine's driver kind (realtime only, else `invalidArgument`; a device that is gone is `engine`/`notFound`). `device.simulate {kind: deviceLost|deviceRestored|sampleRateChanged|processorOverload, deviceID?, sampleRate?}` calls `simulateDeviceEvent` (fake driver only, else `notImplemented`). Both return `{outputDeviceID, deviceRunning, sampleRate, events}`, the events being the ones the call raised; they are also kept for `engine.events`, where `deviceChanged` carries `device: {reason, previousDeviceID, deviceID, previousSampleRate, sampleRate}`. Telemetry has `outputDeviceID`, `processorOverloads`, `renderOverruns`.
- *Scripts (CTL-010):* one request per line, as JSON (`jsonrpc` optional, `id` defaults to the line number) or shorthand `method {params}`; `#` and `//` lines are comments. `dawctl script` stops at the first error unless `--keep-going`. Exit status (CTL-012): 0 ok, 1 a request failed, 2 bad usage.

**Attach mode details (clarified in T-032).** The code is the reference: `Sources/DAWControl/Socket/`, `Sources/DAWControl/Attach/`, `Sources/dawmcp/SessionMode.swift`, `App/EmberStudio/Shell/Control/`.
- *Socket (CTL-030/032):* newline-delimited JSON-RPC as above. Socket files are created 0600, and each peer must have the same uid (`getpeereid`). A socket file nobody answers on is unlinked when the server starts. A path where a server still answers, or a path that isn't a socket, is refused (`attachFailed`). The server removes only a socket file it created. The app serves when given `--control-socket <path>`, or in Debug at `$TMPDIR/emberstudio-<pid>.sock`. A path longer than `sun_path` allows (103 bytes) falls back to `/tmp/<same name>`. The attach path is `$TMPDIR/emberstudio-<first 8 bytes of SHA-256 of the checkout root, hex>.sock`.
- *Errors:* -32004 `attachFailed` means attach mode couldn't launch or reach the app, or the app closed the connection. An error the app returns arrives unchanged (the client's `remote` case).
- *Progress (CTL-031):* while a request with an `id` runs, the server sends the notification `{"jsonrpc": "2.0", "method": "progress", "params": {"id": <request id>, "method": <control method>, "progress": 0…1, "message"?}}` on the same connection, before the response. Render and asset jobs report at least 1 % apart, at most every 50 ms, and end at 1. dawmcp forwards progress as MCP `notifications/progress` `{progressToken, progress, total: 1, message: <method>}` when the tool call carries `_meta.progressToken` (DW-133), and sends all of it before the result.
- *App arguments:* `--control-socket <path>`, `--engine fake|coreAudio|offline` (default `coreAudio`; it is the engine `project.new`/`project.open` use when they don't ask for a mode; `fake` is realtime on the fake driver), and `--parent-pid <pid>` (quit when that process exits). With `--control-socket` or `--parent-pid` the app is "automated": quitting never asks about unsaved changes. SIGTERM is a clean quit: every project is `close()`d and the socket file is removed.
- *Launcher (CTL-023, DW-046):* the app is `<root>/.build/xcode/Build/Products/Debug/Ember Studio.app/Contents/MacOS/Ember Studio`. It is rebuilt with `xcodebuild … -derivedDataPath .build/xcode` when it is missing or older than anything under `App/EmberStudio`, `App/EmberStudio.xcodeproj` or `Sources/`, or than `Package.swift`/`Package.resolved` (log: `.build/attach/xcodebuild.log`). It is started with `Process` and an argument array (never a shell, never `open -a`) as `--control-socket <path> --engine <e> --parent-pid <launcher pid>`, with its output in `.build/attach/app.log`. An app already answering on the socket is reused and never stopped by this launcher. Stopping is SIGTERM, then SIGKILL after 3 s.
- *`daw_session_mode` (CTL-023):* `{mode: headless|attach, engine? = fake, build? = true}` returns `{mode, socketPath?, pid?, launched?, note?}`. In attach mode every other `daw_*` tool goes over the socket. Asking for attach again while connected returns `note: "already attached"`. `headless`, and the end of the MCP session (stdin closed), stop the app this session launched. Headless mode keeps its own in-process dispatcher throughout.
- *`dawctl` (CTL-011):* `--attach` uses this checkout's attach socket and `--socket <path>` an explicit one. `--launch` (with `--attach`) starts the app if nothing listens, without `--parent-pid`, so it outlives dawctl. `--progress` prints `dawctl: <method> <n>%` lines to stderr. `dawctl serve [--control-socket p] [--engine e] [--parent-pid n]` serves a headless dispatcher behind the same socket server (used as the app's stand-in in tests).
- *`ui.*` in the app (UI-050..052):* they act on the main window. `ui.state` is the UIStateDumper JSON: `{mainWindow, windows: [{id, title, isMain, project, panes, selection, zoom, scroll, visibleTracks, tracks, transport, toasts, controls}]}`. `ui.perform {accessibilityId, action}` runs a view model's control descriptor: `click`/`press` for buttons and toggles, `toggle`/`on`/`off` for toggles. It returns `{accessibilityId, kind, action, isOn?}`. An unknown id or a bad action is `invalidParams` (the message lists the ids); a disabled control is `invalidArgument`. Ids: `transport.play|stop`, `edit.undo|redo`, `zoom.in|out`, `pane.browser|inspector`, `pane.bottom.<mixer|pianoRoll|deviceChain|compEditor>`, `track.<id>.select|mute|solo`, `toast.<n>.dismiss|action`. `ui.snapshot {path?}` writes the main window's content view through `cacheDisplay` to `path` (relative to the app's working directory; default `$TMPDIR/emberstudio-<pid>-snapshot-<n>.png`) and returns `{pngPath, width, height, window}`.

**dawmcp details (clarified in T-018).** The code is the reference: `Sources/dawmcp/DawTools.swift`, `Sources/DAWControl/Schema/`.
- *Tools (CTL-021):* one per `ControlMethod`, named `daw_` + the method with `.` → `_` and camelCase → snake_case (`transport.setLoop` → `daw_transport_set_loop`). `inputSchema` is generated from the method's `paramsType` by `JSONSchema.of` (a probing decoder; types it can't see through, i.e. tagged unions and non-`CaseIterable` string enums, conform to `JSONSchemaDescribing` in `Schema/ModelSchemas.swift`). A result is one text item with the result JSON; a failure sets `isError` and its text is the JSON-RPC error object (`{code, message, data}`, CTL-003). `daw_ui_snapshot` puts the PNG first as image content, then the `{pngPath}` text (CTL-022).
- *Command catalogue (CTL-024):* the control method `command.schema` (so `dawctl` has it too) lists `CommandRegistry.registered` with each command's wire-form schema (`type` as a `const`).
- *Process (CTL-020):* SDK `modelcontextprotocol/swift-sdk` pinned `exact:` in `Package.swift` (+ `Package.resolved`). stdout carries only MCP frames (fd 1 is redirected to stderr at start). The server exits when stdin closes. Headless config as `dawctl` (fixtures: `--fixtures`, `$DAWCTL_FIXTURES`, the checkout's `Tests/GoldenTests/fixtures`).
- *Launcher (CTL-025):* `.mcp.json` runs `sh -c 'exec "$(git rev-parse --show-toplevel)/scripts/dawmcp.sh"'`. The script builds `--product dawmcp` (output to stderr) when `.build/debug/dawmcp` is missing or older than `Package.swift`, `Package.resolved` or anything under `Sources/`, then execs it with the checkout root as its working directory, so relative render paths land in that worktree. `scripts/dawmcp.sh --build-only` pre-builds (a fresh worktree's first build takes minutes, longer than an MCP client waits).

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
| CTL-032 | Socket path is per instance (parallel worktrees, `00-conventions §9`): the `--control-socket <path>` argument, or by default `$TMPDIR/emberstudio-<pid>.sock`. `dawmcp` attach passes `$TMPDIR/emberstudio-<hash of worktree root>.sock`. Stale sockets are unlinked on start. |
| CTL-031 | Requests are dispatched on the main actor; long jobs (render) report progress notifications. |

## Status
| ID | status | test |
|---|---|---|
| CTL-001 | done (T-017) | `ProtocolTests` (JSONValue, JSON Pointer, Codable round-trips, NDJSON framing, notifications, batches, parse/invalid-request errors) |
| CTL-002 | done (T-017) | `DispatcherMethodTests` (one test per method group; "every v1 method is dispatched"); `AudioAnalysisTests` (levels, spectrum, LUFS, true peak, WAV/CAF/AIFF, null residual, offset) |
| CTL-003 | done (T-017) | `ProtocolTests` "model errors carry data {dawError, detail, error}; a cycle adds its path", "DW-095 maps an engine-side cycle's NodeIDs back to model IDs" |
| CTL-004 | done (T-017) | `DeterminismTests` (same requests twice: identical project JSON, bit-identical renders, 0 RT violations) |
| CTL-005 | done (T-017) | `DispatcherMethodTests` "attach-only methods return methodNotAvailableInHeadless in headless mode" |
| CTL-010 | done (T-017) | `DawctlTests` (`--json`, `script` file/stdin, `repl`, `methods`, `test.fixture`); `ControlScriptTests` |
| CTL-012 | done (T-017) | `DawctlTests` (exit 1 on a failed request, 2 on bad usage, `--keep-going`) |
| CTL-020 | done (T-018) | `DawmcpServerTests` (real `dawmcp` binary driven by the SDK's `Client` over stdio; stdout protocol-only). SDK `modelcontextprotocol/swift-sdk` exact 0.12.1 |
| CTL-021 | done (T-018) | `DawToolsTests` (one `daw_<method>` tool per control method with its params' JSON Schema; failures are `isError` with CTL-003 data); `SchemaTests` (probe-generated schemas) |
| CTL-022 | done (T-018) | `DawToolsTests` "daw_ui_snapshot returns the PNG as image content plus the path" (attach-mode dispatcher, fake UI provider; real attach is T-032) |
| CTL-024 | done (T-018) | `SchemaTests` (every registered command has a complete schema; enum values match decoding; `command.schema` reads the registry; smallest instances decode) |
| CTL-025 | done (T-018) | `LauncherTests` (`scripts/dawmcp.sh` builds this checkout's dawmcp once and execs at the checkout root from any folder; failed build exits 1 with clean stdout; `.mcp.json` is repo-relative) |
| CTL-* (rest) | todo | |
