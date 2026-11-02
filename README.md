# Ember Studio

A linear-timeline DAW for macOS with audio and MIDI tracks.

- **Engine:** C++20, single audio thread, immutable render-graph snapshots swapped atomically, shared atomic parameter slots, plugin delay compensation.
- **Model:** UI-free Swift package (`DAWModel`) with command-pattern undo and a JSON project folder.
- **App:** SwiftUI shell with AppKit/CALayer/Metal canvases for the timeline and piano roll.
- **Plugins:** Audio Unit (v2/v3) and VST3 hosting, in-process, with autosave and recovery.
- **Agent-testable:** a JSON control protocol exposed as a CLI (`dawctl`) and an MCP server (`dawmcp`), so agents can build scenarios, render offline, analyze audio and drive the UI.

Target: macOS 15+, Apple Silicon only.

## Spec-driven

The spec is the source of truth and the code implements it.

- [`SPEC.md`](SPEC.md) is the index, the decision log (D-01…D-28) and the v1 non-goals.
- [`specs/`](specs/) holds one file per area. Requirements have stable IDs (`ENG-012`, `MIX-021`, …) that code, tests and commits cite.
- [`specs/90-tasks.md`](specs/90-tasks.md) has the task breakdown, milestones M1–M8 and current status.
- [`CLAUDE.md`](CLAUDE.md) has the instructions for coding agents. Work is orchestrated with Patchbay: a lead session on `main` and one worker per task, each in its own git worktree.

## Layout

```
Sources/
  DAWEngine/      C++20 real-time engine + narrow Swift facade
  DAWModel/       document model, commands, undo, persistence
  DAWControl/     JSON control protocol
  dawctl/         command-line client
  dawmcp/         MCP server (headless engine or attach to the running app)
  PluginScanner/  out-of-process AU/VST3 scanner
App/              thin Xcode project for the SwiftUI app
Tests/            unit, golden-render and RT-safety tests, plus fixtures
Vendor/           VST3 SDK (pinned submodule) and its SwiftPM shim
scripts/          bootstrap, test, dawmcp launcher, golden updates
specs/            the specification
docs/handover/    lead handover notes and task reports
```

## Getting started

Requires Xcode 16+ and Swift 6+ on an Apple Silicon Mac.

```sh
git clone --recurse-submodules https://github.com/afritzsch/ember-studio.git
cd ember-studio
scripts/bootstrap.sh       # checks the toolchain, checks out the pinned VST3 SDK
scripts/test.sh            # builds everything and runs every test stage
scripts/test.sh --no-xcode # quicker: skips the app build
```

Open `App/EmberStudio.xcodeproj` to run the app.

## Testing and verification

`scripts/test.sh` is the single entry point for agents and CI. Logs go to `.build/test-logs/`.

Debug builds trap allocations and locks on the audio thread, so real-time violations fail loudly. Golden-render tests compare offline renders against stored references. Use `scripts/update-goldens.sh` to regenerate them, and explain why in the commit.

The repo's [`.mcp.json`](.mcp.json) registers `dawmcp`, built from the current checkout. A typical agent check is `daw_test_fixture` → `daw_render_offline` → `daw_audio_analyze`, then confirm `daw_engine_telemetry.rtViolations == 0`. See [`specs/14-testing.md`](specs/14-testing.md) → *Agent verification recipe*.

## License

No license has been chosen yet. The vendored VST3 SDK is MIT-licensed by Steinberg (see `Vendor/vst3sdk/LICENSE.txt`).
