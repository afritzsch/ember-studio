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

### Contract delta (T-052), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-052 contract", "T-052 undo")
Facade additions are in 08 (same heading). Model side:
- `Track.inputPair: UInt32` (0…15, channels 2·pair and 2·pair + 1), decoded with a default of 0, so projects saved before it open unchanged.
- Commands (07, MODEL-005): `ArmTrack {trackID, armed, inputPair?}` (`inputPair` left out keeps the track's) and `SetMonitoring {trackID, mode: off|on|auto}`. Both are **history-exempt** (persisted, mark the project dirty, never in undo history, refused inside a composite), like `SetMetronome`. `SetMonitoring` only stores the mode; what it does is REC-020/021 (T-054).
- `EngineSync` turns the armed audio tracks into `armInput` calls (each change of arm state or input pair; a removed armed track is disarmed; MIDI tracks' arming is T-053). `EngineSync.setRecording(_:)` pushes the recordings folder first; use it instead of `engine.setRecording`.

Clarifications:
- *Folder (REC-002).* Takes go to `<project folder>/Audio/Recordings/`. A project without a folder records into `$TMPDIR/EmberStudio-Recordings/<project UUID>-<pid>/` and refers to the files by absolute path; saving copies them into `Audio/` (DW-124). Files are named `Track <id> Take <n>.caf`, with the first unused `n`. A partly written take (writer error) is deleted; a take with drops is kept with silence in the gaps.
- *Placement (REC-003, REC-004).* Clips start on ticks. The clip starts at the first tick at or after `startSample`, with `sourceOffsetSamples` skipping the frames before it, so file frame k still plays at sample `startSample + k` exactly. A take starting before 0 starts at tick 0 with its first frames skipped. A take recorded at another session rate is placed scaled to the current one.
- *Import (REC-004).* `ProjectStore` imports each `recordingFinalized` take when the events are polled (`RecordingImport`, `importRecording`): the engine loads the file under the next model ID, then `CompositeCommand("Record", [ImportAsset, AddClip])` is performed as one undo step. Undo leaves the file on disk.
- *Punch (REC-005).* The range is transport state (not in the project), set through `transport.setPunch` (13). The loop disables it (REC-030 takes are T-080).

## Status
| ID | status | test |
|---|---|---|
| REC-001 | done (T-052) | `RecordingTests` (FIFO whole blocks, ≥ 2 s at 96 kHz; armed pairs record), `RecordingModelTests` (ArmTrack → armInput, armed on attach), `RecordingControlTests` recordFlow; RT trap 0 |
| REC-002 | done (T-052) | `RecordingTests` "stalled writer … drops counted"; `RecordingModelTests` (unsaved project → per-project temp folder) |
| REC-003 | done (T-052) | `RecordingTests` loopback via fake device (±1 sample); golden `record_loopback_alignment` (exact to the sample) |
| REC-004 | done (T-052) | `RecordingTests` (finalize on stop/device loss/arm change, DW-119); `RecordingModelTests` (one undoable "Record" = ImportAsset + AddClip; relative path inside the project) |
| REC-005 | done (T-052) | `RecordingTests` punch [in, out) at any block split, loop disables it; golden `record_loopback_alignment` punch; `RecordingControlTests` `transport.setPunch` |
| REC-* (rest) | todo | |
