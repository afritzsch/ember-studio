# 08 — Swift ↔ C++ Bridge (EngineFacade)

**Depends on:** 02, 05, 07 · **Owns:** `Sources/DAWEngine/include/daw/EngineFacade.h`, `Sources/DAWEngine/facade/`, `Sources/DAWModel/Engine/EngineClient.swift`.

Swift sees only `EngineFacade` and the POD/description types it uses (D-18). No templates, exceptions, `std::function` or raw owning pointers cross the boundary.

## Requirements

| ID | Requirement | Acceptance |
|---|---|---|
| BRIDGE-001 | `daw::EngineFacade` is a non-copyable C++ class marked `SWIFT_SHARED_REFERENCE` (retain/release functions), so Swift holds it as a class reference. | Swift test creates and destroys it repeatedly without leaks |
| BRIDGE-002 | Every facade method is non-RT and thread-safe (callable from the main actor or a background task). Long operations (load assets, scan, offline render) are async through a completion token polled by Swift (`JobID` + `pollJob`) rather than C++ callbacks into Swift. | — |
| BRIDGE-003 | `GraphDescription` crosses as a C++ value built by Swift through a builder API (`GraphDescriptionBuilder` C++ class with `addNode/addEdge/addClip/addNote/setTempo`), so Swift never instantiates `std::vector<NodeDesc>` directly. | Swift unit test builds a description |
| BRIDGE-004 | Events: `pollEvents(EngineEvent* out, size_t max) → size_t`. Swift polls at 60 Hz in the app (display link) and per tick in the CLI. | — |
| BRIDGE-005 | Telemetry: `telemetry() → TelemetryPOD` (copied snapshot) and `meter(NodeID) → MeterPOD`. | — |
| BRIDGE-006 | Strings cross as `std::string` (Swift interop supports it); binary blobs (plugin state) as `std::vector<uint8_t>` ↔ `Data` via helper. | — |
| BRIDGE-007 | `EngineClient` (Swift) wraps the facade with a Swift-idiomatic, `Sendable` API and is the only Swift type that imports `DAWEngine`. `DAWModel` depends on `EngineClient` through the protocol `EngineProtocol`, so the model can be tested with a `FakeEngine`. | Model tests use FakeEngine |
| BRIDGE-008 | Engine mode is selected at creation: `.realtime(DriverConfig)` or `.offline` (no device; renders only via `renderOffline`). | `dawctl` uses `.offline` |

## Interfaces (contract)
```cpp
namespace daw {
class EngineFacade {               // SWIFT_SHARED_REFERENCE(retainFacade, releaseFacade)
public:
  static EngineFacade* create(EngineMode, const DriverConfig&);
  // graph & params
  uint64_t applyGraph(const GraphDescription&);        // returns graph version; compile is async
  ParamID allocateParams(uint32_t count);  void freeParams(ParamID first, uint32_t count);
  void setParam(ParamID, float);           float getParam(ParamID) const;
  // transport
  void play(); void stop(); void locate(Tick); void setLoop(bool, Tick, Tick); void setRecording(bool);
  TransportPOD transport() const;
  // assets
  JobID loadAsset(uint64_t assetID, const std::string& path);   JobStatus pollJob(JobID) const;
  // recording (09)
  void armInput(NodeID track, uint32_t inputChannelPair, bool armed);
  // plugins (10)
  JobID instantiatePlugin(NodeID slot, const PluginDescriptorPOD&);
  std::vector<uint8_t> getPluginState(NodeID slot); void setPluginState(NodeID slot, const std::vector<uint8_t>&);
  void* createPluginView(NodeID slot); void destroyPluginView(NodeID slot);   // NSView*
  // offline
  JobID renderOffline(Tick from, Tick to, const ExportSpecPOD&);
  // device
  std::vector<DeviceInfoPOD> devices() const; Result<void> setDevice(const DriverConfig&);
  // observability
  TelemetryPOD telemetry() const; MeterPOD meter(NodeID) const;
  size_t pollEvents(EngineEventPOD* out, size_t max);
  std::string paramInfoJSON(NodeKind) const;
};
}
```
```swift
public protocol EngineProtocol: AnyObject, Sendable {
  func applyGraph(_ project: Project, runtime: RuntimeIDs) -> UInt64
  func setParam(_ id: ParamID, _ value: Float)
  // … mirrors the facade with Swift types
}
```

### Contract deltas (T-014, accepted by the user 2026-10-28)
These amend the contract above; where they differ, they win.

