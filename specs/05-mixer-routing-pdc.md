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
| MIX-005 | Channel strip: gain (−∞..+12 dB, slot), pan (−1..1, slot, **−3 dB constant-power pan law**), mute, solo, phase invert, peak + RMS meter (300 ms window) into telemetry. Param slots relative to `firstParam`: gain 0 (linear), pan 1, mute 2, phase 3 (`numParams` ≥ 4). Mute and phase are switches, on at ≥ 0.5; every change ramps over one block (ENG-022): mute fades out/in, phase passes linearly through 0. Phase applies to the strip's input, before gain and pan. Solo has no slot: the model resolves it into each strip's mute slot (MIX-006). The meter is post-fader and post-mute. | Golden: pan hard-left/center/right levels |
| MIX-006 | Solo logic: if any track is soloed, non-soloed tracks are muted, except tracks feeding a soloed bus and buses that soloed tracks feed (solo-in-place). Computed in the model (`GraphDescriptionBuilder`, T-016), not at RT. Solo has no slot: the model resolves mute + solo into each strip's mute slot and every send's mute slot (MIX-007), written with `setParam`, so mute/solo changes never rebuild. | Unit truth table |
| MIX-007 | Sends: per-send level slot, pre/post-fader tap, target bus. A send is a `NodeKind::gain` node on an edge into the target bus, with two slots: level 0 (linear, 0..+12 dB) and mute 1 (on at ≥ 0.5); both ramp over one block (ENG-022). A plain gain node may have only the level slot (`numParams` 1) and is never muted; a send has `numParams` 2. The tap is where the send's incoming edge starts. **Post-fader:** strip → send → bus, so the send follows the strip's gain, pan, mute and phase. **Pre-fader:** the node that feeds the strip (last insert, else the clip player or instrument) → send → bus, so the send taps the strip's input and ignores its gain, pan and phase. **Mute (user decision):** a muted track, whether muted by hand or by solo (MIX-006), silences **all** of its sends, pre-fader included, so solo never leaks through a send. The model writes the track's resolved mute into the strip's mute slot (MIX-005) and into every one of its sends' mute slots; a send's level slot keeps its value while muted. Level and mute changes are slot writes, never rebuilds. | Golden |
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

#### PDC semantics (clarified in T-021)
- **Path latency** (MIX-020) runs over all incoming edges, MIDI included: a node's arrival is the max path latency of its inputs. Every edge into a node, MIDI included (T-045), is delayed by `arrival(to) − pathLatency(from)`, so MIDI lines up with audio at the instrument. The graph latency is the master's path latency; with every merge aligned, every path from an input-less node to the master adds up to exactly that.
- **Delay lines** (MIX-021/022) sit on the feed of the delayed edge (`RenderGraph::feed`), never on a direct read. The builder keeps them per edge ID, and the next graph gets the *same* line for an edge with the same endpoints whose new delay still fits, so contents carry over with no copy. One graph renders per block, so only one thread touches a line at a time. A delay that outgrows its line gets a new, silent line; the latency change glitches anyway.
- **Source pre-roll** (MIX-023) lives in `Engine::render`, not in each player. The transport position is what the graph outputs in that block: offline block *i* is position `from + i`, and the TIME-009 playhead subtracts only the device latency. Timeline nodes (audio/MIDI clip players, metronome) get a TransportBlock laid out `latency` samples ahead, using the transport's loop rule. Every other node gets the transport's block. Each run of playback (play from stopped, or a locate while playing) first renders `latency` frames in chunks of up to `maxBlock` and discards their output. That fills the delays, so the first audible frame is the start position. The cost is a CPU spike in that first block when the latency is large. If the latency changes mid-run, timeline nodes jump by the difference with no new pre-roll.
- **Latency changes** (MIX-024): node factories get a `LatencyReporter` (`NodeCreateInfo::latency`), and a node calls `changed()` from a non-RT thread. `GraphCompiler` then rebuilds its last good description on `daw.compile`, keeping the same instances, and queues a `LatencyEvent` (`takeEvents()`). The facade doesn't expose that event yet.
- **Telemetry**: `Engine::render` copies the graph's latent-node table and `graphLatency` into `Telemetry` whenever the rendered graph changes.

