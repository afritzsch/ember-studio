# 14 — Testing Strategy

**Depends on:** 01, 13 · **Owns:** `Tests/`, `scripts/test.sh`, `scripts/update-goldens.sh`.

## Layers
| Layer | Where | What |
|---|---|---|
| Unit (C++) | `Tests/DAWEngineTests` | TempoMap, SpscQueue, GraphBuilder, PDC, DSP math, snapshot reclaim |
| Unit (Swift) | `Tests/DAWModelTests`, `DAWControlTests` | Commands + inverses, undo, validation, persistence, protocol |
| Golden render | `Tests/GoldenTests` | Fixture projects → offline render → compare to reference WAV |
| RT safety | all engine tests in Debug | RT trap counter must be 0 |
| Agent verification | `dawmcp` / `dawctl script` | Agents build scenarios, render, analyze and check numerically; attach mode for UI |

## Requirements
| ID | Requirement | Acceptance |
|---|---|---|
| TEST-001 | Golden fixtures are `dawctl` **scripts** (`Tests/GoldenTests/fixtures/<name>.jsonl`), not binary projects, so they are reviewable and survive format migrations. Each script builds a project via commands and calls `render.offline`. | — |
| TEST-002 | References: `Tests/GoldenTests/references/<name>.wav` (32f). Compare with `audio.compare`: pass if null residual ≤ −100 dBFS (bit-exact expected on the same machine; tolerance covers libm differences). | — |
| TEST-003 | `scripts/update-goldens.sh <name>` regenerates a reference. The diff summary (`audio.analyze` before/after) must be pasted in the commit message. Agents **must not** update goldens to make a failing test pass without stating why in the commit. | Policy |
| TEST-004 | Test-only nodes: `SineNode`, `ImpulseNode`, `FakeLatencyNode(n)`, `AllocatingNode` (to test the trap), `NaNNode`. Registered only in test builds. | — |
| TEST-005 | `FakeDeviceDriver`: drives `Engine::render` on a timer thread with configurable latency, loopback (output → input with N samples delay), and scripted events (device loss, rate change). | Used by IO and REC tests |
| TEST-006 | Property/fuzz tests: random block sizes, random command sequences + undo, random routing edits (always acyclic after validation), random locates (no stuck notes). | — |
| TEST-007 | Sanitizers: a CI job runs C++ tests with ASan+UBSan, and a stress job with TSan on snapshot publish/reclaim. | — |
| TEST-008 | Performance smoke: 64 tracks × (EQ + Comp) + 8 buses with reverb at 48k/128 frames renders offline at ≥ 20× realtime on Apple Silicon; record the result in telemetry output. | Fails if < 10× |