1. **`setDevice` returns `FacadeError`, not `Result<void>`.** `core/Result.h` isn't on the include path Swift sees (`include/` only, 01 Interfaces), and Swift can't call `Result::value()` (DW-022). `FacadeError { FacadeErrorCode code; std::string message; std::vector<NodeID> cycle; }`, where `code == none` means success. It is also how jobs and graph builds report errors. `FacadeErrorCode` mirrors `daw::ErrorCode` plus `none`. For `cycle`, `Error::nodes` crosses as `FacadeError::cycle` (DW-050).
2. **`EngineEventType` (04 Interfaces) is defined in `EngineFacade.h` and gets more cases.** Swift has to see the enum, so it can't live in `io/`. The added cases are facade-produced: `assetLoaded`, `assetLoadFailed` (DW-041; the model re-applies the graph with the affected clip players' `configVersion` bumped, DW-051), `graphRejected` (a failed build, e.g. a cycle) and `jobFinished`. `overload` is raised when telemetry's xrun count grows (IO-023).
3. **Additive facade API.** `GraphStatusPOD graphStatus() const` and `GraphStatusPOD waitForGraph(uint64_t version, uint32_t timeoutMs)` let callers learn the outcome of a build without callbacks (BRIDGE-002). `std::vector<NodeLatencyPOD> nodeLatencies() const` covers CTL `engine.telemetry`'s per-node latency. `applyGraph` stamps the description's `version` itself (1, 2, …) and returns it, so versions are unique and `TelemetryPOD.graphVersion` can be waited on (DW-047). `GraphDescriptionBuilder` (BRIDGE-003) is declared in `EngineFacade.h`. Diagnostics: `instanceID()` and `static isLive(id)` (the BRIDGE-001 leak test). `ByteVector` names `std::vector<uint8_t>` so Swift can build plugin state (BRIDGE-006).
4. **Swift `EngineProtocol.applyGraph(_ graph: EngineGraph) -> UInt64`** takes `EngineGraph`, a Swift value mirror of `GraphDescription`, instead of `(Project, RuntimeIDs)`. Turning a Project into a description is MODEL-020 (T-016), and `RuntimeIDs` (MODEL-022) doesn't exist yet. A plain value keeps the protocol a mirror of the facade, lets `FakeEngine` record exactly what would cross, and gives T-016 something to snapshot-test. T-016 can add `applyGraph(_ project:runtime:)` as an extension on top.
5. **The facade's config type is `DriverConfigPOD`.** T-011 defined `daw::DriverConfig` in `io/DriverConfig.h` (04 `AudioDriver::start`), which Swift can't see, and two `daw::DriverConfig`s can't coexist. So `create`/`setDevice` take `DriverConfigPOD`, which mirrors the io fields (device AudioObjectIDs, rate, `bufferFrames`, channels). It leaves out `inputEnabled`, which the facade derives from `armInput` (DW-067: turning input on or off restarts the driver). `DeviceInfoPOD` identifies devices by `deviceID` (AudioObjectID).

Affected: T-016 (builds `EngineGraph`, reacts to `assetLoaded`), T-017/T-018 (dispatcher uses `EngineProtocol`, `waitForGraph`, events), T-011/T-051 (driver adapter seam `facade/DriverAdapter.h` with `CoreAudioDriverAdapter`; `DriverConfigPOD`; IO-021/023 events).


### Contract deltas (T-051, accepted by the user 2026-10-28)
IO-021 (7) asks for `EngineEvent.deviceChanged{reason}`, but `EngineEventPOD` has no place for a reason or for which device the engine moved to. dawctl/dawmcp also can't reach a fake device to exercise the hot-swap (DW-089), so IO-021 couldn't be driven through the control layer as CONV §5.5 asks. Everything below is **additive**: existing fields, cases and calls keep their meaning, and current Swift code compiles unchanged. The engine side is `io/DeviceMonitor.h`; `facade/DeviceHost` implements its host.

1. **`deviceChanged` says why and what it changed to.** New in `EngineFacade.h`:
   ```cpp
   enum class DeviceChangeReason : uint8_t {
     deviceLost,           // the running output (or separate input) device went away → fell back to the default (D-26)
     sampleRateChanged,    // its nominal rate moved off the session rate → restarted (IO-021 (5))
     defaultOutputChanged, // following the system default (outputDevice 0) and it moved
     deviceAvailable,      // nothing was running (no device / a failed start) and a device appeared
     startFailed,          // a start the facade made itself failed: at create, after an export, arming input
   };
   struct DeviceChangePOD {
     DeviceChangeReason reason = DeviceChangeReason::deviceLost;
     uint32_t previousDeviceID = 0;      // output AudioObjectID before (0: none was running)
     uint32_t deviceID = 0;              // running now (0: none; `error` says why)
     double previousSampleRate = 0;      // session rate before
     double sampleRate = 0;              // session rate after (differs only when IO-021 (5) changed it)
   };
   // EngineEventPOD gains:   DeviceChangePOD device;   // set for deviceChanged
   ```
   The facade already emits `deviceChanged` with only `error` set when a start fails. Those events become `reason = startFailed`. `error` keeps meaning "the device isn't running now".
2. **Which device runs, in telemetry.** `TelemetryPOD` gains `uint32_t outputDeviceID` (0 while stopped), plus `uint64_t processorOverloads` and `uint64_t renderOverruns`. The two counters split `xruns` (IO-023) by source, so a check can tell the CoreAudio notification from a slow graph (DW-068). The `overload` event is unchanged (`count` = total xruns).
3. **Fake device through the facade (DW-089).** `DriverConfigPOD` gains `DeviceDriverKind driver = DeviceDriverKind::coreAudio` (`coreAudio`, `fake`). Realtime `create` with `fake` runs `FakeDeviceDriver` (TEST-005) on two made-up devices: id 1 "Fake Device A" (44.1/48/88.2/96 kHz) and id 2 "Fake Device B" (44.1 kHz only, so a fallback to it changes the session rate), paced in real time. `setDevice` can't switch the kind (`invalidArgument`). New:
   ```cpp
   enum class DeviceEventKind : uint8_t { deviceLost, deviceRestored, sampleRateChanged, processorOverload };
   struct DeviceEventPOD { DeviceEventKind kind; uint32_t deviceID = 0; /* 0: the running device */ double sampleRate = 0; };
   FacadeError simulateDeviceEvent(const DeviceEventPOD&);   // unsupported unless driver == fake
   ```
   It maps to `FakeDeviceDriver::inject`. That lets `dawctl`/`dawmcp` script a device loss and watch the `deviceChanged` event and telemetry.
