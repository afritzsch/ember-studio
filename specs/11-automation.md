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

### Contract delta (T-074), accepted (autobuild, see docs/autobuild/DECISIONS.md "T-074 contract", "T-074 wrap jump")
The Interfaces above are implemented as written. The additions below are additive POD/facade plumbing (facade side: 08 "Contract delta (T-074)").
- **Wire values.** `AutomationPointDesc.curve`: 0 linear, 1 hold, 2 exponential. `shape` is used by exponential only: `w(f) = (e^(s·f) − 1)/(e^s − 1)`, with |s| < 1e-4 treated as linear and s clamped to ±50 (`automation/AutomationCurve.h`). A point's curve shapes the segment that starts at it. Before the first point a lane holds the first value, and after the last point it holds the last.
- **Mapping (AUTO-008).** Values are normalized 0…1. GraphBuilder maps them through the range of the node whose param range holds `target`:
  - built-ins use their ParamInfo row: `linear` is min + v·(max − min), `log` is min·(max/min)^v, and `db` is dB-linear. A db range that reaches 0 (strip gain, send level) maps v = 0 to silence and otherwise runs dB-linear from −60 dB to 20·log10(max). For the 0…+12 dB fader, v = 5/6 is unity.
  - AU params map linearly over the AU parameter's min…max.
  - VST3 params pass through unchanged (they are already normalized).
  - A lane is left out when it is disabled (`off`), has no points, targets a slot that no node in the graph owns (a removed send or device; since T-064 a bypassed device stays in the graph, inside a BypassNode, and its lanes keep driving its slots), or targets a row that isn't `automatable`.
  - GraphBuilder rejects (`invalidArgument`) unsorted or repeated ticks, non-finite values or shapes, unknown curves and targets outside the table.
