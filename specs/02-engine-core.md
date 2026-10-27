# 02 — Engine Core

**Depends on:** 00, 01 · **Owns:** `Sources/DAWEngine/core/` (Node, RenderGraph, Engine, ParamSlot, reclaim, SpscQueue, RT trap, telemetry).

The engine is a set of **node instances** connected by an immutable **RenderGraph** snapshot. The audio thread renders the current snapshot. Non-RT threads build new snapshots and publish them atomically. Continuous values travel through **param slots** that bypass snapshots.

## Concepts
- **NodeID** (`uint64_t`): stable identity assigned by the model; it survives snapshots.
- **Node instance**: owns DSP state (filter memory, voices, plugin instance). Node instances are **shared across snapshots** through a `NodePool` keyed by NodeID, so snapshots never re-instantiate plugins or reset DSP state. A node is destroyed only when no live snapshot references it, and always on `daw.reclaim`.
- **RenderGraph**: an immutable plan with node pointers in topological order, buffer assignments, PDC delay lines, per-node input/output buffer indices, clip/event data for the playback window, and param slot pointers.
- **ParamSlot**: `struct ParamSlot { std::atomic<float> value; std::atomic<uint32_t> generation; }`, allocated in a `ParamSlotTable` that never shrinks during a session (indices stay stable).

## Requirements

### Node API
| ID | Requirement | Acceptance |
|---|---|---|
| ENG-001 | `class Node` with non-RT `prepare(const PrepareInfo&)` (sample rate, max block size, channel layout) and `release()`, and RT `process(ProcessContext&, NodeIO&)` and `reset()`. | Unit test with a mock node |
| ENG-002 | `uint32_t latencySamples() const` (non-RT readable, may change only after `prepare`). | Used by MIX PDC |
| ENG-003 | `NodeIO` provides input/output `AudioBufferView` (non-interleaved float32 channels, `numFrames`), `const MidiEventSpan in`, `MidiEventWriter out`, and sidechain `AudioBufferView` (may be empty). | — |
| ENG-004 | Max block size 4096 frames. Nodes must handle any `numFrames ≤ maxBlock`, including 0. | Fuzz test with random block sizes |

### Snapshots
| ID | Requirement | Acceptance |
|---|---|---|
| ENG-010 | `Engine::publish(std::unique_ptr<RenderGraph>)` is callable from any non-RT thread. It swaps an `std::atomic<RenderGraph*>`, and the previous graph is enqueued for retirement. | Stress test: 10k publishes during render, no crash or leak (ASan/LSan) |
| ENG-011 | The audio thread loads the current graph pointer **once per block** (acquire) and uses it for the whole block. | — |
| ENG-012 | Retirement is epoch-based: the audio thread publishes `renderEpoch` after each block; `daw.reclaim` frees graph *G* only when `renderEpoch` has advanced past the epoch in which *G* was replaced. | Test with an artificial audio-thread stall: no use-after-free |
| ENG-013 | When a node is newly added or its config changes, the compile thread calls `prepare()` **before** the node is published. Node removal → `release()` + destruction happen on reclaim. | — |
| ENG-014 | The audio thread never frees memory. All RT-retired objects go through `RetireQueue` (SPSC, RT → reclaim). | RT trap test |
| ENG-015 | When no graph is published, render outputs silence. | Unit |

### Param slots
| ID | Requirement | Acceptance |
|---|---|---|
| ENG-020 | `ParamSlotTable` preallocates N slots (default 65,536). `allocate()`/`free()` are non-RT; slots are referenced by `ParamID` (uint32). | — |
| ENG-021 | UI/model writes use `slot.value.store(v, relaxed)`. Nodes read once per block. | — |
| ENG-022 | Nodes ramp linearly from the previous block's value to the new value across the block (`ParamSmoother`), so there is no zipper noise. | Golden: gain step 0→1 shows a linear ramp over one block |
| ENG-023 | Snapshot `NodeConfig`s reference ParamIDs, not values. Changing a param value never triggers a snapshot. | Test: fader sweep → 0 publishes |

