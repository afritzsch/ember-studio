# 03 — Time & Transport

**Depends on:** 02 · **Owns:** `Sources/DAWEngine/time/` (TempoMap, Transport), plus the Swift mirror `Sources/DAWModel/Time/`.

## Model
- **Tick**: `int64_t`, **960 PPQ**. All musical positions in the model are ticks.
- **Sample position**: `int64_t` at the current session rate.
- **TempoMap**: ordered tempo events `(tick, bpm)` (step changes only in v1; no ramps) and time-signature events `(tick, num, den)`. Event 0 is always at tick 0.
- Audio clips are tick-anchored: tempo changes move their **start** but never stretch them (D-06).

### Conversion semantics (clarified in T-007)
- `tickToSample(t)` is the exact position rounded **half away from zero** (`llround`). `sampleToTick(s)` is the last tick `t` with `tickToSample(t) ≤ s` (the tick sounding at `s`), so `tickToSample(sampleToTick(s)) ≤ s < tickToSample(sampleToTick(s) + 1)`.
- Positions before tick 0 (or sample 0) extrapolate the first tempo / time signature backwards. Ticks before 0 fall in bar 0, −1, …
- `BBT{bar, beat, tick}`: bar and beat are 1-based, `tick` is the offset inside the beat. The beat is one 1/den note (6/8 has six 480-tick beats).
- A time-signature event always starts a new bar. If it isn't on a bar line of the previous signature, that bar is cut short (and still counts as a bar).
- Validation rejects the map (no clamping): sample rate in 1 kHz…768 kHz, bpm in 1…1000, numerator 1…64, denominator a power of two from 1 to 64, both event lists non-empty, starting at tick 0, with strictly increasing ticks. Checks run in a fixed order (sample rate, then tempo events, then time signatures, each list event by event) and the first failure is reported.
- C++ and Swift use the same double arithmetic in the same order, and the C++ file disables FMA contraction, so both give bit-identical results (TIME-011).

### Transport semantics (clarified in T-087, DW-062)
- A segment's `[startTick, endTick)` is exactly the ticks whose events sound in it: the ticks `t` with `startSample ≤ tickToSample(t) < startSample + numFrames`.
- A block while stopped, or with 0 frames, has `numSegments == 0`; `seg[0]` still carries the current position (with `numFrames == 0`).
- The loop wraps only when playback crosses the loop end from before it. A playhead already at or past the loop end (e.g. after a locate there) plays on without wrapping.
- Loop wraps never reset nodes; timeline nodes handle them per segment (TIME-006). Only `locate()` while playing resets them (TIME-008).

## Requirements

| ID | Requirement | Acceptance |
|---|---|---|
| TIME-001 | `TempoMap::tickToSample(tick)` and `sampleToTick(sample)` are exact and drift-free. Precompute the cumulative sample offset (as `double`, rounded only on output) at each tempo event; conversion is O(log n). | Round-trip property test over 10k random positions at random tempos: error ≤ 1 sample |
| TIME-002 | Bars/beats: `tickToBBT` and `bbtToTick` respect time-signature events. | Unit table tests (4/4 → 7/8 → 3/4) |
| TIME-003 | TempoMap is immutable within a RenderGraph; a tempo edit publishes a new snapshot. The RenderGraph owns its map: GraphBuilder builds it from `GraphDescription.tempo` (05) at the engine rate, and `Engine::render` points `TransportBlock.tempo` at `RenderGraph::tempoMap()`. | — |
| TIME-004 | `Transport` state (RT-owned): `playing`, `recording`, `samplePos`, `loopEnabled`, `loopStart/End` (ticks). Commands from non-RT (`play`, `stop`, `locate(tick)`, `setLoop`) arrive via `SpscQueue<TransportCmd>` and are applied at block start. | Unit |
| TIME-005 | Per block the transport produces a `TransportBlock`: `startSample`, `startTick`, `numFrames`, `tempoAtStart`, and up to **2 segments** when a loop wrap occurs inside the block (each with its own sample/tick range and a `wrapped` flag). | Golden: loop-wrap mid-block is click-free and correct |
| TIME-006 | Nodes that read the timeline (clip players, MIDI sequencers, automation) must honor segments: they process segment 1, then reset per-segment position and process segment 2. | Clip player golden |
| TIME-007 | Tempo change inside a block: the block is processed at the tempo at block start. Event positions are still computed exactly through the TempoMap. | Documented limitation + test |
| TIME-008 | `locate()` while playing calls `reset()` on timeline nodes (clears voices and tails of clip players only; effects keep their tails). Loop wraps don't reset them (TIME-006 handles wraps). | Golden |
| TIME-009 | The transport reports the **playhead position** (sample + tick) through an atomic for UI readout, compensated for output latency (`displayPos = samplePos − outputLatency`). | — |
| TIME-010 | Metronome: built-in click node (accented downbeat), enabled per transport, sample-accurate from the tempo map. | Golden |
| TIME-011 | The Swift mirror `DAWModel.TempoMap` has identical semantics for UI and model use; a shared test vector file `Tests/Fixtures/tempo_vectors.json` is checked by both the C++ and Swift tests. | Both suites pass the same vectors |