#### MIDI routing (clarified in T-045, DW-099)
- **Storage.** A node with an outgoing MIDI edge writes into `NodeIO::midiOut` with room for `GraphBuilder::kMidiCapacity` (1024) events per block. The storage is allocated when the RenderGraph is created (never on the audio thread) and every graph gives the node the same capacity, so it never shrinks between blocks, even across a snapshot swap: a node that keeps room for its note-offs (MidiClipPlayer, 06 "MidiClipPlayer semantics") can rely on it, and no note hangs. A node without outgoing MIDI edges gets a writer of capacity 0.
- **Delivery (pull).** Right before a node runs, its `midiIn` is gathered from the nodes upstream of its MIDI edges, which ran earlier in the block. One undelayed MIDI edge: `midiIn` is the upstream writer's `written()` span itself, no copy. Several: a k-way merge in frame order, stable for equal frames (description order of the edges), into storage of the node's own sized for everything its inputs can deliver in one block, so a merge never drops. Fan-out is free: every consumer reads the same span. Converging edges mean converging MIDI streams: a re-created player's All Notes Off (CC 123) also ends the other streams' notes on that channel, as on a hardware MIDI merge.
- **Delay (MIX-021/022).** A delayed MIDI edge goes through a `MidiDelayLine` (core/RenderGraph.h): events are queued with the frame they are due at and leave in the block that frame falls in. Its capacity (`kMidiDelayCapacity`, 4096 events in flight) doesn't depend on the delay, so the builder keeps an edge's line for the same endpoints whatever the new delay, even 0, and queued events (note-offs included) survive a rebuild or a latency change. A shrinking delay delivers the events behind it a little late, never reordered. At most `kMidiCapacity` events leave a line per block; the rest leave at the start of the next block.
- **Overflow policy.** Only two places can drop MIDI: a node's own writer (the MidiClipPlayer drops note-ons it can't also end, 06) and a full delay line. A line never drops a note-off or a sustain pedal-up for a note or pedal-down it let through: it counts held notes (per channel and key) and pedals, and keeps that many slots free. A note-on or pedal-down is queued only if room stays for itself and its release; any other event (including offs for notes it never saw) only if it leaves the reserve intact. CC 120/123 clear the channel's held notes from the reserve, CC 121 its pedal. Drops are counted per line (`MidiDelayLine::dropped()`); they are not in Telemetry yet (T-045 Discovered work: a `midiEventsDropped` counter).

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
| MIX-001 | done (T-012; MIDI edges T-045) | `GraphTests` (builds + renders, prepare before publish; `GraphCompiler` on daw.compile coalesces and keeps the current graph on failure; malformed descriptions rejected before the pool is touched); `MidiRoutingTests` (MIDI edges deliver data, converging edges merge in frame order, stable, nothing dropped) |
| MIX-002 | done (T-012) | `GraphTests` (crafted cycle → NodeIDs; random DAGs). Returns `ErrorCode::cycle` with `Error::nodes` (T-087, DW-050) |
| MIX-003 | done (T-012) | `GraphTests` (100-track project ≤ max fan-in + depth; random mixer projects). Bound holds for mixer-shaped graphs, not arbitrary dense DAGs |
| MIX-004 | done (T-012, golden T-025) | `GraphTests` (summing, sidechain port, random DAG sums exact); golden `bus_send_sum` + `GoldenReferenceTests` per-sample check (T-025) |
| MIX-008 | done (T-023, golden T-071) | `SidechainTests` (NodeIO sidechain empty without an edge, else the sum of its edges; pre-fader tap ignores the source's fader/mute/phase/pan, post-fader follows them; rebuilds add/move/remove sidechains with delay-line carry-over; PDC-aligned sidechain merges; buffer liveness over sidechain ports; a model-shaped SetSidechain graph renders through the facade) with test node `SidechainMixNode`. A pre-fader sidechain keys even when its source is muted (ghost trigger; autobuild decision, docs/autobuild/DECISIONS.md). Golden `sidechain_compressor` (T-071): the tone × 0.5 ducked by the kick-keyed compressor gain, sample by sample |
| MIX-009 | done (T-012) | `GraphTests` (master last; limiter off by default, clips + counts overs when on) |
| MIX-005 | done (T-013, T-020) | `ChannelStripTests` (−3 dB constant-power pan law, also on centred stereo; gain linear clamped to +12 dB; ENG-022 per-block ramps; post-fader peak + 300 ms RMS into Telemetry; GraphBuilder assigns stable, reusable MeterIDs, DW-048). T-020: mute/phase slots ramped over one block (`ChannelStripTests` "mute and phase slots…"). Golden `pan_law` + per-sample L²+R² constant check (T-025) |
| MIX-006 | done (T-016) | `SoloResolverTests` (12-row solo-in-place truth table; master muted only by its own mute; resolved mutes land in strip slot 2 and the owner's send slot 1); `EngineSyncTests` solo flips mute slots without a rebuild; `EngineSyncIntegrationTests` "sendMute" (real engine: solo doesn't leak through a pre-fader send) |
| MIX-007 | done (T-020) | `SendTests` (gain node level/mute slots ramped, block-size fuzz; post-fader send follows fader/pan/phase, pre-fader doesn't; a muted track silences pre- and post-fader sends, unmute fades back without a click). Goldens `bus_send_sum` and `send_ramps` (one-block level/mute ramps) with per-sample reference checks (T-025) |
| MIX-020 | done (T-021) | `PdcTests` "path latency = max over inputs + own; graph latency and node table reach telemetry" |
| MIX-021 | done (T-021) | `PdcTests` "delay lines align summing and sidechain merges" (null test, random block sizes, 40 random mixers); golden `pdc_alignment_null` (exact-sample null, T-025); MIDI edges (T-045): `MidiRoutingTests` "MIX-021, MIX-022: MIDI edges are PDC-delayed like audio…" and `MidiDelayLine` checks |
| MIX-022 | done (T-021) | `PdcTests` "a rebuild during playback carries delay lines over by edge ID" (bit-identical to no rebuild, sync and on a render thread; control with a new edge ID) |
| MIX-023 | done (T-021) | `PdcTests` "timeline nodes run graph-latency ahead, pre-rolled at play/locate, loop-aware"; "clip on beat 1 behind a latent master insert exports at sample 0". Pre-roll lives in `Engine::render`. Golden `pdc_alignment_null` (click at frame 0 with graph latency 1500; a bus every track routes through stands in for the master insert, DW-149) (T-025) |
| MIX-024 | partial (T-021) | `PdcTests` "a node's latency change rebuilds on daw.compile, re-plans PDC, queues an event"; the event isn't exposed through the facade yet (DW-082) |
| MIX-025 | done (T-021) | Documented limitation (`core/Engine.h`, 05 "PDC semantics") |
| MIX-* (rest) | todo | |
