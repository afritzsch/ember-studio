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

#### MidiClipPlayer semantics (clarified in T-040)
- A note's on sounds at `tickToSample(start)` and its off at `tickToSample(start + length)`. Within a block, events are in frame order, and offs come before ons on the same tick. Notes are fixed per instance (DW-051, like DSP-001). Notes with length ≤ 0, pitch > 127 or channel > 15 are dropped, and velocity is clamped to 1..127.
- Notes are chased (user decision, DW-103, T-041): playback that starts inside a note (play, locate, loop start, or a tempo edit that moved the playhead's tick) sounds it from that frame, for its remaining length. On every segment that doesn't continue the previous one, after the hanging notes' offs, each note with `start < startTick` whose `tickToSample(start + length)` is after the segment's first sample gets its on at the segment's first frame (in note-start order), under the same capacity rule as any other on.
- "Hanging notes" are the notes the player has started and not yet ended. Each gets exactly one note-off (velocity 64): at its end; at the first frame of a segment that doesn't continue the previous one's ticks (loop wrap, locate, or a tempo edit that moved the playhead's tick), before that segment's ons; or at frame 0 of a stopped block. The offs are explicit per note, not CC 123.
- A new instance can't know what the instance it replaces left on, so its first non-empty block starts with All Notes Off (CC 123) on all 16 channels.
- `midiOut` has fixed capacity. A note-on is written only if room stays for its own off and the offs of all held notes, so a full writer drops notes and never leaves one hanging.

### Channel & utility
| ID | Requirement | Acceptance |
|---|---|---|
| DSP-010 | `ChannelStrip` (see MIX-005): gain, pan, mute, phase, meters. `GainNode` (`NodeKind::gain`): level slot (+ mute slot as a send), the send node of MIX-007. | Golden |
| DSP-011 | `Metronome` (TIME-010). | Golden |

### Sampler (D-19)
| ID | Requirement | Acceptance |
|---|---|---|
| DSP-020 | Key-mapped zones: `{assetID, rootKey, lowKey, highKey, lowVel, highVel, tune, gain, loopStart?, loopEnd?}`. | Unit |
| DSP-021 | Pitch shifting by resampling with 4-point Hermite interpolation; playback-rate = 2^((note−root+tune)/12). | Golden: A4 root, play A5 → 2× freq (FFT peak ±1 Hz) |
| DSP-022 | 32 voices, oldest-note stealing with a 5 ms release on stolen voices. ADSR amp envelope (sample-accurate). Velocity → gain curve. | Unit: 40 notes → 32 voices, no clicks |
| DSP-023 | Responds to sustain pedal (CC64) and pitch bend (±2 semitones). | Unit |

#### Sampler semantics (clarified in T-041)
- **Zones (DSP-020)** come from the node's `configJSON` and are fixed per instance (DW-051): the model bumps `configVersion` when they change or an asset they use finishes loading. Format: `{"zones": [{"assetID": 7, "rootKey": 69, "lowKey": 0, "highKey": 127, "lowVel": 1, "highVel": 127, "tune": 0, "gain": 1, "loopStart": 0, "loopEnd": 48000}]}`. Only `assetID` is required; defaults are rootKey 60, the full key and velocity ranges, tune 0 (semitones), gain 1 (linear) and no loop. Loop points are source frames, `[loopStart, loopEnd)`, both or neither; a loop is clamped to the asset and dropped if that leaves it empty. An empty string or `{}` is a sampler without zones; unknown keys are ignored; malformed JSON or out-of-range values are `invalidArgument`. A zone whose asset isn't loaded or isn't at the session rate is silent.
- A note-on starts one voice per playable zone whose key and velocity ranges (inclusive) contain it, so zones layer. Voices read from frame 0; one-shot voices end at the asset's end, looping ones wrap until their release ends. Velocity `v` scales the zone gain by `(1 − s) + s·(v/127)²`, `s` the velocity-sensitivity param.
- **Voices (DSP-022):** at most 32 sound. A note-on beyond that steals the oldest note, preferring notes already released (not held by key or pedal); the stolen voice fades out linearly over 5 ms in one of 32 extra fade slots while the new note starts at once. If all fade slots are busy too, the quietest fade is cut.
- **ADSR (DSP-022):** linear segments advanced per sample; MIDI events act on their exact frame. Params (relative to `firstParam`, read once per block): 0 attack 0…10 s (default 0.002), 1 decay 0…10 s (0.3), 2 sustain 0…1 (1), 3 release 0…20 s (0.2), 4 velocity sensitivity 0…1 (1). Params beyond `numParams` use their defaults.
- **MIDI (DSP-023, DW-100):** per channel. Note-off (or note-on velocity 0) releases the oldest held note on that key, all its layers. CC 64 ≥ 64 is pedal down: note-offs are deferred until it goes up. CC 123 (All Notes Off) is a note-off for every held note on the channel, so the pedal still holds them (MIDI 1.0). Pitch bend is ±2 semitones (8192 centre, both ends exact), applied from its frame on. Other messages are ignored.

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
| DSP-001 | done (T-013) | `ClipPlayerTests` "AudioClipPlayer (DSP-001)" (sample range, source offset, clip gain, mono → L/R; linear fades clamped, adjacent clips; random clips over a tempo map in random block sizes vs oracle; loop wrap mid-block 64-sample crossfade; locate/stop reset; asset refs released on reclaim, missing/wrong-rate assets silent). Golden "two adjacent clips, fades" waits for T-019. Overlaps summed until DSP-002 |
| DSP-003 | done (T-040, chase T-041) | `MidiClipPlayerTests` (note chase at play/locate/loop start (DW-103), exact frames, oracle over a tempo map in random block sizes, loop wrap, locate/stop release, no-stuck-notes fuzz with small writers, CC 123 on a new instance, through GraphBuilder + Engine). MIDI edges carry no data yet (DW-099); goldens wait for T-019 + T-041 |
| DSP-020 | done (T-041) | `SamplerTests` (zone config JSON; key/velocity ranges and layers) |
| DSP-021 | done (T-041) | `SamplerTests` "Hermite resampling; rate 1 bit-exact, A4 root playing A5 peaks at 880 Hz ±1 Hz" (FFT). Golden `sampler_pitch` waits for MIDI routing + zone config in the model (DW-139) |
| DSP-022 | done (T-041) | `SamplerTests` (sample-accurate ADSR in any block size, velocity curve; 40 notes → 32 voices, released notes stolen first, 5 ms steal fades, no clicks) |
| DSP-023 | done (T-041) | `SamplerTests` (sustain pedal, CC 123 All Notes Off per channel (DW-100), pitch bend ±2 semitones) |
| DSP-010 | done (T-013, T-020) | `ChannelStripTests` (gain, pan, mute, phase, meters; clip player → strip → master through the Engine); `SendTests` (GainNode) |
| DSP-* (rest) | todo | |
