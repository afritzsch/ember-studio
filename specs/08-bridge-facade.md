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

### PROPOSED (T-014): deltas to the contract above
The user approved implementing these on the T-014 branch, marked PROPOSED. The lead confirms or rejects them at merge.

1. **`setDevice` returns `FacadeError`, not `Result<void>`.** `core/Result.h` isn't on the include path Swift sees (`include/` only, 01 Interfaces), and Swift can't call `Result::value()` (DW-022). `FacadeError { FacadeErrorCode code; std::string message; std::vector<NodeID> cycle; }`, where `code == none` means success. It is also how jobs and graph builds report errors. `FacadeErrorCode` mirrors `daw::ErrorCode` plus `none`. For `cycle`, `Error::nodes` crosses as `FacadeError::cycle` (DW-050).
2. **`EngineEventType` (04 Interfaces) is defined in `EngineFacade.h` and gets more cases.** Swift has to see the enum, so it can't live in `io/`. The added cases are facade-produced: `assetLoaded`, `assetLoadFailed` (DW-041; the model re-applies the graph with the affected clip players' `configVersion` bumped, DW-051), `graphRejected` (a failed build, e.g. a cycle) and `jobFinished`. `overload` is raised when telemetry's xrun count grows (IO-023).
3. **Additive facade API.** `GraphStatusPOD graphStatus() const` and `GraphStatusPOD waitForGraph(uint64_t version, uint32_t timeoutMs)` let callers learn the outcome of a build without callbacks (BRIDGE-002). `std::vector<NodeLatencyPOD> nodeLatencies() const` covers CTL `engine.telemetry`'s per-node latency. `applyGraph` stamps the description's `version` itself (1, 2, …) and returns it, so versions are unique and `TelemetryPOD.graphVersion` can be waited on (DW-047). `GraphDescriptionBuilder` (BRIDGE-003) is declared in `EngineFacade.h`.
4. **Swift `EngineProtocol.applyGraph(_ graph: EngineGraph) -> UInt64`** takes `EngineGraph`, a Swift value mirror of `GraphDescription`, instead of `(Project, RuntimeIDs)`. Turning a Project into a description is MODEL-020 (T-016), and `RuntimeIDs` (MODEL-022) doesn't exist yet. A plain value keeps the protocol a mirror of the facade, lets `FakeEngine` record exactly what would cross, and gives T-016 something to snapshot-test. T-016 can add `applyGraph(_ project:runtime:)` as an extension on top.
5. **The facade's config type is `DriverConfigPOD`.** T-011 defined `daw::DriverConfig` in `io/DriverConfig.h` (04 `AudioDriver::start`), which Swift can't see, and two `daw::DriverConfig`s can't coexist. So `create`/`setDevice` take `DriverConfigPOD`, which mirrors the io fields (device AudioObjectIDs, rate, `bufferFrames`, channels). It leaves out `inputEnabled`, which the facade derives from `armInput` (DW-067: turning input on or off restarts the driver). `DeviceInfoPOD` identifies devices by `deviceID` (AudioObjectID).

Affected: T-016 (builds `EngineGraph`, reacts to `assetLoaded`), T-017/T-018 (dispatcher uses `EngineProtocol`, `waitForGraph`, events), T-011/T-051 (driver adapter seam `facade/DriverAdapter.h`, `DriverConfig` defined in `EngineFacade.h`; IO-021/023 events).

## Status
| ID | status | test |
|---|---|---|
| BRIDGE-* | todo | |