## Interfaces (contract)
```cpp
namespace daw {
using Tick = int64_t; using SamplePos = int64_t;
constexpr int kPPQ = 960;
class TempoMap { public:
  SamplePos tickToSample(Tick) const; Tick sampleToTick(SamplePos) const;
  double bpmAt(Tick) const; BBT tickToBBT(Tick) const; Tick bbtToTick(BBT) const; };
struct TransportSegment { SamplePos startSample; Tick startTick; Tick endTick;
                          uint32_t frameOffset, numFrames; bool afterWrap; };
struct TransportBlock { bool playing, recording; uint8_t numSegments;
                        TransportSegment seg[2]; const TempoMap* tempo; };
}
```
```swift
public struct Tick: Hashable, Comparable, Codable { public var raw: Int64 }   // 960 PPQ
public struct TempoMap: Codable, Sendable { ... same API ... }
```

## Status
| ID | status | test |
|---|---|---|
| TIME-001, TIME-002, TIME-011 | done (T-007) | `DAWEngineTests/TempoMapTests` + `DAWModelTests/TempoMapTests` against shared `Tests/Fixtures/tempo_vectors.json` (incl. bit-exact vectors); conversions run inside RtScope with 0 violations |
| TIME-003 | done (T-008) | `TransportTests` (each block uses the map it's given; Engine points `TransportBlock.tempo` at the current graph's `tempoMap()`) |
| TIME-004 | done (T-008) | `TransportTests` (commands apply in order at block start, validated, full queue refuses; several producers, each applied once). Producers serialize on a send-side mutex; queue holds 256 |
| TIME-005 | partial (T-008) | `TransportTests` (one segment without loop; wrap mid-block → 2 segments; wrap at block boundary; random block sizes vs frame model; edge cases). Golden `loop_wrap_midblock` pending (T-019) |
| TIME-006 | done (T-008) | `TransportTests` (test timeline node through Engine places every event exactly; `SegmentContinuity`). Helpers in `time/TransportSegments.h`; clip player golden with T-013 |
| TIME-007 | done (T-008) | `TransportTests` (block spanning a tempo change runs at start tempo; events exact) |
| TIME-008 | partial (T-008) | `TransportTests` (locate while playing resets timeline nodes once; effects keep state). Loop wraps don't reset (TIME-006 handles them). Golden pending (T-019) |
| TIME-009 | done (T-008) | `TransportTests` (latency-compensated playhead, clamped at play start, unwrapped after wrap; seqlock, never torn) |
| TIME-010 | done (T-024) | `MetronomeTests` (clicks sample-exact over tempo changes and 3/4 → 4/4 → 6/8, accented bar starts, random blocks; on switch + levels latched per click; locate cuts a click with a 64-frame fade; loop wrap mid-block; scheduled graph-latency ahead); golden `metronome_click` + `MetronomeGoldenTests` (every onset exact). Project-level toggle/command/UI: T-026 |
| TIME-* (rest) | todo | |
