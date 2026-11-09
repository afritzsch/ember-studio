# 10 — Plugin Hosting (AU + VST3)

**Depends on:** 02 (Node API), 05 (sidechain edges, PDC), 08 (facade) · **Owns:** `Sources/DAWEngine/plugins/`, `Sources/PluginScanner/`.

## Requirements

### Scanning
| ID | Requirement | Acceptance |
|---|---|---|
| PLUG-001 | `PluginScanner` is a separate executable. The app launches it per plugin (or per batch) and it prints a JSON descriptor to stdout. A timeout (10 s) or crash → plugin marked `blocked` with a reason. | Test with a deliberately crashing fake bundle |
| PLUG-002 | AU discovery via `AVAudioUnitComponentManager` (types `aufx`, `aumu`, `aumf`), including AUv3 app extensions. | — |
| PLUG-003 | VST3 discovery: `/Library/Audio/Plug-Ins/VST3`, `~/Library/Audio/Plug-Ins/VST3`. Load the module, enumerate classes (`kVstAudioEffectClass`), read bus arrangement and sidechain bus presence. | — |
| PLUG-004 | Cache: `~/Library/Application Support/Ember Studio/plugins.json` keyed by path + mtime + version. Rescan only changed or new entries; blocked list is user-resettable. | — |

### Hosting node
| ID | Requirement | Acceptance |
|---|---|---|
| PLUG-010 | `AUPluginNode`: instantiate `AUAudioUnit` (in-process for v2, out-of-process allowed for v3 using `kAudioComponentInstantiation_LoadOutOfProcess` when available). `allocateRenderResources` in `prepare`; render via `renderBlock` with a preallocated `AudioBufferList`; MIDI via `scheduleMIDIEventBlock` (for instruments) with frame offsets. | Golden with Apple's built-in `AUDelay`/`AUSampler` |
| PLUG-011 | `VST3PluginNode`: `IComponent` + `IAudioProcessor` + `IEditController`, `setupProcessing`, `setActive`, `setProcessing` in `prepare`; `process()` with preallocated `ProcessData`, `EventList` (note on/off), `ParameterChanges` (one point per block at offset 0, block-rate per D-13), `ProcessContext` filled from TransportBlock (tempo, ppq position, playing flag). | Golden with a test VST3 (e.g. SDK `again` sample built in Vendor) |
| PLUG-012 | Instantiation happens off the audio thread (`daw.compile` or main thread when the plugin requires it — AU and VST3 controllers with UI: main thread). The node enters the graph only after prepare succeeds. | — |
| PLUG-013 | Latency: AU `latency` property / VST3 `getLatencySamples()`. Change notifications (`kAudioUnitProperty_Latency` listener / `IComponentHandler::restartComponent(kLatencyChanged)`) → MIX-024. | Unit with fake plugin reporting latency change |
| PLUG-014 | Sidechain: if the plugin has an aux input bus, expose sidechain port 1 (MIX-008). | — |
| PLUG-015 | Parameters: plugin params are mirrored to ParamSlots on demand (only automated or UI-touched params get slots). Block-start slot changes are pushed to the plugin (AU `AUParameter.setValue` from the render thread via `AUParameterTree` is **not** RT-safe → use AU render-thread param events / VST3 `IParameterChanges`). Plugin-originated changes (UI knob) → `IComponentHandler::performEdit` / AU parameter observer → main thread → model `SetParam` (gesture-coalesced via `beginEdit/endEdit`). | — |
| PLUG-016 | State: AU `fullState` (plist → binary plist) / VST3 component + controller state via `IBStream` (MemoryStream). Get and set happen off the RT thread. | Round-trip test |
| PLUG-017 | GUI: AU `requestViewController` / VST3 `IPlugView` attached to an `NSView` in a floating `NSPanel`. Resize negotiation for VST3 (`IPlugFrame::resizeView`). All on the main thread. | Manual + UI snapshot via MCP |
| PLUG-018 | Bypass: host-side bypass (pass-through with latency-matched delay to keep PDC stable). | Golden null test |

