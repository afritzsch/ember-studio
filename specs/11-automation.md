# 11 — Automation

**Depends on:** 02 (param slots, smoothing), 03 (ticks, segments), 07 (model, Commands) · **Owns:** `Sources/DAWEngine/automation/`, `Sources/DAWModel/Automation/`.

Block-rate evaluation with per-block linear ramps (D-13).

## Model
```swift
struct AutomationLane: Codable { id; target: ParamTarget   // (slotID, paramIndex) or strip gain/pan/send level
  points: [AutomationPoint]  // sorted by tick
  mode: .read | .touch | .latch | .write | .off }
struct AutomationPoint: Codable { tick: Tick; value: Float /* normalized 0..1 */; curve: .linear | .hold | .exp(Float) }
```

## Requirements
| ID | Requirement | Acceptance |
|---|---|---|
| AUTO-001 | Lanes are part of the GraphDescription (`AutomationDesc{paramID, points[]}`) and are compiled into an `AutomationPlayer` per lane in the RenderGraph (sorted arrays, cursor cached between blocks). | — |
| AUTO-002 | Per block (per TransportSegment) the engine evaluates each lane at the **segment start tick** and writes the value into the target ParamSlot **before** nodes process. Nodes then ramp from the previous value (ENG-022). | Golden: linear ramp 0→1 over 1 bar matches analytic within 1 block of error |
| AUTO-003 | A loop wrap within a block evaluates at the second segment start too; the smoother jumps instead of ramping across a wrap (avoids ramping across a discontinuity). | Golden |
| AUTO-004 | Curve types: linear, hold (step), exponential (shape param). | Unit |
| AUTO-005 | Mode `read`: automation overrides user changes during playback. `off`: lane ignored. | — |
| AUTO-006 | Modes `touch/latch/write` (recording automation): UI gestures during playback are captured on the main thread with timestamps (playhead tick from TIME-009), thinned (Ramer–Douglas–Peucker, ε = 0.5 % range) and committed as **one** command at gesture end (`touch`: return to existing curve after release; `latch`: hold last value until stop; `write`: overwrite everything while playing). | Unit on thinning and mode semantics |
| AUTO-007 | When stopped, automated params show the lane's value at the playhead; moving the control while stopped edits the point under the playhead if one exists, else offsets nothing (v1). | — |
| AUTO-008 | Automatable targets: strip gain/pan/mute, send level, built-in params (`ParamInfo.automatable`), plugin params (PLUG-015). | — |
| AUTO-009 | Plugin params receive the evaluated value through the plugin param path (VST3 `IParameterChanges` at offset 0, AU param events), not just the slot. | Golden with test VST3 |
| AUTO-010 | Automation is not latency compensated in v1 (MIX-025). | Documented |

## Interfaces (contract)
```cpp
struct AutomationPointDesc { Tick tick; float value; uint8_t curve; float shape; };
struct AutomationDesc { uint64_t laneID; ParamID target; std::vector<AutomationPointDesc> points; bool enabled; };
// GraphDescription gains: std::vector<AutomationDesc> automation;   (additive to 05)
```

## Status
| ID | status | test |
|---|---|---|
| AUTO-* | todo | |
