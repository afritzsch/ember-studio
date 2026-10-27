# 05 — Mixer, Routing & Plugin Delay Compensation

**Depends on:** 02 · **Owns:** `Sources/DAWEngine/graph/` (GraphDescription consumer, GraphBuilder, topo sort, PDC, mixer node types).

## Topology
```
[Track source: AudioClipPlayer | MidiClipPlayer→Instrument]
   → [Insert chain: effects/plugins…]
   → [Channel strip: gain, pan, mute/solo, meter]
   → output: Bus | Master
   → sends (pre/post fader) → Bus
Bus = Insert chain → Channel strip → output (Bus | Master)
Master = Insert chain → Channel strip → device/offline target
Sidechain: any track/bus (pre- or post-fader) → a plugin's sidechain input
```

## Requirements

| ID | Requirement | Acceptance |
|---|---|---|
| MIX-001 | `GraphBuilder::build(const GraphDescription&, NodePool&, ParamSlotTable&) → Result<unique_ptr<RenderGraph>>` runs on `daw.compile`. It is the only producer of RenderGraphs. | Unit |
| MIX-002 | Topological sort (Kahn). A cycle returns `Error::cycle` with the offending NodeIDs. The model should have prevented it (MODEL-030), so this is a defensive check. | Unit with crafted cyclic description |
| MIX-003 | Buffer allocation: assign scratch buffers by liveness (graph coloring over the topo order) to minimize memory. | Test: 100-track project uses ≤ (max fan-in + depth) buffers |
| MIX-004 | Summing: multiple edges into one input are summed. Stereo throughout v1 (mono sources are duplicated to L/R at the clip player). Ports in v1: `audio` edges use `toPort` 0 (the node's main input); `sidechain` edges feed the node's sidechain input (`toPort` 0); other `toPort` values are rejected with `invalidArgument`. | Golden |
| MIX-005 | Channel strip: gain (−∞..+12 dB, slot), pan (−1..1, slot, **−3 dB constant-power pan law**), mute, solo, phase invert, peak + RMS meter (300 ms window) into telemetry. | Golden: pan hard-left/center/right levels |
| MIX-006 | Solo logic: if any track is soloed, non-soloed tracks are muted, except tracks feeding a soloed bus and buses that soloed tracks feed (solo-in-place). Computed in the builder, not at RT. Mute/solo are slots read per block to avoid rebuilds. | Unit truth table |
| MIX-007 | Sends: per-send level slot, pre/post-fader tap, target bus. | Golden |
| MIX-008 | Sidechain: an edge type `sidechain` into a node's sidechain input, with pre/post-fader tap. | Golden with built-in compressor (06) |
| MIX-009 | Master: final node, writes to the RenderTarget, with an optional hard-clip safety limiter (off by default; on in tests to detect overs). The limiter is switched by the master node's first param slot (on when ≥ 0.5; a master with `numParams` 0 never clips); clipped samples (and NaNs, which become 0) are counted as overs. | — |

### PDC
| ID | Requirement | Acceptance |
|---|---|---|
| MIX-020 | Each node's latency comes from `Node::latencySamples()`. The builder computes `pathLatency(node)` = max over inputs of (input path latency) + own latency. | Unit |
| MIX-021 | At every merge point (summing input, sidechain input), shorter paths get a `DelayLine` inserted so all arrivals align to the max. | Golden null test: track A dry vs track B through a 1000-sample latency node → aligned |
| MIX-022 | Delay lines are owned by the RenderGraph and preallocated. On rebuild, delay-line contents for unchanged edges are **carried over** to avoid glitches (keyed by edge ID). | Test: rebuild during playback without discontinuity |
| MIX-023 | Total graph latency is reported. Clip players are scheduled `totalLatency` samples early, so playback stays aligned with the timeline (latency compensation at the source). | Golden: click on beat 1 appears at exact sample with a latent master plugin |
| MIX-024 | When a plugin reports a latency change, schedule a rebuild (non-RT) and notify via event. | — |
| MIX-025 | Automation and param changes are not latency-compensated in v1 (documented limitation). | — |

## Interfaces (contract)
`GraphDescription` is plain data produced by `DAWModel` and passed through the facade (08). Defined in `include/daw/GraphDescription.h`:
```cpp
namespace daw {
enum class NodeKind : uint16_t { audioClipPlayer, midiClipPlayer, sampler, channelStrip, gain, eq, compressor,
                                 delay, reverb, metronome, auPlugin, vst3Plugin, master, bus };
struct NodeDesc { NodeID id; NodeKind kind; uint32_t configVersion; /* bump → re-prepare */
                  ParamID firstParam; uint32_t numParams; std::string configJSON; /* kind-specific, non-RT */ };
enum class EdgeKind : uint8_t { audio, midi, sidechain };
struct EdgeDesc { uint64_t edgeID; NodeID from; NodeID to; EdgeKind kind; uint8_t toPort; };
struct ClipDesc { NodeID player; uint64_t clipID; Tick start; Tick length; uint64_t assetID;
                  int64_t sourceOffsetSamples; float gain; Tick fadeIn, fadeOut; /* audio */ };
struct NoteDesc { NodeID player; Tick start; Tick length; uint8_t pitch, velocity, channel; };
struct TempoPointDesc { Tick tick; double bpm; };              // mirrors daw::TempoEvent (03)
struct TimeSigDesc    { Tick tick; int32_t num; int32_t den; }; // mirrors daw::TimeSigEvent (03)
struct TempoMapDesc   { std::vector<TempoPointDesc> tempos; std::vector<TimeSigDesc> timeSigs; };
struct GraphDescription { uint64_t version; std::vector<NodeDesc> nodes; std::vector<EdgeDesc> edges;
                          std::vector<ClipDesc> audioClips; std::vector<NoteDesc> notes;
                          TempoMapDesc tempo; NodeID master; };
}
```

`TempoMapDesc` (approved T-012) uses its own POD event structs rather than 03's `TempoEvent`/`TimeSigEvent`, because `include/daw/` is what Swift sees (01 Interfaces) and can't include `time/TempoMap.h`. For the same reason, the header redeclares `NodeID`, `ParamID` and `Tick` as identical aliases. The desc carries no sample rate: `GraphBuilder` builds the `TempoMap` at the rate it prepares nodes at (fails with `invalidArgument` on an invalid map), and the RenderGraph owns it (`RenderGraph::tempoMap()`, TIME-003).

## Status
| ID | status | test |
|---|---|---|
| MIX-001 | done (T-012) | `GraphTests` (builds + renders, prepare before publish; `GraphCompiler` on daw.compile coalesces and keeps the current graph on failure; malformed descriptions rejected before the pool is touched) |
| MIX-002 | done (T-012) | `GraphTests` (crafted cycle → NodeIDs; random DAGs). No `ErrorCode::cycle` yet: returns `invalidArgument` "cycle: <ids>" (DW-050) |
| MIX-003 | done (T-012) | `GraphTests` (100-track project ≤ max fan-in + depth; random mixer projects). Bound holds for mixer-shaped graphs, not arbitrary dense DAGs |
| MIX-004 | partial (T-012) | `GraphTests` (summing, sidechain port, random DAG sums exact); golden `bus_send_sum` pending (T-019) |
| MIX-009 | done (T-012) | `GraphTests` (master last; limiter off by default, clips + counts overs when on) |
| MIX-* (rest) | todo | |
