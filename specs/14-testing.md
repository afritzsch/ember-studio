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
| `gain_ramp_smoothing` | M1 | ENG-022 |
| `pan_law` | M2 | MIX-005 |
| `bus_send_sum` | M2 | MIX-004/007 |
| `pdc_alignment_null` | M2 | MIX-021/023 (with FakeLatencyNode) |
| `clips_fades_tempo_change` | M3 | TIME-001, DSP-001 |
| `loop_wrap_midblock` | M3 | TIME-005 |
| `sampler_pitch` | M4 | DSP-021 |
| `midi_locate_no_stuck_notes` | M4 | DSP-003 |
| `record_loopback_alignment` | M5 | REC-003 |
| `comp_crossfade` | M8 | REC-032 |
| `vst3_again_gain` | M6 | PLUG-011 |
| `automation_ramp` | M7 | AUTO-002 |
| `sidechain_compressor` | M7 | DSP-031, MIX-008 |
| `reverb_determinism` | M7 | IO-011 |

## Agent verification recipe
When an agent finishes an audio-affecting task it must:
1. Write or extend a golden fixture script.
2. Run it through `dawmcp` (`daw_test_fixture` → `daw_render_offline` → `daw_audio_analyze`) and sanity-check the numbers against expectations stated in the spec (levels, frequencies, alignment).
3. Check `daw_engine_telemetry.rtViolations == 0`.
4. For UI tasks: attach mode → `daw_ui_perform` → `daw_ui_state` assertions → `daw_ui_snapshot` for visual review.

## Status
| ID | status | test |
|---|---|---|
| TEST-* | todo | |
