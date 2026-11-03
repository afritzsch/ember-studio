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
- While a pass runs `play()` is refused and `renderOffline` waits for it (IO-033).

Swift (`EngineProtocol.swift`, in its own block at the end): `AssetsReload`, `EngineEvent.reload`, `EngineTelemetry.assetsReloadPending`, and the requirements `setSessionSampleRate(_:)` and `loadAsset(_:path:peakCacheDirectory:)`, both with defaults in a protocol extension (refused / plain load), so other conformers compile unchanged. `FakeEngine` implements them (`refuseSessionRate`, `simulateEngineRateChange` test hooks).

Affected: T-056 only. T-055 (device toasts) may read `reload`; the app's `ToastCenter` already shows `assetsReloaded` only when it carries an error.

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