### RT safety trap (Debug)
| ID | Requirement | Acceptance |
|---|---|---|
| ENG-030 | With `DAW_RT_TRAP=1`, a thread-local flag `inRealtimeContext` is set during `render()`. | — |
| ENG-031 | Interpose `malloc/free/calloc/realloc/posix_memalign` and `pthread_mutex_lock`, and count calls made while the flag is set. | Test: a deliberately allocating node increments the counter |
| ENG-032 | Violations are counted in telemetry (`rtViolations`) with the first offending backtrace captured off-thread. They never abort by default; `DAW_RT_TRAP_ABORT=1` env aborts. | — |
| ENG-033 | Allowlist: CoreAudio-internal allocations during device start are excluded by enabling the flag only inside the engine's own render scope. | — |

### Engine entry points
| ID | Requirement | Acceptance |
|---|---|---|
| ENG-040 | `Engine::render(RenderTarget&, uint32_t numFrames)` is the single RT entry point, called by the device driver or the offline driver (see 04). | — |
| ENG-041 | Render order: load graph → advance transport (03) → for each node in topo order: gather inputs (sum + PDC delay), process → write master to target → publish telemetry → bump epoch. | Golden tests |
| ENG-042 | Denormals are flushed to zero (FPCR FZ bit on arm64) at the start of every render. | Test with a decaying IIR |

### Telemetry
| ID | Requirement | Acceptance |
|---|---|---|
| ENG-050 | `TelemetrySnapshot` (atomics, read without locks): DSP load % (render time / block duration, EMA), xrun count, rtViolations, current graph epoch, per-node latency, total output latency, per-meter peak/RMS. | Read via facade |
| ENG-051 | Render time is measured with `mach_absolute_time` at block start and end. | — |

### Utilities
| ID | Requirement |
|---|---|
| ENG-060 | `daw::SpscQueue<T, N>`: lock-free, power-of-2 capacity, trivially-copyable T, wait-free push/pop. |
| ENG-061 | `daw::AudioBufferPool`: preallocated per-graph scratch buffers; the RenderGraph owns its pool. |

## Interfaces (contract)
```cpp
namespace daw {
using NodeID = uint64_t; using ParamID = uint32_t;
struct PrepareInfo { double sampleRate; uint32_t maxBlock; uint32_t numIn, numOut; };
struct ProcessContext { uint32_t numFrames; double sampleRate;
                        const TransportBlock& transport; // see 03
                        const ParamSlotTable& params; };
class Node {
public:
  virtual ~Node() = default;
  virtual void prepare(const PrepareInfo&) = 0;            // non-RT
  virtual void release() {}                                // non-RT
  virtual void reset() DAW_RT {}                           // RT (transport jump)
  virtual void process(ProcessContext&, NodeIO&) DAW_RT = 0;
  virtual uint32_t latencySamples() const { return 0; }
};
class Engine {
public:
  void publish(std::unique_ptr<RenderGraph>);              // non-RT
  void render(RenderTarget&, uint32_t numFrames) DAW_RT;
  ParamSlotTable& params();
  const Telemetry& telemetry() const;
  NodePool& nodes();                                       // non-RT
};
}
```
`RenderGraph` is built only by `GraphBuilder` (05-mixer-routing-pdc).

## Status
| ID | status | test |
|---|---|---|
| ENG-060 | done (T-002) | `CoreUtilsTests` (SpscQueue cases) |
| ENG-061 | done (T-002) | `CoreUtilsTests` (AudioBufferPool cases); "RenderGraph owns its pool" verified when RenderGraph lands (T-004/T-012) |
| ENG-030..033 | done (T-003) | `RtTrapTests` (Debug only). Allocations caught via libmalloc `malloc_logger`, locks via GOT rebinding — not dyld `__interpose` (see DW-012). Not wired into render/telemetry yet (T-004/T-006) |
| ENG-020, 021 | done (T-005) | `ParamSlotTableTests`, `ParamSlotTests`, `ParamRealtimeTests` (RtScope count 0). `allocate(count)` returns a contiguous range; `generation` counts writes |
| ENG-022 | partial (T-005) | `ParamSmootherTests` (0→1 step = linear ramp for every block size 0..4096); golden pending (T-019) |
| ENG-023 | partial (T-005) | `ParamSnapshotIsolationTests` (sweep leaves node config unchanged); "fader sweep → 0 publishes" pending Engine + GraphBuilder (T-012/T-014) |
| ENG-* (rest) | todo | |
