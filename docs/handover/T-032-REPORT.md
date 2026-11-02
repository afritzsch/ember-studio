## Status at stop

The session was stopped by the user/lead (weekly limit). T-032 is **unfinished**.

**Committed** (branch `t-032-app-shell`, commit 9098a3f "T-032: WIP …"; the working tree is clean apart from this untracked file):
- `Sources/DAWControl/ControlProgress.swift`: the CTL-031 progress value. On the socket it is a JSON-RPC notification `{"method":"progress","params":{id, method, progress, message?}}`, sent before the response and only for requests that have an `id`.
- `Sources/DAWControl/Dispatcher.swift` (additive changes only; `projectOpen`/`projectSave` are untouched because T-031 is editing them):
  - `handle(line:notify:)`, `handle(_:progress:)` and `call(_:_:progress:)`.
  - Render and asset jobs report progress in steps of at least 1%, at most every 50 ms, and always end at 1.
  - `bind(_ store:)` lets the app point the Dispatcher at its main window without detaching the previous store.
  - `engineEventsDidArrive` and `drainEngineEvents()` let toasts read engine events without a second drain.
- `Sources/DAWControl/ControlError.swift`: new cases `attachFailed` (-32004) and `remote(RPCError)`, which passes an app error through unchanged. `init(_:)` is now public.
- `Sources/DAWControl/Socket/ControlSocketPath.swift` (CTL-032):
  - `$TMPDIR/emberstudio-<pid>.sock`, or `$TMPDIR/emberstudio-<sha256 prefix of the checkout root>.sock` for attach mode.
  - Falls back to /tmp if the path would exceed the 103-byte socket path limit.
  - Includes a helper that finds the checkout root.
- `Sources/DAWControl/Socket/ControlSocketServer.swift` (CTL-030):
  - Unix socket created 0600 (umask while binding, then chmod).
  - Each peer is checked with `getpeereid` to be the same uid.
  - A stale socket is unlinked; a socket that is still live, or a path that isn't a socket, is refused.
  - Newline-delimited JSON, handled on the main actor, in order per connection.
  - `stop()` removes the socket file only if this server created it (inode check).
- `Sources/DAWControl/Socket/ControlSocketClient.swift` (CTL-011/023):
  - Blocking round trip on a serial queue; `progress` notifications are forwarded to the caller.
  - `connect(path:timeout:alive:)` retries until the server listens.
  - `call()` mirrors `Dispatcher.call`.

**Half-done:** nothing is written but uncommitted. The pieces above build (`swift build --target DAWControl`, no warnings shown), but they have **no tests yet** and have not been run end to end.

**scripts/test.sh:** **not run** at the last commit. Only the DAWControl target build was checked.

**Exact next steps** (the design is settled):
1. **Tests in `Tests/DAWControlTests/`:**
   - Socket server: 0600 mode, stale socket unlinked, live socket refused, round trip, two clients, `stop()` removes the file.
   - Client errors map to `attachFailed`; app errors pass through as `remote`.
   - Dispatcher progress during `render.offline` on FakeEngine (CTL-031).
   - Socket path hashing and the length limit.
2. **`Sources/DAWControl/Attach/AppLauncher.swift`:**
   - The app bundle is `<root>/.build/xcode/Build/Products/Debug/Ember Studio.app` (the same derived data path as test.sh). It is built with `xcodebuild … -derivedDataPath .build/xcode` when it is missing or stale.
   - Launch with `Process` and an argument array, so the space in the path is safe (DW-046), never `open -a`.
   - Arguments: `--control-socket <path> --engine fake --parent-pid <pid>`.
   - Wait for the socket. If a live socket already exists, reuse it and don't terminate that app.
   - `terminate()` sends SIGTERM, then SIGKILL after 3 s.
