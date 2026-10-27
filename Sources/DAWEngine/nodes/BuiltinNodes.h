#pragma once
// Registers the node kinds that live in nodes/ (06-dsp-builtins) with a NodeRegistry. Whoever
// builds the GraphCompiler's registry (the facade, T-014; tests) calls it after
// NodeRegistry::withBuiltins(). Non-RT.
//
//   audioClipPlayer  DSP-001; clips are fixed at creation (DW-051, see AudioClipPlayer.h), assets
//                    come from `lookup`
//   channelStrip     DSP-010 / MIX-005 gain and pan; needs numParams >= ChannelStrip::kNumParams
//                    (invalidArgument otherwise). No meter until GraphBuilder assigns MeterIDs
//                    (DW-048).

#include "core/Result.h"
#include "graph/NodeRegistry.h"
#include "nodes/AssetLookup.h"

namespace daw {

Result<void> registerBuiltinNodes(NodeRegistry& registry, AssetLookup lookup);

} // namespace daw