## Minimum golden set (grows per milestone)
| Fixture | Milestone | Checks |
|---|---|---|
| `sine_through_graph` | M1 | Engine skeleton, master output |
| `wav_playback_resampled` | M1 | 44.1k asset in a 48k session |
| `gain_ramp_smoothing` | M1 | ENG-022 (the step is an automation hold step inside the render since T-089, DW-063) |
| `pan_law` | M2 | MIX-005 |
| `bus_send_sum` | M2 | MIX-004/007 |
| `pdc_alignment_null` | M2 | MIX-021/023 (with FakeLatencyNode) |
| `send_ramps` | M2 | MIX-007, ENG-022 (send level ramps, automation hold steps inside the render; the send-mute ramp is in `SendTests` "gainNodeLevel"/"mutedWithTrack" since T-089) |
| `clips_fades_tempo_change` | M3 | TIME-001, DSP-001 |
| `loop_wrap_midblock` | M3 | TIME-005 |
| `loop_short_multiwrap` | M3 | TIME-005, DW-125 (loop shorter than a block, several wraps per block) |
| `locate_reset` | M3 | TIME-008 (clip player reset at a render start), DW-063 (the render resets the effect too). Live locate keeping effect state: `TransportTests` "locateFlagsReset", `OfflineResetTests` "resetsEveryNode" |
| `metronome_click` | M2 | TIME-010, DSP-011 |
| `sampler_pitch` | M4 | DSP-021 |
| `midi_locate_no_stuck_notes` | M4 | DSP-003, DW-103 (chase at a render start), DW-063 (no held note survives a render start). Live locate note-off and release: `MidiClipPlayerTests` "locateAndStop", "noStuckNotesFuzz" |
| `midi_loop_wrap` | M4 | DSP-003 (loop-wrap note-offs, chase at the loop start: DW-101, DW-103) |
| `record_loopback_alignment` | M5 | REC-003 |
| `comp_crossfade` | M8 | REC-032 |
| `vst3_again_gain` | M6 | PLUG-011 |
| `automation_ramp` | M7 | AUTO-002 |
| `sidechain_compressor` | M7 | DSP-031, MIX-008 |
| `reverb_determinism` | M7 | DSP-033, IO-011 |
| `automation_loop_wrap` | M7 | AUTO-003 (strip/send jump at the wrap frame; the other built-ins are DW-232) |
| `delay_tempo_sync` | M7 | DSP-032 |
| `eq_response` | M7 | DSP-030 (impulse response vs analytic RBJ ≤ 0.01 dB: bell boost/cut, shelves, HP/LP slopes), DSP-040 (exact 0 tail) |
| `effects_silence_nan_guard` | M7 | DSP-040 (EQ, comp, delay, reverb: tails end in exact 0; NaN in → silence, `nanBlocks` counted, DW-142) |
| `builtin_bypass_null` | M7 | PLUG-018 for the built-ins (bypassed EQ/comp/delay/reverb null against the dry signal) |
| `effect_param_steps` | M7 | ENG-022, AUTO-002 on effect params (EQ gain, comp makeup, delay mix, reverb mix ramp over one block) |
| `m7_scene` | M7 | DSP-030..033, MIX-007, AUTO-002, IO-011 (EQ → comp → send → reverb bus, delay insert, two lanes; bit-identical on fresh engines) |

## Agent verification recipe
When an agent finishes an audio-affecting task it must:
1. Write or extend a golden fixture script.
2. Run it through `dawmcp` (`daw_test_fixture` → `daw_render_offline` → `daw_audio_analyze`) and sanity-check the numbers against expectations stated in the spec (levels, frequencies, alignment).
3. Check `daw_engine_telemetry.rtViolations == 0`.
4. For UI tasks: attach mode → `daw_ui_perform` → `daw_ui_state` assertions → `daw_ui_snapshot` for visual review.

Notes (DW-135, DW-122):
- Fixtures with `@node` test nodes (e.g. FakeLatencyNode, SineNode) render silence through `dawctl`/`dawmcp`: only the GoldenTests harness registers the test-only nodes. Check those fixtures with `swift test --filter GoldenTests`.
- Real-device switches: `DAW_SKIP_DEVICE_TESTS=1` skips the CoreAudio device runs; `DAW_AUDIBLE_DEVICE_TEST=1` plays IO-001's sine audibly; `DAW_DEVICE_INPUT_TESTS=1` runs the input/duplex device checks (IO-004); `DAW_DEVICE_EVENT_TESTS=1` runs the real sample-rate flip (IO-020). The opt-in ones are off by default.

## C++ unit tests
Engine tests are Swift Testing suites in `Tests/DAWEngineTests` that call engine C++ directly through the test-only module `DAWEngineTestSupport` (`Tests/DAWEngineTestSupport`, T-085). Nothing test-only goes into `Sources/DAWEngine`: no test functions, no `extern "C"` hooks, no deliberate violations.

