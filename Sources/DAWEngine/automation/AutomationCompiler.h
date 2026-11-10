#pragma once
// AUTO-001/008 (T-074): GraphBuilder's automation step. validateAutomation() runs with the rest
// of the description's checks, before the NodePool is touched; compileAutomation() runs once
// the graph's node instances exist and turns the enabled lanes into AutomationPlayers.
//
// A lane drives the param slot `target`. Its mapping (ParamMapping.h) comes from the node whose
// param range [firstParam, firstParam + numParams) holds the slot, at index target − firstParam:
//   - a hosted AU (auPlugin): the AU parameter's min…max, linear (PLUG-015, AUInstance::params);
//   - a hosted VST3 (vst3Plugin): identity, VST3 values are normalized already (10 T-062 delta);
//   - any other kind: its ParamInfo row (06, DSP-041); a row that isn't `automatable` (AUTO-008)
//     leaves the lane out. A kind without a row for the index maps 0…1 as is.
// Lanes that are disabled (mode `off`, AUTO-005), have no points, or whose slot no node in this
// graph owns (a bypassed device, a removed send) are left out: there is nothing to drive.

#include <memory>
#include <span>
#include <vector>

#include "automation/AutomationSet.h"
#include "core/Node.h"
#include "core/ParamSlotTable.h"
#include "core/Result.h"
#include "daw/GraphDescription.h"
#include "graph/NodeRegistry.h"

namespace daw {

// invalidArgument unless every lane's target is in the param table, its points have strictly
// increasing ticks, finite values and shapes, and known curves.
Result<void> validateAutomation(const GraphDescription& desc, const ParamSlotTable& params);

// `kinds` and `nodes` are indexed like desc.nodes (prepared instances). Null when no lane is left.
std::unique_ptr<AutomationSet> compileAutomation(const GraphDescription& desc,
                                                 std::span<const NodeKindInfo* const> kinds,
                                                 std::span<const std::shared_ptr<Node>> nodes);

} // namespace daw