### Crash policy (D-07)
| ID | Requirement |
|---|---|
| PLUG-020 | No sandboxing in v1. The autosave (MODEL-044) is the mitigation. |
| PLUG-021 | On launch after a crash (detected via a `running` marker file not cleaned up), show which plugins were in the last session and offer to open the project with plugins **disabled** (slots kept, state preserved, bypassed). |
| PLUG-022 | `NaN`/inf output from a plugin → output silence for that node, set telemetry flag, emit `pluginCrashed`-class event `pluginMisbehaved{slot}`. |

## Interfaces (contract)
```cpp
struct PluginDescriptorPOD { uint8_t format; /*au=0, vst3=1*/ std::string identifier; /* AU: type:subtype:manufacturer, VST3: path#classUID */
                             std::string name, vendor, version; bool isInstrument, hasSidechain; uint32_t numParams; };
```
Scanner stdout JSON = array of `PluginDescriptorPOD` fields + `{status: ok|blocked, reason?}`.

### Contract delta (T-061), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-061 contract")
Additive; the facade side is in 08 "Contract delta (T-061)". How the AU half is hosted (`Sources/DAWEngine/plugins/`):
- **Identity and config.** `NodeKind::auPlugin`'s `configJSON` = `{"identifier", "state"?}`. The identifier follows the scanner's `AudioUnitIdentifier` (four-character codes, `0x` + 8 hex digits otherwise).
- **One AU per slot** (`AUPluginHost`). A slot's AU outlives node re-creations (configVersion bumps, a changed param range), so edits never reset its DSP or lose state; a new AU is made only for a new slot, a changed identifier, or a session-rate change (the new AU gets the old one's state). Instantiation runs on `daw.compile` (or the caller's thread for `instantiatePlugin`), in-process; an AUv3 that can't load in-process is loaded out of process (waits ≤ 10 s). The node is rendered only once `prepare` (formats, `maximumFramesToRender`, `allocateRenderResources`) has succeeded (PLUG-012).
- **Render** (PLUG-010): stereo bus formats where the AU accepts them (else mono, summed/duplicated), main input bus enabled, preallocated `AudioBufferList` and scratch buffers, `renderBlock` with a pull-input block; MIDI from `NodeIO::midiIn` through `scheduleMIDIEventBlock` at `AUEventSampleTimeImmediate + frameOffset`; host musical-context and transport-state blocks from the block's `TransportBlock`. No Objective-C message on the audio thread. Apple's AUDelay/AUSampler/AUMIDISynth render, schedule MIDI and take parameter events without allocating, so the RT trap needs no exemption.
- **Params** (PLUG-015): param slot *i* drives the AU parameter at index *i* of `parameterTree.allParameters` (listed by `pluginInfoJSON`). Slots whose generation moved are pushed at block start through `scheduleParameterBlock` (clamped; ramped over the block if the parameter can ramp). NaN = not set: the plugin keeps its value. The plugin→model direction (AU parameter observer → `SetParam`, gesture-coalesced) is left to T-063, where plugin-side edits first appear.
- **Latency** (PLUG-013): `latency` at prepare, then KVO; a change goes to the node's `LatencyReporter` from a global dispatch queue (MIX-024).
- **Sidechain** (PLUG-014, DW-159): the AU's aux input bus (bus 1) is enabled and fed from `NodeIO::sidechain` (graph `toPort` 0).
- **State** (PLUG-016): `fullState` ↔ binary plist, off the RT thread.

### Contract delta (T-062), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-062 contract")
Additive; the facade side is in 08 "Contract delta (T-062)". The VST3 half (`Sources/DAWEngine/plugins/VST3*`) mirrors the AU half of the T-061 delta:
- **Identity and config.** `NodeKind::vst3Plugin`'s `configJSON` = `{"identifier": "path#classUID", "state"?}` (the scanner's identifier, class UID as 32 hex digits, canonically uppercase; state as `getPluginState` returns it, base64).
- **One instance per slot** (`VST3PluginHost`), the same rules as `AUPluginHost`, including a failed load rendering as absent (`pluginCrashed`, the graph isn't rejected). Modules load and unload under one process-wide mutex.
- **Render** (PLUG-011): every bus the plugin declares gets channel buffers (`AudioBusBuffers`, unused buses too); main in/out stereo where accepted, else mono (mono output duplicated). All process inputs (scratch buffers, `ProcessData`, event/param lists, `ProcessContext`) are preallocated in `prepare`. Fixed-capacity `IEventList` and `IParameterChanges` of our own, with `addEvent`/`addPoint`/`addParameterData` allocation-free, since the SDK helpers grow vectors. `ProcessContext` from `TransportBlock`: tempo, ppq, bar position, time signature, playing, continuous time. Notes in `NodeIO::midiIn` become note on/off events at their frame offsets (other MIDI: T-063/discovered work). The audio thread calls the plugin only through the `IAudioProcessor` vtable; RT safety of plugin code is verified by the RT trap, not assumed.
- **Params** (PLUG-015): param slot *i* drives the *i*-th parameter of `IEditController::getParameterInfo`. One point per block at offset 0 (D-13), clamped to 0…1. **VST3 values are normalized:** `pluginInfoJSON` reports `min 0, max 1, canRamp false`, and the model/automation see normalized values. NaN = not set. Read-only parameters (meters) aren't pushed. Pushed values are written to the controller off the RT thread before `params(true)`/`state()` read it. The plugin → model direction is T-063 (DW-204): `IComponentHandler::performEdit/beginEdit/endEdit` are accepted no-ops.
- **Latency** (PLUG-013): `getLatencySamples()` at prepare; `restartComponent(kLatencyChanged)` from any thread only sets an atomic flag, and a 50 ms timer on a utility queue re-reads latency off the RT thread and reports it through the node's `LatencyReporter` (MIX-024).
- **Sidechain** (PLUG-014, DW-159): the first `kAux` audio input bus is activated and fed from `NodeIO::sidechain` (graph `toPort` 0).
- **State** (PLUG-016): one blob: magic `EVS3`, u32 version 1, u64 component length, component state, u64 controller length, controller state (little-endian), through `MemoryStream`, off the RT thread. Restore calls `IComponent::setState`, then `IEditController::setComponentState` and `setState`.
- **Editor seam** (T-063): `VST3Instance::editController()` is the `IEditController` for `createView`; `EngineFacade::createPluginView` is still a stub.

## Status
| ID | status | test |
|---|---|---|
| PLUG-001..004 | done (T-060) | `PluginScannerTests` (launcher crash/timeout → blocked with fake VST3 bundles, VST3 probe, AU scan of Apple built-ins, cache rescan). AUv3 extension path not covered by an automated test |
| PLUG-010 | done for AU (T-061) | `AUPluginTests` (identifier/configJSON round trip; AUDelay echo at 0.25 s with param slots as render-thread events; MIDI at exact frame offsets, fake AU + AUSampler; 0 RT violations); golden `AUGoldenTests` AUSampler instrument nulls against AVAudioEngine at ≤ −90 dBFS (−156.5 measured; no stored reference, DECISIONS "T-061 golden"); `PluginControlTests`. VST3 half: T-062 |
| PLUG-012 | done for AU (T-061) | `AUPluginTests` "a missing AU renders as absent and is reported; slots keep their AU; parked AUs are adopted" (`pluginCrashed` event, graph never rejected) |
| PLUG-013 | done for AU (T-061) | `AUPluginTests` "AU latency change (KVO) rebuilds the graph and PDC keeps paths aligned" (0 → 480 → 0) |
| PLUG-014 | done for AU (T-061) | `AUPluginTests` aux input bus fed from the node's sidechain port (test-only AUv3; no Apple FX has an aux bus) |
| PLUG-015 | done for AU, host → plugin (T-061) | `AUPluginTests` AUDelay slot pushes; `AUSlotModelTests` (NaN = not set, written once); `engine.pluginInfo`. Plugin → model direction: T-063 (DW-204) |
| PLUG-016 | done for AU (T-061) | `AUPluginTests` fullState round trip off the RT thread, survives a rate change; `AUSlotModelTests`; `PluginControlTests` (`Plugins/<slot>.state` bplist); `AppModelTests` app saves capture live state |
| PLUG-* (rest) | todo | |