- **Exposing a header.** Add the engine header to `Tests/DAWEngineTestSupport/include/module.modulemap` (path relative to that file) and `import DAWEngineTestSupport`. Engine headers include each other rooted at `Sources/DAWEngine` (`#include "core/RtTrap.h"`). The public `DAWEngine` module map stays facade-only (01 Interfaces).
- **Prefer Swift.** Call `daw::` types from Swift when interop allows it. Put small inline adapters in a test-support header, e.g. `daw::testing::makeTempoMap` to unwrap `Result` (see DW-022).
- **When it has to be C++.** Use C++ for templates, non-movable or move-only types, threads, `RtScope`, and `DAW_RT` bodies (only the C++ compiler checks them). Declare a `daw::testing::` function in `include/<Area>TestSupport.h` or `<Area>Checks.h` and define it in a `.cpp` next to `include/`. That target builds with the engine's flags, so `-Wfunction-effects -Werror` and `DAW_RT_TRAP` match the engine. Multi-assert C++ bodies return `daw::testing::CheckResult` (`Checks.h`, `DAW_CHECK`) and Swift asserts them with `expectPasses(...)`.
- **RT "0 violations" checks** (CONV §5.3) use the scope's own count, never the process-wide one. Other suites provoke violations in parallel, and only the scope's count is immune to them:
  ```cpp
  uint64_t fooViolations(Foo& foo) {   // DAWEngineTestSupport
      RtScope scope;
      foo.process();                    // the DAW_RT path under test
      return scope.violations();        // this thread, this scope only (DW-019)
  }
  ```
  ```swift
  #if DEBUG  // the trap exists only in Debug (BUILD-005)
  #expect(daw.RtTrap.install())
  #expect(daw.testing.fooViolations(&foo) == 0)
  #endif
  ```
  Work on another thread (e.g. a render thread) opens its own `RtScope` there and reports that scope's count.
- **Process-wide trap state.** Deliberate violations and anything that reads or resets `violationCount()`, `firstViolation()` or `resetViolations()` belong only in the serialized `RtTrapTests` suite. Nest new suites inside it (`extension RtTrapTests { @Suite struct … }`) and use the probes in `RtTrapTestSupport.h`.

## Status
| ID | status | test |
|---|---|---|
| TEST-005 | done (T-050) | `FakeDeviceDriverTests` (exact cycle counts in buffer-size blocks, latency published, stop/restart; real-time pacing vs as-fast-as-possible; loopback N frames; scripted rate change / overload / device loss on exact frames via the `io/DeviceNotification.h` seam for T-051; a realtime EngineFacade on `FakeDeviceDriverAdapter`; 0 RT violations) |
| TEST-001 | done (T-019) | `GoldenRenderTests` (one case per `fixtures/*.jsonl`, run in-process through `ControlScript` + `Dispatcher.handle(_:)`); `GoldenHarnessTests` (directives, script failures). Fixture directives `# @node` (test-only node under a real kind) and `# @expect` (audio.analyze assertions) |
| TEST-002 | done (T-019) | `GoldenRenderTests` (audio.compare ≤ −100 dBFS, equal length); "referencesMatchFixtures"; `GoldenHarnessTests` "mismatchFails". M1 goldens: `sine_through_graph`, `gain_ramp_smoothing`, `wav_playback_resampled`. M2 (T-025): `pan_law`, `bus_send_sum`, `pdc_alignment_null`, `send_ramps`, each with a `GoldenReferenceTests` check of the reference against the spec numbers; `@expect` takes `"channel"`. M4 (T-044): `sampler_pitch`, `midi_loop_wrap`, `midi_locate_no_stuck_notes` (`M4GoldenReferenceTests`, per-sample oracle from 06). M7 (T-077): `eq_response`, `effects_silence_nan_guard`, `builtin_bypass_null`, `effect_param_steps`, `m7_scene` (`M7GoldenTests`, oracles from 06; `m7_scene` bit-identical on two fresh engines) |
| TEST-003 | done (T-019) | `scripts/update-goldens.sh` (prints the audio.analyze before/after summary; refuses fixtures that fail or miss their `@expect`s); `GoldenHarnessTests` "missingReferenceFails" |
| TEST-004 | done (T-019) | `TestNodeTests` (SineNode, ImpulseNode, FakeLatencyNode, NaNNode, registration); `AllocatingNodeTests`; registered only through `FacadeOptions::registerNodes` in test builds |
| TEST-* (rest) | todo | |
