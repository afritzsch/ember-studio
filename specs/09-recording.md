# 09 — Recording, Monitoring & Comping

**Depends on:** 04 (devices, latency, file writer), 07 (Commands), 08 (facade) · **Owns:** `Sources/DAWEngine/record/`, `Sources/DAWModel/Recording/`.

## Requirements

### Audio recording
| ID | Requirement | Acceptance |
|---|---|---|
| REC-001 | Arming a track assigns an input channel pair. While recording, the audio thread copies input frames into a per-track `SpscQueue`-backed FIFO (preallocated, ≥ 2 s capacity). | RT trap = 0 during record |
| REC-002 | `daw.diskwrite` drains FIFOs into 32-bit float CAF files in `Audio/Recordings/`. FIFO overflow → telemetry `recordDrops` + event (never blocks the audio thread). | Stress test with slow writer → drops counted, no glitch |
| REC-003 | **Latency compensation:** the recorded clip's start = transport tick at record start, minus `inputLatency + outputLatency` (in samples, converted via tempo map) (IO-005). | Loopback test with `FakeDeviceDriver` (output → input with known latency): recorded click aligns within ±1 sample |
| REC-004 | On stop: finalize files, emit `recordingFinalized{trackID, file, startSample, frames, takeIndex}`; the model turns it into `ImportAsset` + `AddClip` (or take folder entries) as **one** undoable composite command. | Test |
| REC-005 | Punch in/out: if loop is off and a punch range is set, write only inside the range. | Golden via fake device |

### MIDI recording
| ID | Requirement | Acceptance |
|---|---|---|
| REC-010 | CoreMIDI input: `MIDIInputPortCreateWithProtocol` (MIDI 1.0). Events are timestamped with host time → converted to sample time against the device clock anchor → pushed into an `SpscQueue<MidiInEvent>` per input. | Unit with synthetic timestamps |
| REC-011 | The audio thread routes MIDI input to armed MIDI tracks (live play-through to the instrument) and to the record buffer. | — |
| REC-012 | On stop, recorded notes (paired on/off, unpaired → closed at stop) become a MIDI clip via a Command. | Unit |

### Input monitoring
| ID | Requirement | Acceptance |
|---|---|---|
| REC-020 | Monitoring modes per track: `off`, `on`, `auto` (on when armed and (stopped or recording), off during playback). | Truth table test |
| REC-021 | Monitored input feeds the track's insert chain in place of the clip player. Software monitoring latency = input + output latency + PDC of that chain; shown in the UI. | — |
| REC-022 | Monitoring changes are slots (no rebuild); arming changes are structural (rebuild). | — |

### Loop recording & comping
| ID | Requirement | Acceptance |
|---|---|---|
| REC-030 | When loop is enabled during recording, each loop pass becomes a **take** in the track's `TakeFolder {range, takes: [TakeID: clipRef], comp: [CompSegment]}`. A single continuous file is written and takes are clip views into it (offsets). | Fake device: 3 passes → 3 takes |
| REC-031 | `CompSegment { start: Tick, end: Tick, take: TakeID }` covers the folder range without gaps. Default comp = last take everywhere. | — |
| REC-032 | The comp renders as ordinary audio clips derived from segments (GraphDescriptionBuilder flattens it), with 64-sample equal-power crossfades at boundaries (DSP-002). | Golden |
| REC-033 | `SetCompSelection(folder, range, take)` splits and merges segments. It is undoable. | Unit |
| REC-034 | MIDI loop recording: merge (overdub) by default, with an option for takes (same TakeFolder model with MIDI clips). | Unit |

## Interfaces (contract)
- Facade: `armInput`, `setRecording`, event `recordingFinalized` (08).
- Model types: `TakeFolder`, `Take`, `CompSegment` (Codable, persisted in `Track.takeFolders`).

## Status
| ID | status | test |
|---|---|---|
| REC-* | todo | |
