# 10 — Plugin Hosting (AU + VST3)

**Depends on:** 02 (Node API), 05 (sidechain edges, PDC), 08 (facade) · **Owns:** `Sources/DAWEngine/plugins/`, `Sources/PluginScanner/`.

## Requirements

### Scanning
| ID | Requirement | Acceptance |
|---|---|---|
| PLUG-001 | `PluginScanner` is a separate executable. The app launches it per plugin (or per batch) and it prints a JSON descriptor to stdout. A timeout (10 s) or crash → plugin marked `blocked` with a reason. | Test with a deliberately crashing fake bundle |
| PLUG-002 | AU discovery via `AVAudioUnitComponentManager` (types `aufx`, `aumu`, `aumf`), including AUv3 app extensions. | — |
| PLUG-003 | VST3 discovery: `/Library/Audio/Plug-Ins/VST3`, `~/Library/Audio/Plug-Ins/VST3`. Load the module, enumerate classes (`kVstAudioEffectClass`), read bus arrangement and sidechain bus presence. | — |
| PLUG-004 | Cache: `~/Library/Application Support/macDAW/plugins.json` keyed by path + mtime + version. Rescan only changed or new entries; blocked list is user-resettable. | — |

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

## Status
| ID | status | test |
|---|---|---|
| PLUG-* | todo | |