4. **Behaviour that comes with it (no signature change).**
   - The facade owns a `DeviceMonitor`. Its host side does steps (1) to (7). Notifications come from `CoreAudioDeviceListener` (or the fake driver's queue) on a new `daw.device` thread, which runs the sequence under the facade lock. That thread isn't in the CONV §3 table; see Discovered work.
   - **DW-079:** `setDevice` with a different `sampleRate` now changes the session rate through the same step (5) as a fallback: transport stops, the graph is rebuilt at the new rate (a new `GraphCompiler`, since its rate is fixed at construction), and the driver restarts. Re-resampling loaded assets (IO-033) stays T-056's. Until then, assets loaded before a rate change keep their old rate, and the facade says so with an `assetsReloaded` event carrying `error = unsupported`.

Affected: T-051 (facade wiring, and the Swift `EngineEvent` / `TelemetrySnapshot` / `DriverConfig` mirrors in `EngineProtocol.swift`, `EngineClient.swift`, `FakeEngine`), T-018 (dawctl/dawmcp: select the fake driver, `device.simulate` command, show `deviceChanged`), T-055 (device toasts read `reason`/`deviceID`), T-056 (IO-033 replaces the asset placeholder in point 4).

### Contract delta (T-036, accepted (autobuild, see docs/autobuild/DECISIONS.md))
Additive. Offline renders turn the transport's loop off, so no golden could show a loop wrap
(TIME-005/006, DW-058, DW-073). `ExportSpecPOD` gets one field, after the existing ones:
```cpp
bool followLoop = false;   // keep the transport's loop and wrap at its end (io ExportSpec::followLoop)
```
`false`, the default, keeps today's straight-through render bit for bit. `true` makes
`OfflineDriver` leave the loop on: the export is still `tickToSample(to) − tickToSample(from)`
frames (plus the tail) of playback from `from`, wrapping at the loop end the way live playback
does (03 "Transport semantics", including the gap a loop shorter than a block leaves). Its
per-block playhead check follows the wrap. The Swift mirror is `ExportSpec.followLoop`
(EngineProtocol.swift), and `render.offline` exposes it as `loop` (13).

Affected: T-036 (implements it and the `loop_wrap_midblock` golden), T-033 (shares
`facade/` and `EngineProtocol.swift`; nothing existing moved).

### Contract delta (T-033, accepted (autobuild, see DECISIONS.md))
UI-011 draws waveforms from the IO-034 peak mipmaps, which the facade didn't expose. One **additive, read-only, non-RT** query:
```cpp
using FloatVector = std::vector<float>;
inline constexpr uint32_t kPeakLevelCount = 4;     // PeakMipmap::kBlockSizes: 256, 1024, 4096, 16384
struct PeakLevelPOD { bool found; uint64_t assetID; uint32_t channels; double sampleRate; int64_t frames;
                      uint32_t blockSize; int64_t blockCount;
                      FloatVector minMax; };        // channel-major pairs: [(c × blockCount + b) × 2] = min, +1 = max
PeakLevelPOD peaks(uint64_t assetID, uint32_t level) const;   // found == false until the asset has loaded
```
The facade computes the mipmap on `daw.loader` when an asset loads (before `assetLoaded` is queued) and `peaks` copies one level out. Swift: `EngineProtocol.peaks(_ assetID: ModelID, level: Int) -> PeakLevel?`, with a default `nil` in a protocol extension so test doubles compile unchanged; `FakeEngine` returns a deterministic made-up envelope for loaded assets.

Affected: T-033 (arrange canvas). No other task's calls change.

### Contract delta (T-043, accepted (autobuild, see docs/autobuild/DECISIONS.md))
UI-021 auditions notes through the engine, which the facade couldn't do. One **additive, non-RT** call:
```cpp
// Auditions `pitch` on the instrument fed by MIDI source node `source` (a MIDI track's
// MidiClipPlayer, GraphNodeID.source(of: track)), on MIDI channel 1, transport stopped or playing.
void previewNote(NodeID source, uint8_t pitch, uint8_t velocity, bool on);
```
- **Delivery.** The facade posts the note (under its lock, which only serializes producers) to a `MidiPreviewInbox` (`nodes/MidiClipPlayer.h`): one SPSC mailbox per player NodeID (32, claimed on first use, handed to another player only when empty and holding no note), no allocation after construction. The player drains its mailbox at frame 0 of its next block and writes the notes into its `midiOut` ahead of its own events, so they reach the track's instrument (sampler or plugin) over the T-045 MIDI edge, PDC delay included. Its writer reserve (06 MidiClipPlayer "Capacity") counts held preview notes, so a preview note-off is never dropped. A track without an instrument has no player (MODEL-020): the note goes nowhere.
- **Semantics.** Velocity is clamped to 1…127. A note-on for a pitch already sounding retriggers it (off, on); a note-off for a pitch that isn't sounding is dropped. Every note-on needs its note-off from the caller; in addition `stop()`, `locate()` and `renderOffline()` turn off every preview note still on. A re-created player (any note edit, DW-051) starts with All Notes Off and then turns the previews still held back on, so a preview lasts until its own off. A note-on is ignored in offline mode and while an export runs (only the export would hear it); a note-off never is.
- **Swift.** `EngineProtocol.previewNote(track: ModelID, pitch: UInt8, velocity: UInt8, on: Bool)`, with a default no-op in a protocol extension so test doubles compile unchanged; `EngineClient` passes `GraphNodeID.source(of: track)`; `FakeEngine` records `.previewNote(track:pitch:velocity:on:)` calls.

Affected: T-043 (piano roll audition). No other task's calls change. Tests: `PreviewNoteTests` (inbox, player merge, re-created player, mailbox reuse, no-hang fuzz, realtime facade on the fake device audible on the strip meter; 0 RT violations).

### Contract delta (T-056, accepted (autobuild, see docs/autobuild/DECISIONS.md))
IO-033 needs progress events for the re-conversion (DW-044), the facade must keep asset paths to re-load them (DW-118), and a project-driven rate change must work offline too, where `setDevice` is unsupported. Everything is **additive and defaulted**; no existing field, case or call changes meaning, except that the T-051 placeholder (point 4 of that delta: `assetsReloaded` with `error = unsupported`) is gone: assets are now re-converted.
```cpp
enum class AssetsReloadPhase : uint8_t { started, progress, finished };
struct AssetsReloadPOD {
  AssetsReloadPhase phase = AssetsReloadPhase::finished;
  double previousSampleRate = 0, sampleRate = 0;   // the change
  uint32_t done = 0, total = 0, failed = 0;        // assets
  uint64_t assetID = 0;                            // progress: the asset just done
};
// EngineEventPOD gains:  AssetsReloadPOD reload;          // assetsReloaded
// TelemetryPOD gains:    uint32_t assetsReloadPending = 0; // assets of the running pass still to come
FacadeError setSessionSampleRate(double rate);   // 44.1/48/88.2/96 kHz, either mode (see below)
JobID loadAsset(uint64_t assetID, const std::string& path, const std::string& peakCacheDir);  // DW-077
```
- `assetsReloaded` keeps its `EngineEventType` case; every session-rate change raises `started`, one `progress` per asset (`subject` = assetID, `count` = done) and `finished` (`error = io` if some asset failed to load again). A change during a pass abandons it without a `finished`; the new `started` supersedes it. No new `EngineEventType` case, so Swift switches over `EngineEvent.Kind` stay exhaustive.
- `setSessionSampleRate`: invalidArgument for another rate, no-op for the current one, unsupported during an export. Offline (or realtime without a driver) it stops the transport and changes the rate (rebuild at it, IO-033 pass). Realtime with a driver it is `setDevice` with the running config at that rate, so a device that can't run it is unsupported and nothing changes.
- `loadAsset` keeps each asset's path and peak-cache directory for IO-033 (DW-118); the three-argument form computes IO-034's peaks through `<peakCacheDir>/<assetID>.peaks` (DW-077). The two-argument form is the three-argument one with no directory.
- While a pass runs `play()` is refused and `renderOffline` waits for it (IO-033). *Changed by T-089:* `play()` is queued, see "Contract delta (T-089)".

Swift (`EngineProtocol.swift`, in its own block at the end): `AssetsReload`, `EngineEvent.reload`, `EngineTelemetry.assetsReloadPending`, and the requirements `setSessionSampleRate(_:)` and `loadAsset(_:path:peakCacheDirectory:)`, both with defaults in a protocol extension (refused / plain load), so other conformers compile unchanged. `FakeEngine` implements them (`refuseSessionRate`, `simulateEngineRateChange` test hooks).

Affected: T-056 only. T-055 (device toasts) may read `reload`; the app's `ToastCenter` already shows `assetsReloaded` only when it carries an error.

### Contract delta (T-052), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-052 contract")
09's REC-001..005 need a recordings folder, a punch range, the take on `recordingFinalized`, and drop and latency telemetry. Everything is **additive and defaulted**: `recordingFinalized` already was an `EngineEventType` case, `armInput` and `setRecording` keep their signatures, and no existing field changes meaning.
```cpp
struct RecordingPOD {               // EngineEventPOD gains:  RecordingPOD recording;
  NodeID track; std::string file;   // absolute path of the 32-bit float CAF
  int64_t startSample, frames;      // timeline sample of frame 0 (latency-compensated, may be < 0)
  uint32_t takeIndex = 0, channels = 2; double sampleRate; uint32_t inputPair; uint64_t droppedFrames;
};
// TransportPOD gains:  bool punchEnabled; Tick punchIn, punchOut;
// TelemetryPOD gains:  uint64_t recordDrops; uint32_t deviceInputLatency; uint32_t armedTracks;
void setRecordingDirectory(const std::string& directory);  // "" = $TMPDIR/EmberStudio-Recordings-<pid>
std::string recordingDirectory() const;
void setPunch(bool enabled, Tick in, Tick out);
```
- **Takes.** A take records while the transport plays with `setRecording(true)` and some track is armed, in realtime mode with a driver (offline engines have no input). It ends on `stop()`, `setRecording(false)`, a `locate()` while it runs, an `armInput` change, `renderOffline`, a device change (IO-021 (2), DW-119: finalized, not only disarmed) and destruction. Each armed track then gets one `recordingFinalized` event: `subject` = track, `count` = dropped frames, `recording` as above. `error` is set when frames were dropped (`io`, the file is usable, gaps are silence) or the file couldn't be written (`file` empty).
- **Latency (REC-003).** `startSample` = the transport sample the first captured frame was taken at, minus the running device's input + output latency (IO-005). Facade-internal: `DriverAdapter::latency()` (default zeros; CoreAudio and fake adapters report the running device), refreshed after every driver start.
- **Punch (REC-005).** `setPunch` with `enabled` and `in < out` (`in ≥ 0`) records only `[in, out)` while the loop is off. Disabling keeps the range, or stores a non-empty one passed with it. An enabled empty or negative range is ignored. Not persisted; `transport()` reports it.
- **IO seam (04, additive).** `DriverConfig::capture` (`InputCapture*`, `io/InputCapture.h`): `DeviceRenderer` hands it each block's input after `Engine::render`, on the audio thread (`DAW_RT`). The facade points it at its `Recorder` (`record/`).

Swift (`EngineProtocol.swift`): `RecordedTake` and `EngineEvent.recording`, `TransportState.punchEnabled/punchIn/punchOut`, `EngineTelemetry.recordDrops/deviceInputLatency/armedTracks`, and the requirements `setPunch(enabled:start:end:)` and `setRecordingDirectory(_:)`, with default no-ops in a protocol extension so other conformers compile unchanged. `FakeEngine` records both and counts armed tracks; tests post `recordingFinalized` themselves.

Affected: T-052. T-055 (arm/monitor buttons) uses `ArmTrack`/`SetMonitoring` and `EngineSync.setRecording`; T-054 (monitoring) and T-080 (loop takes, `takeIndex`) build on it. No other task's calls change. Tests: `RecordingTests` (DAWEngineTests, six checks incl. a loopback ±1 sample and device-loss finalize), golden `record_loopback_alignment`.

### Contract delta (T-061), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-061 contract")
AU hosting (10 PLUG-010, 012..016) fills the existing plugin calls and adds one **additive, read-only, non-RT** query. No existing signature, field or enum case changes.
- **`NodeKind::auPlugin` config.** The node's `configJSON` is `{"identifier": "type:subtype:manufacturer", "state": "<base64>"}` (`plugins/AUPluginConfig.h`); `state` (the binary-plist `fullState`, as `getPluginState` returns it) is optional. DAWModel writes it from a `.au` `DeviceSlot` (identifier, `pluginState`), keys sorted.
- **`instantiatePlugin(slot, plugin)`** instantiates the AU on the calling (non-RT) thread and parks it for `slot`; the build that brings the slot's auPlugin node adopts it. The job is finished when the call returns (`succeeded`, or `failed` with `notFound`/`unsupported`). VST3 descriptors fail with `unsupported` until T-062.
- **`getPluginState(slot)` / `setPluginState(slot, state)`** read and write the slot's AU `fullState` (binary plist) off the audio thread. With no AU yet, `setPluginState` holds the state for the slot's first AU; `getPluginState` returns the configured state of a slot whose plugin couldn't load (so a save keeps it), else empty. A refused state is reported as below.
- **Failures** (a component that isn't installed, a prepare that failed, a refused state) are `pluginCrashed` events with `subject` = the slot and `error` set. The node then renders as absent (an effect passes its input through, an instrument is silent); the graph isn't rejected. (No new `EngineEventType` case, so Swift switches stay exhaustive. PLUG-022's misbehaviour events are T-064's.)
- **New:** `std::string pluginInfoJSON(NodeID slot) const;` → `{"slot", "identifier", "loaded", "error"?, "name", "instrument", "midi", "sidechain", "inputChannels", "outputChannels", "latencySamples", "tailSeconds", "params": [{"index", "address", "id", "name", "unit", "min", "max", "value", "canRamp"}]}`, or `{"slot": n, "loaded": false}`. Param slot *i* of the auPlugin node drives `params[i]` (PLUG-015).
- **Swift:** `EngineProtocol.pluginInfoJSON(slot:) -> String`, with a default `""` in a protocol extension (own block at the end of `EngineProtocol.swift`); `EngineClient` forwards it. `ParamCatalog.defaultValue` is NaN ("not set") for hosted-plugin kinds, and `EngineSync` compares written values by bit pattern so a NaN isn't rewritten each update.

Affected: T-061 only. T-062 (VST3) should follow the same configJSON / NaN / pluginInfoJSON shape; T-063 (editors) and T-065 (device chain UI) read `pluginInfoJSON`.

### Contract delta (T-062), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-062 contract")
VST3 hosting fills the same calls for `.vst3` descriptors. No signature, field or enum case changes.
- `NodeKind::vst3Plugin` config: `{"identifier": "path#classUID", "state"?: "<base64>"}`; DAWModel writes it from a `.vst3` `DeviceSlot` as `.au` slots.
- `instantiatePlugin`, `getPluginState`/`setPluginState` and `pluginInfoJSON` work for VST3 slots (10 "Contract delta (T-062)"): state is the `EVS3` blob; `pluginInfoJSON` has the same shape, with `address`/`id` = the ParamID, `min` 0, `max` 1, `canRamp` false (normalized values). The facade routes each call by which host knows the slot; a `setPluginState` for a slot no host knows yet is held for its first plugin of either format.
- `pluginCrashed` events carry VST3 failures the same way.

### Contract delta (T-070), accepted (autobuild, see docs/autobuild/DECISIONS.md)
DSP-040 asks the NaN guards to bump telemetry (DW-142). **Additive and defaulted**; no existing field or call changes.
- `TelemetryPOD` gains `uint64_t nanBlocks = 0;` (and `TelemetrySnapshot`, `Telemetry::countNanBlock()`): the blocks the built-in effects' NaN guards silenced since the engine was created; each effect's silenced block counts once, so a bad input feeding two effects counts twice. It is a relaxed atomic bumped on the audio thread.
- Swift `EngineTelemetry.nanBlocks` mirrors it, so `engine.telemetry` (13) reports it.
- `paramInfoJSON` keeps its signature; it now reads `NodeRegistry::paramInfo(NodeKind)` (06 Interfaces, DSP-041). `.sampler` and `.eq` return their tables instead of `"[]"`.

Affected: T-070 only. No other task's calls change.

### Contract delta (T-053), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-053 contract", "T-053 routing", "T-053 placement")
09's REC-010..012 need MIDI input listing, arming, a test seam for timestamped MIDI, a finalize event carrying the recorded notes and a drop counter. Everything is **additive and defaulted**: `recordingFinalized` already was an `EngineEventType` case, and no existing field changes meaning.
```cpp
struct RecordedNotePOD { int64_t start, end; uint8_t pitch, velocity, channel; };   // timeline samples, compensated
using RecordedNoteVector = std::vector<RecordedNotePOD>;
struct RecordingPOD { /* T-052 */ bool midi = false; int64_t endSample = 0; RecordedNoteVector notes; };   // a MIDI take
struct MidiInputInfoPOD { int32_t uniqueID; std::string name; bool connected; };
// TelemetryPOD gains:  uint64_t midiInputDrops = 0; uint32_t armedMidiTracks = 0;
void armMidiInput(NodeID track, NodeID player, bool armed);          // player: the track's MidiClipPlayer (GraphNodeID.source)
std::vector<MidiInputInfoPOD> midiInputs() const;                    // CoreMIDI sources; empty on offline and fake-device engines
FacadeError injectMidi(int64_t atSample, bool relativeToNow, uint8_t status, uint8_t data1, uint8_t data2, uint8_t size);   // test seam
```
- **Routing (REC-011).** Every connected CoreMIDI source reaches every armed MIDI track on all channels, whatever the track's monitoring mode. Live events reach the instrument through the track's `MidiClipPlayer` (the T-045 MIDI path), so a track with no instrument has no player and records but sounds nothing. PDC for clips is unchanged.
- **Takes.** A MIDI take records while the transport plays with `setRecording(true)` and a MIDI track armed, in realtime mode with a driver, and ends like an audio take (T-052 "Takes"). Each armed track then gets one `recordingFinalized` event with `recording.midi` set, `recording.file` empty and `frames` 0; `droppedFrames` counts events the record buffer had no room for (`error` is set then). If no note was played, there is no event.
- **Placement (REC-012).** `startSample`/`endSample` and the notes are timeline samples: the transport sample an event was struck at minus the running device's output latency (IO-005), so the position the player heard. PDC isn't subtracted: the transport position already is what the graph outputs (MIX-023). With the loop on, a note keeps its transport position on the pass it was heard in, and one held across a wrap ends at the loop end.
- **Seam.** `injectMidi` is the test seam (`midi.inject`, 13): one MIDI message as if from a connected source, `atSample` a transport sample (`relativeToNow`: frames from the block about to render). A position already past, or a stopped transport, means now. Injected events hold back until their block; real CoreMIDI events are always due. Unsupported in offline mode.
- **Engine seams (facade-internal).** `core/LiveMidiInput.h` (`Engine::setLiveMidiInput`, `beginBlock`/`endBlock`/`idleBlock`, called after any MIX-023 pre-roll, so pre-roll chunks consume nothing), and `Engine::setCycleHostTicks` (DeviceRenderer sets it per IO cycle: the MIDI clock's anchor). `FacadeOptions::coreMidi` connects the facade to CoreMIDI (`io/CoreMidiInput`, thread `daw.midi`); only the default CoreAudio engine asks for it, so tests with driver adapters and fake devices never touch the MIDI server.

Swift (`EngineProtocol.swift`, in its own block at the end): `RecordedMidiNote`, `RecordedTake.endSample/notes/isMidi`, `MidiInputInfo`, `EngineTelemetry.midiInputDrops/armedMidiTracks`, and the requirements `armMidiInput(track:armed:)`, `midiInputs()` and `injectMidi(atSample:relativeToNow:status:data1:data2:)`, with defaults in a protocol extension (no-op, empty, `notImplemented`), so other conformers compile unchanged. `FakeEngine` records the calls and has `setMidiInputs(_:)`; `EngineClient` passes `GraphNodeID.source(of: track)` as the player.

Affected: T-053 only. T-054 (monitoring) is untouched: play-through ignores the monitoring mode by decision. T-080 (loop takes) builds on the record buffer's pass numbers. Tests: `MidiInputTests` (DAWEngineTests; REC-010 with synthetic timestamps, block boundaries, loop wrap, disarm while held, overflow, a real CoreMIDI virtual source, RT trap 0), `MidiRecordingModelTests`, `MidiRecordingControlTests`.

### Contract delta (T-082), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-082 normalize")
UI-042 asks for a normalize option in the export dialog. **Additive and defaulted**: no existing field changes meaning, and an export without it is bit-identical to before.
```cpp
struct ExportSpecPOD {    // after followLoop
  bool normalize = false; // scale the export so its sample peak is −0.1 dBFS, before dither and quantization
};
struct OfflineResultPOD { // after renderSeconds
  double peak = 0;          // the rendered sample peak (linear, before normalizing)
  double normalizeGain = 1; // the gain normalize applied (1 without it, or for silence)
};
```
- **Where (04, io).** `ExportSpec::normalize` and `kNormalizePeakDb = −0.1` (`io/ExportSpec.h`); `OfflineRenderStats` gets `peak` and `normalizeGain`. With `normalize`, `OfflineDriver` renders the range and tail once, as always (the RT trap, transport handling and determinism are unchanged), but writes the kept frames as interleaved float32 to an anonymous temp file (`tmpfile()`: unique per render and removed when closed, 00 §9) instead of the writer and the sink, tracking the peak. Then it reads the file back in `blockSize` chunks, scaled by `10^(−0.1/20) / peak` (gain 1 when the peak is 0 or not finite), into the `AudioFileWriter`, which dithers and quantizes as before, and the sink. Off the audio thread (the export thread); deterministic (IO-011): one render, one gain.
- **Swift.** `ExportSpec.normalize` (default false), `OfflineRenderResult.peak` / `.normalizeGain`; `EngineClient` maps them; `FakeEngine` records each `ExportSpec` (`exportSpecs`) and can fail the next render (`failNextRender`), test hooks only.

Affected: T-082 only. Tests: `OfflineDriverTests.normalize` (`offlineNormalize`), golden `export_normalize`, `ExportDialogTests`.

### Contract delta (T-064), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-064 bypass", "T-064 NaN event", "T-064 crash marker")
Host bypass (PLUG-018), the plugin NaN guard (PLUG-022) and safe mode (PLUG-021). Everything is **additive and defaulted**; no existing signature, field or enum case changes meaning.
- **`NodeDesc::bypassParam`** (05's `GraphDescription`, defaulted to `kNoBypassParam` = `0xFFFFFFFF`): the node's host-side bypass slot (10 "Contract delta (T-064)"). `GraphDescriptionBuilder` gains `addBypassableNode(id, kind, configVersion, firstParam, numParams, configJSON, bypassParam)`; `addNode` is unchanged and leaves it at none. Swift: `EngineGraph.Node.bypassParam: ParamID?` (nil = none), which `EngineClient` sends through `addBypassableNode`.
- **`EngineEventType::pluginMisbehaved`** (appended last): `subject` = the device slot whose plugin wrote NaN or infinity, `error` = `internal` with a message. Its output was silenced; reported once per node instance of the slot (a rebuild that re-creates the node can report again). AU and VST3. Swift: `EngineEvent.Kind.pluginMisbehaved`; the app shows it like `pluginCrashed` (one line in `ToastCenter`, so its switch stays exhaustive).
- **`TelemetryPOD.nanBlocks`** (T-070) also counts the blocks hosted plugins' guards silenced.
- **Control protocol (13):** `project.open` takes `safeMode?: Bool` (default false) and answers `safeMode: true` when set.

Affected: T-064. T-074 and T-054 add their own defaulted fields to `GraphDescription` in the same additive way; T-065 (device chain UI) shows bypass from the model and toggles it with `SetDeviceBypass`; T-083 (crash dialog) uses `CrashMarkerSession.crashedSessions` and `ProjectStore.open(_:recover:safeMode:)`.

### Contract delta (T-054), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-054 contract")
09's REC-020..022 need each audio track's monitoring in the graph, a way to run the device input without an arm, and the software monitoring latency. Everything is **additive and defaulted**:
```cpp
struct MonitorDesc { NodeID player; ParamID modeSlot; uint32_t inputPair; bool armed; };   // GraphDescription.h
struct GraphDescription { /* … */ std::vector<MonitorDesc> monitors = {}; };              // T-054, additive
void GraphDescriptionBuilder::addMonitor(NodeID player, ParamID modeSlot, uint32_t inputPair, bool armed);
void setMonitorInput(bool wanted);   // DW-067 extension: input also runs while `wanted`; a change restarts the driver
// TelemetryPOD gains:  uint32_t monitoringLatency = 0;   // device input + output + graph latency; 0 with no device running
//                      bool monitorInput = false;        // setMonitorInput's flag
```
- **Monitors.** These follow 09's T-054 delta. The mode is a param slot (`setParam`, no rebuild); `armed` and `inputPair` are structural. GraphBuilder validates monitors (`invalidArgument`). A description without monitors (graphs built by hand, older callers) renders as before.
- **Engine seams (facade-internal).** `core/InputMonitoring.h` holds `MonitoringMode`, `monitoringActive` (REC-020's truth table), `kMonitorFadeFrames` and `MonitorInput`. `RenderGraph::process` takes an optional `MonitorInput`, and `RenderStepDesc` an optional `RenderMonitorDesc`. `Engine::render` passes `RenderTarget::input`; the MIX-023 pre-roll passes none, so active steps output silence.

Swift (`EngineProtocol.swift`): `EngineGraph.Monitor`, `EngineGraph.monitors` (default empty), `EngineGraph.MonitoringSlot`, `EngineTelemetry.monitoringLatency/monitorInput`, and the requirement `setMonitorInput(_:)` with a no-op default in a protocol extension. `EngineClient` passes the monitors through `addMonitor`.

Affected: T-054 only. T-064/T-074 add their own GraphDescription fields next to `monitors`. Tests: `MonitoringTests` (DAWEngineTests), `MonitoringModelTests`, `GraphDescriptionBuilderTests` "monitors", `RecordingUITests` "monitoringLatency".

### Contract delta (T-074), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-074 contract")
Additive; the automation contract itself is 11 Interfaces and 11 "Contract delta (T-074)".
- **`GraphDescription.automation`** (`include/daw/GraphDescription.h`): `std::vector<AutomationDesc> automation{}`, a defaulted last member, with 11's `AutomationPointDesc`/`AutomationDesc` declared next to it. Existing aggregate initializations keep compiling and mean "no lanes".
- **`GraphDescriptionBuilder`** gains `addAutomation(laneID, target, enabled)` and `addAutomationPoint(tick, value, curve, shape)`. A point goes to the lane added last.
- **Swift:** `EngineGraph.automation: [EngineGraph.Automation]` (`laneID`, `target`, `points: [Point{tick, value, curve, shape}]`, `enabled`), default `[]`. `EngineClient` converts it both ways, and `FakeEngine` records it with the rest of the graph. A lane edit is structural (MODEL-021): the graph changes and is re-applied. Param values still travel only through `setParam`.

### Contract delta (T-089), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-089 queued play", "T-089 reset"; pre-accepted in T-089's briefing)
Additive.
```cpp
// TransportPOD gains:
bool playPending = false;  // IO-033: play() came while assets re-convert; starts when they are done
```
- **`play()` during a re-conversion is queued** (IO-033, user decision 2026-11-10; T-056 refused it). The facade remembers it (`playPending`), and when the pass finishes (assets swapped, graph rebuilt) it prepares recording (REC-001) and starts the transport, from wherever the playhead is then (a `locate()` meanwhile moves it and keeps the pending play). `stop()` cancels it, as does the IO-021 stop on a device change. `transport()` reports `playPending`; `playing` stays false until the transport really starts. Without a pass running, `play()` is unchanged and `playPending` is never set.
- **Offline renders reset every node** (DW-063, IO-011 clarified in 04). `renderOffline` is unchanged at the facade; the OfflineDriver asks the engine to reset the whole graph before the first block. Live `locate()` is unchanged (TIME-008).
- **Tempo edits keep the playhead's tick** (DW-061, 03 "Tempo edits, short loops"): `transport()` after an `applyGraph` with a new tempo shows the same `tick` (and a new `sample`), stopped or playing. No API change.

Swift: `TransportState.playPending: Bool` (default false), filled by `EngineClient.transport()`. `FakeEngine` never sets it (it has no re-conversion).

Affected: T-089 only. `ui.state`/toolbar (T-034, App) may show the pending state later; the control protocol carries it (13 "Contract delta (T-089)").

## Status
| ID | status | test |
|---|---|---|
| BRIDGE-001 | done (T-014) | `EngineClientTests` "the facade is a Swift class reference; created and destroyed repeatedly without leaks" (`instanceID`/`isLive`) |
| BRIDGE-002 | done (T-014) | `FacadeTests` export job via `pollJob`; `EngineClientTests` loadAsset on daw.loader, renderOffline on a job thread; `waitForGraph`/`graphStatus` |
| BRIDGE-003 | done (T-014) | `EngineClientTests` "EngineGraph crosses as a GraphDescription built through GraphDescriptionBuilder" |
| BRIDGE-004 | done (T-014) | `EngineClientTests` loadAsset status and events (`assetLoaded`/`assetLoadFailed`); `graphRejected`, `jobFinished` |
| BRIDGE-005 | done (T-014) | `EngineClientTests` "telemetry, meters, plugin stubs and param info cross as Swift values"; `FacadeTests` strip meters via `meter(NodeID)` (DW-071) |
| BRIDGE-006 | done (T-014) | `EngineClientTests` (strings, `ByteVector` ↔ `Data`, plugin stubs; DW-017) |
| BRIDGE-007 | done (T-014) | suite "FakeEngine (BRIDGE-007)": "the model drives the engine through EngineProtocol; FakeEngine records it"; FakeEngine mirrors rejection, asset events, jobs |
| BRIDGE-008 | done (T-014) | `EngineClientTests` offline mode (bad rate throws, no device); `FacadeTests` realtime mode drives a `DriverAdapter`, `setDevice` restarts it (fake driver; `CoreAudioDriverAdapter` in realtime) |
