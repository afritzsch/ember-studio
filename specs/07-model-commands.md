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

### Validation
| ID | Requirement | Acceptance |
|---|---|---|
| MODEL-030 | **Cycle rejection** (D-14): `SetTrackOutput`, `AddSend` and `SetSidechain` run DFS reachability over the routing graph and throw `DAWError.routingCycle(path)` if the edge would close a cycle. | Unit: bus A→B, B→A rejected; error carries path |
| MODEL-031 | Commands validate references (IDs exist, ranges valid) and throw rather than corrupt state. | Fuzz: random invalid commands never break invariants |
| MODEL-032 | `Project.validate()` checks all invariants (unique IDs, acyclic, clips non-negative, sorted notes). It runs after every command in Debug. | — |

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
| MODEL-* | todo | |
