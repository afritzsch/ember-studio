# 07 — Document Model, Commands, Undo & Persistence

**Depends on:** 03 (Swift TempoMap), 05 (GraphDescription shape) · **Owns:** `Sources/DAWModel/`.

`DAWModel` is a **UI-free** Swift package (D-25). The app, `dawctl` and `dawmcp` all mutate the document only through `Command`s.

## Document (value types)
```swift
public struct Project: Codable, Sendable {
  var formatVersion: Int          // MODEL-040
  var id: UUID; var name: String
  var sessionSampleRate: Double
  var tempoMap: TempoMap
  var tracks: [Track]             // ordered
  var buses: [Bus]; var master: MasterChannel
  var assets: [AssetRef]          // original file path (relative), channels, original rate, frames
  var loop: LoopRange?
}
struct Track { id: NodeIDValue; name; kind: .audio | .midi; color
               clips: [Clip]; takeFolders: [TakeFolder] (09)
               instrument: DeviceSlot?  // midi tracks
               inserts: [DeviceSlot]; strip: ChannelStripState; sends: [Send]
               output: OutputTarget; armed: Bool; monitoring: .off|.auto|.on
               automation: [AutomationLane] (11) }
enum Clip { case audio(AudioClip), midi(MidiClip) }    // ticks
struct DeviceSlot { id; kind: .builtin(NodeKind) | .au(AUDescriptor) | .vst3(VST3Descriptor)
                    params: [ParamValue]; pluginState: Data?; bypass: Bool; sidechainSource: SidechainRef? }
```
IDs are `UInt64`, allocated by `IDAllocator` stored in the project (never reused).

## Requirements

### Commands & undo
| ID | Requirement | Acceptance |
|---|---|---|
| MODEL-001 | `protocol Command: Codable, Sendable { func apply(to: inout Project) throws(DAWError) -> any Command /* inverse */ ; var label: String }`. | — |
| MODEL-002 | `UndoStack`: `perform(cmd)`, `undo()`, `redo()`, unlimited depth (cap 1000), redo cleared on new perform. | Property test: random command sequences, undo-all → original project (==) |
| MODEL-003 | **Coalescing**: continuous gestures (fader drag, clip drag) use `beginGesture/endGesture`. Intermediate updates write param slots directly or apply without pushing; one undo entry is pushed at gesture end. | Test: 100-step drag → 1 undo entry |
| MODEL-004 | `CompositeCommand` for multi-step edits (e.g. delete track = remove sends targeting it + remove track). | — |
| MODEL-005 | Command catalogue (v1): `AddTrack, RemoveTrack, MoveTrack, RenameTrack, SetTrackOutput, AddBus, RemoveBus, AddSend, RemoveSend, SetSendLevel, SetSendTap, AddClip, RemoveClip, MoveClip, ResizeClip, SplitClip, SetClipGain, SetClipFades, AddNotes, RemoveNotes, MoveNotes, SetNoteProps, InsertDevice, RemoveDevice, MoveDevice, SetDeviceBypass, SetParam, SetSidechain, SetTempoEvent, RemoveTempoEvent, SetTimeSignature, SetLoop, ArmTrack, SetMonitoring, AddAutomationPoint(s), RemoveAutomationPoints, MoveAutomationPoints, SetAutomationMode, CreateTakeFolder, SetCompSelection, ImportAsset, SetSessionSampleRate`. | Each has an apply/inverse round-trip test |
| MODEL-006 | Every Command is **Codable** with a stable `type` string. This is the wire format for the control protocol (13). | JSON round-trip tests |
| MODEL-007 | `ProjectStore` (observable for the UI) holds the current `Project`, the undo stack, a dirty flag and `changeStream` (AsyncStream of `ProjectChange` with changed IDs). | — |

### Engine sync
| ID | Requirement | Acceptance |
|---|---|---|
| MODEL-020 | `GraphDescriptionBuilder` turns `Project` into `GraphDescription` (05 interfaces): node per clip player, instrument, insert, strip, bus, master; edges for outputs, sends, sidechains. Pure function. | Snapshot tests on fixture projects |
| MODEL-021 | After each Command (or gesture end), the store diffs whether structure changed. Structural change → build a description → `EngineFacade.applyGraph` (debounced 10 ms, coalesced). Param-only change → `EngineFacade.setParam` (no rebuild). | Test: SetParam does not call applyGraph |
| MODEL-022 | `ParamID` allocation: the model asks the facade for ParamIDs per device slot when it is created and stores them in runtime-only state (not persisted). On load, they are reallocated. | — |

