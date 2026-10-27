# 06 — Built-in DSP Processors

**Depends on:** 02 (Node API), 03 (TransportBlock for clip players/sampler) · **Owns:** `Sources/DAWEngine/dsp/`, `Sources/DAWEngine/nodes/`.

All processors are `daw::Node` subclasses, stereo in/out, with parameters through ParamSlots smoothed per block (ENG-022). Each has a **parameter table** (id, name, range, default, unit, curve) exported as JSON for the model and UI (`ParamInfo`).

## Requirements

### Clip players
| ID | Requirement | Acceptance |
|---|---|---|
| DSP-001 | `AudioClipPlayer`: for each TransportSegment, finds overlapping clips (sorted array, binary search), copies frames from `AudioAsset` with clip gain and linear fades (fade in/out in ticks → samples). Mono assets are duplicated to L/R. A clip sounds on samples `[tickToSample(start), tickToSample(start+length))` of the block's tempo map (moves with tempo, never stretches, D-06); source frames outside the asset are silent. **Clip delivery (DW-051):** a player's clips (and their assets, resolved through the `AssetLookup` given to `registerBuiltinNodes`) are fixed when the node instance is created, so the model bumps the player's `configVersion` whenever that track's clips change or an asset they use finishes loading; unloaded assets play silence. Loop wraps crossfade the old and new pass over 64 samples (TIME-005/006). | Golden: two adjacent clips, fades |
| DSP-002 | Overlapping clips on one track: the later clip wins, with an automatic 64-sample equal-power crossfade at boundaries (comp boundaries reuse this, see 09). | Golden |
| DSP-003 | `MidiClipPlayer`: emits note-on/off events with frame offsets for notes overlapping the segment. On loop wrap/locate it sends note-offs for hanging notes (all-notes-off). | Unit: no stuck notes after random locates |

### Channel & utility
| ID | Requirement | Acceptance |
|---|---|---|
| DSP-010 | `ChannelStrip` (see MIX-005): gain, pan, mute, phase, meters. | Golden |
| DSP-011 | `Metronome` (TIME-010). | Golden |

### Sampler (D-19)
| ID | Requirement | Acceptance |
|---|---|---|
| DSP-020 | Key-mapped zones: `{assetID, rootKey, lowKey, highKey, lowVel, highVel, tune, gain, loopStart?, loopEnd?}`. | Unit |
| DSP-021 | Pitch shifting by resampling with 4-point Hermite interpolation; playback-rate = 2^((note−root+tune)/12). | Golden: A4 root, play A5 → 2× freq (FFT peak ±1 Hz) |
| DSP-022 | 32 voices, oldest-note stealing with a 5 ms release on stolen voices. ADSR amp envelope (sample-accurate). Velocity → gain curve. | Unit: 40 notes → 32 voices, no clicks |
| DSP-023 | Responds to sustain pedal (CC64) and pitch bend (±2 semitones). | Unit |

### Effects
| ID | Requirement | Acceptance |
|---|---|---|
| DSP-030 | **EQ**: 4 bands (low shelf, 2× peak, high shelf) + HP/LP (12 dB/oct), RBJ biquads, TDF-II, coefficients recomputed per block when params change. | Frequency response test vs analytic within 0.1 dB |
| DSP-031 | **Compressor**: feed-forward, peak/RMS detector, threshold, ratio, attack, release, knee, makeup, **sidechain input** (MIX-008), gain-reduction meter in telemetry. 0 latency (no lookahead). | Static curve test; sidechain golden |
| DSP-032 | **Delay**: stereo/ping-pong, time in ms or tempo-synced note values (reads tempo from TransportBlock), feedback, LP filter in loop, mix. Delay time changes are smoothed (no zipper/pitch artifacts beyond a short crossfade). | Golden |
| DSP-033 | **Reverb**: algorithmic (FDN, 8 lines, Hadamard), size, decay, damping, pre-delay, mix. Deterministic (no random modulation, or seeded). | Golden + determinism (IO-011) |

### General
| ID | Requirement |
|---|---|
| DSP-040 | Every processor passes: RT trap = 0 violations, block-size fuzz (ENG-004), silence-in → silence-out after tail (no denormal blowup), NaN guard (outputs 0 and bumps telemetry on NaN). |
| DSP-041 | Every processor publishes `ParamInfo[]` through a registry: `NodeRegistry::paramInfo(NodeKind)`. |

## Interfaces (contract)
```cpp
struct ParamInfo { uint32_t index; const char* id; const char* name; float min, max, def;
                   enum class Curve { linear, log, db } curve; const char* unit; bool automatable; };
class NodeRegistry { public: static std::span<const ParamInfo> paramInfo(NodeKind);
                     static std::unique_ptr<Node> create(NodeKind, std::string_view configJSON); };
```

## Status
| ID | status | test |
|---|---|---|
| DSP-* | todo | |
