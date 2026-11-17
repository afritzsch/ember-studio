# 01 — Build & Repository Layout

**Depends on:** 00 · **Owns:** `Package.swift`, `Packages/*/Package.swift`, `App/EmberStudio.xcodeproj`, `Vendor/`, `scripts/`, CI config.

## Layout
```
macDAW/
  SPEC.md  CLAUDE.md  specs/
  Package.swift                 # root SwiftPM manifest (all packages as targets)
  Sources/
    DAWEngine/                  # C++20 — engine, DSP, I/O, plugin hosts
      include/daw/              # public headers (only EngineFacade.h + data types are visible to Swift)
    DAWModel/                   # Swift — document, Commands, undo, persistence, GraphDescription build
    DAWControl/                 # Swift — JSON control protocol (types + dispatcher)
    dawctl/                     # Swift executable — headless CLI
    dawmcp/                     # Swift executable — MCP stdio server
    PluginScanner/              # Swift/C++ executable — out-of-process plugin scan helper
  Tests/
    DAWEngineTests/             # C++ tests (via Swift Testing + C++ interop, or a C++ test target)
    DAWModelTests/
    DAWControlTests/
    GoldenTests/                # fixture projects + reference WAVs
  App/
    EmberStudio.xcodeproj       # thin app target: links the SwiftPM products
    EmberStudio/                # SwiftUI + AppKit sources
  Vendor/
    vst3sdk/                    # git submodule, pinned tag
  scripts/                      # bootstrap, golden update, lint
```

## Requirements

| ID | Requirement | Acceptance |
|---|---|---|
| BUILD-001 | Root `Package.swift` declares targets `DAWEngine` (C++20, `cxxLanguageStandard: .cxx20`), `DAWModel`, `DAWControl`, `dawctl`, `dawmcp`, `PluginScanner` and their test targets; platform `.macOS(.v15)`. | `swift build` succeeds on a clean clone after `scripts/bootstrap.sh` |
| BUILD-002 | Swift targets that import `DAWEngine` enable `.interoperabilityMode(.Cxx)`. | Compiles |
| BUILD-003 | VST3 SDK is a pinned git submodule under `Vendor/vst3sdk`, built as C++ target `VST3SDK` (hosting sources only: `pluginterfaces`, `base`, `public.sdk/source/vst/hosting`). | `DAWEngine` links it |
| BUILD-004 | `App/EmberStudio.xcodeproj` contains only the app target. It depends on the local package, has `NSMicrophoneUsageDescription`, hardened runtime, the `com.apple.security.device.audio-input` entitlement and **disabled library validation** (needed to load third-party plugins). | App launches and asks for mic permission on first record |
| BUILD-005 | Build configurations: `Debug` defines `DAW_RT_TRAP=1`; `Release` is `-O3` with the trap compiled out. | `#if DAW_RT_TRAP` paths present only in Debug |
| BUILD-006 | `scripts/bootstrap.sh` initializes submodules and verifies the Xcode ≥ 16 / Swift ≥ 6 toolchain. | Idempotent |
| BUILD-007 | `scripts/test.sh` runs `swift test` + golden tests + `xcodebuild build` for the app. This is the single CI entry point. | Exit code reflects failures |
| BUILD-008 | Arm64 only (`ARCHS=arm64`). | `lipo -info` shows arm64 |
| BUILD-009 | CI (GitHub Actions `macos-15` runner) runs `scripts/test.sh` on every push. | Green on main |

*BUILD-009 as built (T-084, DECISIONS phase 9 "T-084 CI scope").* `.github/workflows/ci.yml` runs on the `macos-15` runner (newest stable Xcode on the image), on every push to `main` and on `workflow_dispatch`; a newer push cancels the push run in progress. Each job calls `scripts/ci.sh <job>` through `ci-job.yml`, so it runs the same way locally:
- `test` (push and manual): a clean build, then `scripts/test.sh`. `ci.sh` removes every compiled output first (`swift package clean`, the app's derived data), so the "no warnings" check sees every file, not only recompiled ones (DW-005). Only fetched SwiftPM dependencies are cached, never build outputs.
- `asan`, `tsan`, `perf` (manual and weekly, Mondays): TEST-007 and TEST-008, see 14-testing → *CI jobs*.
- Logs (`.build/ci-logs/`, `.build/test-logs/`) are uploaded as artifacts for every job.

## Interfaces
- Product names (consumed by all): `DAWEngine`, `DAWModel`, `DAWControl` (libraries); `dawctl`, `dawmcp`, `PluginScanner` (executables).
- Header visibility: Swift sees **only** `Sources/DAWEngine/include/daw/EngineFacade.h` and the POD types it includes (see 08-bridge-facade). The module map exposes nothing else.

### Contract delta (T-065), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-065 scope" and phase 8 "Spec housekeeping", DW-015)
- Products add the library `PluginCatalog` (target `PluginCatalog`, `Sources/PluginScanner/Catalog`: discovery, the `plugins.json` cache, `ScannerLauncher`; plain Swift, no plugin code). The app links it (Xcode package product dependency) and so does the `EmberStudioShell` target (and its tests), whose plugin manager (12, UI-041) uses it. Package.swift appends those two target dependencies after the package declaration.
- The app embeds the `PluginScanner` executable as an auxiliary executable (`Contents/MacOS/PluginScanner`, found by `Bundle.url(forAuxiliaryExecutable:)`): the target's "Embed PluginScanner" script phase builds it with SwiftPM (same configuration, clean environment), copies it and signs it with the app's identity (hardened runtime). The phase needs `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the app target. `scripts/test.sh`'s manifest check doesn't list the new product yet (scripts are another task's).

## Status
| ID | status | test |
|---|---|---|
| BUILD-001..008 | done (T-001) | `scripts/test.sh` stages: manifest, submodule, swift-build-debug/release, swift-test, engine-objects, xcodebuild, app-bundle, arch, bootstrap. BUILD-004 mic prompt not yet exercised (needs recording) |
| BUILD-007 | done (T-001, T-019) | `scripts/test.sh` stages `swift-test` (all but GoldenTests) and `goldens` (fixture/reference pairing + GoldenTests real comparisons, DW-001) |
| BUILD-009 | done (T-084) | `.github/workflows/ci.yml` + `ci-job.yml` (macos-15, push to main + workflow_dispatch; test job = clean build (DW-005) + `scripts/test.sh` via `scripts/ci.sh test`); verified locally with `scripts/ci.sh test`. First hosted run checked by the lead after the phase-9 push |