- **Engine (AUTO-001/002/003).** `automation/`: `AutomationPlayer` (sorted points, cursor cached between blocks, binary search on a jump), `AutomationSet` (the RenderGraph's players, `RenderGraph::automation()`) and `AutomationCompiler`. `Engine::render` applies the set after `Transport::advance` and before the pre-roll and the nodes.
  - While playing, each lane is evaluated at `seg[0].startTick` and written to its slot. A slot is written only when its value changes, so slot generations, and with them plugin pushes, move only on real changes.
  - With two segments, each lane is also evaluated at `seg[1].startTick`, and that value is registered as the slot's value after the wrap (`ParamSlotTable::beginBlock/setAfterWrap/afterWrap`, stamped per block). `ParamRamp` gains `jumpAt`/`after`, and `ParamSmoother::next(target, n, WrapJump)` ramps to the first value over segment 1 and jumps at the wrap frame (`automation/WrapJump.h` reads it for a node).
  - `ChannelStrip` (gain, pan, mute, phase) and `GainNode` (send level and mute) honor the jump. Other built-ins and hosted plugins still ramp across a wrap and pick up the loop start's value in the next block. This is a known gap, listed in T-074 Discovered work.
- **AUTO-005.**
  - `read`: during playback the lane is re-applied every block, so a `SetParam` (a slot write between blocks) is overridden from the next block.
  - `off`: the lane goes to the engine with `enabled = false` and is ignored.
  - `touch`/`latch`/`write` play like `read` until T-075 adds recording.
  - **While stopped**, each lane writes its value at the playhead once whenever the stopped position or the graph changes (after a stop, a locate while stopped, or a lane edit). A `SetParam` made while stopped holds until playback starts or the playhead moves. That is the engine half of AUTO-007; what the controls show stays T-075's.
- **AUTO-009.** A lane writes the slot, and the existing slot → plugin path delivers it: AU render-thread parameter events (ramped over the block where the parameter can ramp), and a VST3 `IParameterChanges` point at offset 0. A plugin param with a lane gets a param slot even without a stored value (`paramRequirements`).
- **AUTO-010.** Automation follows the transport's own block, not the MIX-023 look-ahead block that timeline nodes get. A param behind L samples of latency therefore changes L samples early (MIX-025).
- **Model.**
  - `AutomationLane {id, target: ParamTarget, points, mode}` and `AutomationPoint {tick, value, curve: linear | hold | exp(shape)}`. In JSON, `curve` defaults to linear and `shape` is present only with `"exp"`.
  - Lanes live in `automation` on the channel that owns their target (a strip's channel, a send's or a device's channel), sorted by lane ID, with one lane per target in the project. A lane outlives its target (a removed send or device), stays valid, and is left out of the graph, so undoing the removal brings the automation back.
  - `validate()` checks point order and range (ticks 0…`Tick.timelineEnd`, values 0…1, |shape| ≤ 50), lane ID order, one lane per target, and automatable targets: strip gain, pan and mute, send level, and device params. Solo and phase are not automatable. Built-in `automatable` flags are applied by the engine. A Track without an `automation` key decodes with no lanes.
  - A strip mute lane drives the strip's mute slot and every send's mute slot (MIX-007). It is disabled while solo mutes the channel (MIX-006), so solo never leaks through an automated mute.
- **Commands** (MODEL-005, all undoable):
  - `AddAutomationPoint {target, point}` and `AddAutomationPoints {target, points}` create the lane (mode `read`) if the target has none.
  - `RemoveAutomationPoints {target, ticks}`.
  - `MoveAutomationPoints {target, ticks, deltaTicks, deltaValue}`. Nothing is clamped: a move that leaves the timeline or 0…1, or collides with another point, is rejected.
  - `SetAutomationMode {target, mode}` creates an empty lane if needed.
  - Every inverse is `SetAutomationLane {channel, target, lane?}`, which sets the lane to exactly that lane with its ID, or removes it. It is registered like any command.

### Clarification (T-088): lanes leave with their target (DW-234, user decision; docs/autobuild/DECISIONS.md "T-088 cascade")
This replaces the sentence of the T-074 delta that says a lane outlives its removed send or device. The Interfaces don't change.
- Removing a send or device slot removes the lanes driving it in the same undo step: `RemoveSend`, `RemoveDevice`, `RemoveInstrument`, `SetInstrument` replacing an instrument, `RestoreInstrument` replacing a slot with another ID, and `RemoveBus` for the sends into the bus. Undo restores the target and then its lanes, with their IDs, points and mode (`SetAutomationLane` steps of one `CompositeCommand`), and redo removes both again. 07 "Contract delta (T-088)" has the full rule.
- A lane whose target is missing anyway (a file saved before T-088, or `SetAutomationLane` on a missing target) still validates and is left out of the graph. Restoring its send or device adopts it. Undoing that restore puts the lane back as it was, so undo stays exact.

## Status
| ID | status | test |
|---|---|---|
| AUTO-001 | done (T-074) | `AutomationTests` `automationCompile` (lanes validated and compiled into players); `AutomationModelTests` (lanes go into the graph on their slots, cross the C++ builder, an automation edit applies a graph) |
| AUTO-002 | done (T-074) | golden `automation_ramp` (+ `AutomationGoldenTests`: within one block of the analytic ramp); `automationDrivesSlots` (written before nodes run) |
| AUTO-003 | done (T-074) for strip and gain nodes | golden `automation_loop_wrap` (jumps at each wrap frame); `automationLoopWrapJump`. Other built-ins and plugins still ramp across a wrap (DW-232, DW-233) |
| AUTO-004 | done (T-074) | `AutomationTests` `automationCurves` (linear, hold, exponential; cursor; mapping) |
| AUTO-005 | done (T-074) | `automationDrivesSlots` (read overrides a slot write, off ignored, stopped behaviour); `AutomationModelTests` SetAutomationMode |
| AUTO-006, AUTO-007 | todo (T-075) | |
| AUTO-008 | done (T-074) | `automationCompile` (ParamInfo mapping, non-automatable left out); `automationAUParam` (AU ranges); `AutomationModelTests` (mute lane drives strip and send mutes, bad edits throw) |
| AUTO-009 | done (T-074) | `AutomationGoldenTests` VST3 lane reaches SDK `again` via IParameterChanges (computed, analytic); `automationAUParam` (AUDelay) |
| AUTO-010 | done (T-074) | documented (11 Contract delta (T-074)): automation follows the transport block, not the MIX-023 look-ahead |