3. **`dawctl`:**
   - `--attach`, `--socket <path>`, `--launch` and `--progress` (progress goes to stderr).
   - `serve [--control-socket p] [--parent-pid n]`: a headless Dispatcher behind the socket server. The launcher tests use it as a stand-in app; copy it to a path with spaces for DW-046.
4. **`dawmcp`:**
   - A `daw_session_mode {mode: headless|attach, engine?, build?}` tool, added on top of the per-method tools. Update the `tools.count` assertion in DawToolsTests.
   - In attach mode, route calls through the `ControlSocketClient`.
   - Forward progress as MCP `notifications/progress` when the call carries a `_meta.progressToken`.
   - Terminate the app when stdin closes.
   - Test with two checkout roots at once (CTL-023).
5. **App, with a new SwiftPM target:**
   - Add `EmberStudioShell` at `App/EmberStudio/Shell` and the test target `EmberStudioShellTests` at `App/Tests/EmberStudioShellTests`, both additive in Package.swift and with no new product.
   - The Xcode app compiles the same files through its synchronized group. `App/EmberStudio/EmberStudioApp.swift` holds only the `@main` AppKit entry (BUILD-004 allows only the app target, so there is no Xcode test target).
   - The spike showed SwiftUI builds no in-process accessibility tree. So `ui.perform` runs view-model `UIControl` descriptors (id, kind, label, isOn, isEnabled, action). The `ControlButton`/`ControlToggle` views apply the same id as `accessibilityIdentifier` (UI-052). A source-scan test forbids raw `Button(`/`Toggle(` in the views.
   - The spike also showed that `cacheDisplay(in:to:)` snapshots an NSHostingView correctly here (UI-051).
   - View models: `AppModel`, `ProjectWindowModel` (panes, selection, zoom, scroll, visible tracks, transport), track header models (mute/solo through `SetParam`), and `ToastCenter` (UI-004). The toast mapping covers `deviceChanged` by `DeviceChange.reason`, coalesced `overload`, `pluginCrashed`, `assetLoadFailed`, `graphRejected` and `assetsReloaded` errors, plus a `post(.recoveryAvailable)` API. Expiry uses an injectable clock.
   - `UIStateDumper` (UI-050), `WindowSnapshotter` and `AppControlProvider` (`ControlUIProvider`).
   - `AppOptions`: `--control-socket`, `--engine`, `--parent-pid` (exit when the parent dies); the socket is on by default in Debug (CTL-030).
   - File menu (UI-001): New, Open, Save, Save As and Export… call `ProjectStore.open/save`, which throw `notImplemented` until T-031.
   - An event pump: the window the Dispatcher is bound to drains through `dispatcher.drainEngineEvents()`; other windows drain through `engineSync.pollEvents()`.
6. **Verify and report:**
   - Run `scripts/test.sh` (use `DAW_SKIP_DEVICE_TESTS=1` if the CoreAudio sine test fails here).
   - Verify in attach mode with `daw_ui_state`, `daw_ui_perform` and `daw_ui_snapshot`. The running dawmcp is an old build, so this may need a restart or `dawctl --attach`.
   - `git merge main` once T-031 lands (the lead will say when).

## T-032 report
- Requirements: none complete yet. CTL-030 and CTL-031 are implemented but untested; UI-001, UI-003, UI-004, UI-050..052, CTL-011 and CTL-023 are not started.
- Tests: not run (stopped early). `swift build --target DAWControl` succeeds.
- RT violations: not measured (no RT code touched).
- Interface proposals: none. A spec 13 *Protocol details* clarification is still to be written: error code -32004 `attachFailed`, the `progress` notification, and `remote` errors.
- Discovered work:
  - (lead/user) Make `EmberStudioShell` a library product the app links, instead of compiling the shared sources. This changes the 01 Interfaces product list.
  - (T-031 follow-up, U) Wire File > Open/Save and the "recovery available" toast once `ProjectStore.open/save` exist.
- Notes for reviewer: the Dispatcher changes are additive; `projectOpen`/`projectSave` are untouched, as the lead asked.