**Engine sync semantics (clarified in T-016).**
- *NodeIDs* (`GraphNodeID`): a channel strip has its track's, bus's or master's ID, so `meter(track.id)` reads the track meter. A device slot has the slot's ID, and a send's `gain` node has the send's ID. Nodes without a model entity get the owner's ID with a role in the top 8 bits: a track's clip player is `source`, a bus's or the master's summing input (`NodeKind.bus`) is `input`, and the master node is `output`. Edge IDs hash `(from, to, kind)`, so an edge whose ends don't change keeps its ID (MIX-022).
- *Sends* (agreed with T-020): post-fader is `strip → gain(send) → bus input`. Pre-fader taps the node that feeds the strip instead (the last insert, or the source/instrument).
- *Structural vs param-only*: a change is structural exactly when the built `EngineGraph` differs from the last one applied. Param values (strip gain/pan/mute/phase, send levels, device params) never enter the graph. They are diffed against the last written values and sent with `setParam`. Structural changes inside a gesture are applied too, coalesced per 10 ms window.
- *Param slots*: strips get 4 (gain 0, pan 1, mute 2, phase 3), sends get 2 (level 0, mute 1; MIX-007), and the master node gets 1 (limiter). Device slots get their kind's ParamInfo count, or as many as their stored values need. A slot is freed after the graph without its node is applied.
- *Solo (MIX-006)*: soloing a track or a bus counts. A channel stays audible if it is soloed, upstream of a soloed channel or downstream of one, following outputs and sends but not sidechains. A channel's own mute always wins, and solo never mutes the master. A channel's resolved mute (manual or solo) is written into its strip's mute slot and into the mute slot of every send it owns, so a pre-fader send can't leak a muted channel (MIX-007, user decision); send levels keep their value.
- *Clip players (DW-072)*: a player gets the next `configVersion` when its clips or notes differ from the applied graph, or when an `assetLoaded` event names an asset its clips use.
- *Left out of the graph*: bypassed devices (until host bypass, PLUG-018), outputs and sends to a missing bus, and a MIDI track's player when it has no active instrument.

### Validation
| ID | Requirement | Acceptance |
|---|---|---|
| MODEL-030 | **Cycle rejection** (D-14): `SetTrackOutput`, `AddSend` and `SetSidechain` run DFS reachability over the routing graph and throw `DAWError.routingCycle(path)` if the edge would close a cycle. | Unit: bus A→B, B→A rejected; error carries path |
| MODEL-031 | Commands validate references (IDs exist, ranges valid) and throw rather than corrupt state. | Fuzz: random invalid commands never break invariants |
| MODEL-032 | `Project.validate()` checks all invariants (unique IDs, acyclic, clips non-negative, sorted notes). It runs after every command in Debug. | — |

