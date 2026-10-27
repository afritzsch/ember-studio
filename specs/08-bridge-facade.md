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

## Status
| ID | status | test |
|---|---|---|
| BRIDGE-* | todo | |
