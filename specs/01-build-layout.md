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

## Interfaces
- Product names (consumed by all): `DAWEngine`, `DAWModel`, `DAWControl` (libraries); `dawctl`, `dawmcp`, `PluginScanner` (executables).
- Header visibility: Swift sees **only** `Sources/DAWEngine/include/daw/EngineFacade.h` and the POD types it includes (see 08-bridge-facade). The module map exposes nothing else.

## Status
| ID | status | test |
|---|---|---|
| BUILD-001..008 | done (T-001) | `scripts/test.sh` stages: manifest, submodule, swift-build-debug/release, swift-test, engine-objects, xcodebuild, app-bundle, arch, bootstrap. BUILD-004 mic prompt not yet exercised (needs recording) |
| BUILD-009 | todo (T-084) | |