**Routing commands and validation (clarified in T-022).**
- *Inverses keep IDs*: undo of a remove and redo of an add re-insert the entity with its own IDs through `RestoreTrack`, `RestoreBus` and `RestoreSend` (registered like any command and checked like any input). So later history entries still find the IDs they name.
- *Cascades* (MODEL-004): `RemoveBus` removes sends into the bus, routes outputs into it to the master and clears sidechains listening to it. `RemoveTrack` clears sidechains listening to the track. Each is one undo entry. `SetTrackOutput` takes a track or a bus (`channelID`).
- *Cycles* (MODEL-030) are checked on a channel graph (tracks, buses, master; edges for outputs, sends and sidechains, bypassed devices included, so toggling bypass never closes a cycle). The error path is the shortest cycle through the new route, `[from, to, …, from]`. A channel sidechaining its own device is a cycle.
- *SetParam* takes a `ParamTarget`: `strip(channel, gain|pan|mute|solo|phase)`, `sendLevel(send)` or `device(slot, index)`. Gain and send level are linear 0…+12 dB, pan −1…1, switches are on at ≥ 0.5, and the master has no solo. A nil value removes a stored device param (back to the kind's default).
- *validate()* (MODEL-032) also checks that IDs are in 1…`GraphNodeID.maxModelID` and below the allocator's `next`, that references exist, that clips match their track's kind, and the strip, send and param ranges. In Debug, a command (or undo/redo) that leaves the project invalid is rejected like an invalid one. Decoding moves the allocator past the largest ID and rejects IDs above `maxModelID` (DW-031). Clip order is checked since T-030 (below).

**Clip, tempo and loop commands (clarified in T-030).**
- *Clip order* (DW-110): a track's clips are sorted by `(start, id)`. With the ID as tie-break the order is a function of the clips, so a clip moved away and back returns to its index and undo restores the project exactly. Every clip command keeps it; `validate()` checks it.
- *Inverses keep IDs* as for routing: `RemoveClip` ↔ `RestoreClip` (clip and note IDs), `ImportAsset` ↔ `RemoveAsset` (with the asset's index), `SplitClip`'s inverse is one composite `[RemoveClip(new), SetClip(original)]`, and `SetLoop`'s inverse is `RestoreLoop`. `SetClip` (replace a clip by ID) and `RestoreLoop` are registered like any command.
- *ImportAsset* (DW-105, DW-043) is `{"type": "ImportAsset", "asset": AssetRef, "index"?}`: it claims `asset.id` (unused, in range) instead of allocating, because the caller loads the file under `project.ids.next` first. The command only records the import: copying the file (`AudioImporter::importFile`, IO-030) and decoding it happen before it, outside the model, since a command is replayed on redo and DAWModel reaches the engine only through `EngineProtocol`. `AssetRef.path` is the project-relative path when the file is inside the project folder, otherwise absolute (a referenced file, or a project with no folder yet). `RemoveAsset` refuses an asset a clip uses; a missing file keeps its asset (MODEL-046).
- *AddClip* `{trackID, start, length?, assetID?, sourceOffsetSamples?, gain?, fadeIn?, fadeOut?}`: an audio track needs `assetID`, and the default length covers the rest of the asset after the offset at the current tempo (rounded up to a whole tick). A MIDI track gets an empty clip (notes are T-042) and needs `length`; audio fields are rejected there.
- *MoveClip* `{clipID, start, trackID?}` moves onto any track of the same kind; the audio and notes move with the clip. *ResizeClip* `{clipID, start, length}` sets the window while the content stays put: moving the start shifts an audio clip's `sourceOffsetSamples` by `tickToSample(new) − tickToSample(old)` (rejected if it would go below 0) and MIDI note starts the other way. Notes outside the window are kept (the builder trims them), fades are left as they are (the clip player clamps them). *SplitClip* `{clipID, at}` with `at` strictly inside: the clip keeps `[start, at)` and its fade-in; a new clip gets `[at, end)`, the fade-out and the matching offset; notes starting at or after `at` move to it.
- *SetClipGain* is linear 0…+12 dB (an invariant, like strip gain). *SetClipFades* `{clipID, fadeIn, fadeOut}`: each fade is in 0…length; they may overlap.
- *Timeline bound*: clips, tempo and signature events and the loop lie in 0…`Tick.timelineEnd` (2^40 ticks), and `sourceOffsetSamples` ≤ 2^48, so tick→sample conversions can't overflow at any valid tempo and rate.
- *Tempo* (`SetTempoEvent {tick, bpm}`, `RemoveTempoEvent {tick}`) and *signatures* (`SetTimeSignature {tick, numerator, denominator}`, `RemoveTimeSignature {tick}`) add an event or change the one at `tick`; the events at tick 0 can be changed, not removed. Map errors are `invalidTempoMap` (DW-021). Clips keep their ticks and offsets (D-06). The playhead is left to the engine (DW-061 open).
- *SetLoop* `{loop: {start, end, isEnabled}?}`; `nil` clears it. An enabled loop must be at least 4096 samples (`daw::kMaxBlock`) at the tempo when it is set (DW-060). A later tempo edit may shrink it; that isn't an invariant, so `RestoreLoop` checks only the range.

### Persistence
| ID | Requirement | Acceptance |
|---|---|---|
| MODEL-040 | Project = folder `Name.dawproject/` with `project.json` (pretty, sorted keys, `formatVersion`), `Audio/`, `Plugins/<slotID>.state` (binary blobs), `Cache/` (disposable), `autosave/`. | — |
| MODEL-041 | Save is atomic: write to `project.json.tmp`, `fsync`, rename. | Kill-during-save test leaves a loadable project |
| MODEL-042 | `Migrations`: `[Int: (inout JSON) throws -> Void]`, applied sequentially on load when `formatVersion` < current. | Test migration v1→v2 fixture (dummy) |
| MODEL-043 | Plugin state is captured from the engine (facade `getPluginState(slot)`) at save time and restored after instantiation on load. | Round-trip test with built-in "fake plugin" |
| MODEL-044 | **Autosave** (D-07): every 60 s if dirty, and immediately (debounced 2 s) after structural commands, write a full copy to `autosave/project.json` + plugin states. Never overwrites the main file. | — |
| MODEL-045 | **Recovery**: on open, if `autosave/project.json` is newer than `project.json`, offer recovery (UI) or `--recover` flag (CLI). A clean quit deletes the autosave. | Test via `dawctl open --recover` |
| MODEL-046 | Missing audio file on load: mark the asset `offline`, keep clips, render silence, report through `ProjectLoadReport`. | Test |

## Interfaces (contract)
```swift
public protocol Command: Codable, Sendable { static var type: String { get }; var label: String { get }
  func apply(to project: inout Project) throws(DAWError) -> any Command }
@MainActor public final class ProjectStore: Observable {
  public private(set) var project: Project
  public func perform(_: any Command) throws(DAWError)
  public func undo(); public func redo()
  public func beginGesture(_ label: String); public func endGesture()
  public func save(to: URL?) async throws(DAWError); public static func open(_: URL, recover: Bool) async throws(DAWError) -> ProjectStore }
public enum CommandRegistry { public static func decode(_ json: Data) throws(DAWError) -> any Command }
```
In headless tools, `ProjectStore` runs on `@MainActor` too (the CLI has a main run loop), so there is one isolation story.

## Status
| ID | status | test |
|---|---|---|
| MODEL-001 | done (T-015) | `UndoStackTests`. `DAWError` lives in `Sources/DAWModel/DAWError.swift`; a throwing `apply` leaves the project unchanged |
| MODEL-002 | done (T-015) | `UndoStackTests` (property test: random sequences, undo-all == original; `Project ==` ignores the ID allocator) |
| MODEL-003 | done (T-015) | `UndoStackTests`, `ProjectStoreTests` (100-step drag → 1 undo entry); param-slot path is a seam for T-016 |
| MODEL-004 | done (T-015) | `UndoStackTests` (`CompositeCommand`) |
| MODEL-006 | done (T-015) | `CommandRegistryTests` (JSON round trip, stable `type`); only real command so far is `RenameTrack` |
| MODEL-007 | done (T-015) | `ProjectStoreTests`; `save`/`open` throw `.notImplemented` until T-031 |
| MODEL-020 | done (T-016) | `GraphDescriptionBuilderTests` (snapshots of 4 fixture projects in `Tests/Fixtures/graph_snapshots/`; well-formed; pure; send/sidechain taps; stable edge IDs; role-tagged NodeIDs); real engine accepts the graphs (`EngineSyncIntegrationTests`) |
| MODEL-021 | done (T-016) | `EngineSyncTests` (param-only → setParam, never applyGraph; structural → one apply per 10 ms window from the latest project; 100-step fader drag rebuilds nothing; clip drag coalesces); end to end in `EngineSyncIntegrationTests`. Cost measured in `SyncCostTests` (DW-032) |
| MODEL-022 | done (T-016) | `EngineSyncTests` (slots allocated on attach, freed after the apply that drops a node, runtime-only and reallocated on open; counts/defaults from ParamInfo) |
| MODEL-005 | partial (T-022: routing subset) | `RoutingCommandTests` (AddTrack, RemoveTrack, MoveTrack, RenameTrack, SetTrackOutput, AddBus, RemoveBus, AddSend, RemoveSend, SetSendLevel, SetSendTap, SetSidechain, SetParam; apply → JSON-decoded inverse → redo; Restore* inverses keep IDs); `CommandRegistryTests`; end to end in `RoutingEngineTests`. Clip/tempo (T-030) and note (T-042) subsets todo |
| MODEL-030 | done (T-022) | `RoutingCommandTests` (A → B then B → A rejected with `routingCycle([B, A, B])`; self-routing, longer cycles through sends and sidechains; bypassed devices count) |
| MODEL-031 | done (T-022) | `RoutingCommandTests` "unknown IDs and bad arguments throw and change nothing" (35 cases); routing fuzz (150 runs × 40 commands, undo-all restores) |
| MODEL-032 | done (T-022) | `ProjectValidationTests` (unique IDs in 1…maxModelID below the allocator; references; acyclic; clip/note/param ranges; Debug `UndoStack` hook rejects an invalidating command; decoding reserves IDs). Clip order isn't enforced yet (DW-110) |
| MODEL-* (rest) | todo | |
