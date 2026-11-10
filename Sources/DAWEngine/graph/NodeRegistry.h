#pragma once
// How GraphBuilder (MIX-001) makes a node instance for each NodeKind. Node implementations live
// in other modules and later tasks (clip players T-013/T-040, DSP 06, plugins 10); each
// registers a factory for its kind here, so the builder never names a concrete node type. Tests
// register test-only nodes under real kinds (TEST-004).
//
// Non-RT. A registry is copied into each GraphBuilder; fill it before building.

#include <functional>
#include <memory>
#include <span>

#include "core/Node.h"
#include "core/Result.h"
#include "core/Telemetry.h"
#include "daw/GraphDescription.h"
#include "dsp/ParamInfo.h"
#include "graph/LatencyReporter.h"

namespace daw {

// What a factory gets. The spans hold the clips/notes whose `player` is this node, in
// description order; they're valid only during the call.
//
// A factory runs only when the builder needs a new instance: the node is new, or its kind,
// configVersion, firstParam or numParams changed (DW-036). Clip and note edits that don't bump
// configVersion reach no factory call, so a clip player that needs them per graph must get them
// another way (T-013).
//
// `meter` is the node's MeterID for Telemetry::writeMeter (DW-048) when its kind has `meters`
// set, otherwise kNoMeter. It stays the same for a NodeID across builds, re-created instances
// included, until the node leaves the description.
inline constexpr MeterID kNoMeter = Telemetry::kMaxMeters;

struct NodeCreateInfo {
    const NodeDesc& desc;
    std::span<const ClipDesc> clips;
    std::span<const NoteDesc> notes;
    MeterID meter = kNoMeter;
    LatencyReporter latency;
};

struct NodeKindInfo {
    // Returns an unprepared node; the builder prepares it through NodePool::put (ENG-013).
    std::function<Result<std::unique_ptr<Node>>(const NodeCreateInfo&)> create;
    // False for nodes that write only MIDI (midiClipPlayer): they get no audio output buffer,
    // and audio or sidechain edges out of them are rejected.
    bool audioOutput = true;
    // MIX-005: nodes of this kind get a MeterID (channelStrip). When all kMaxMeters are taken,
    // further nodes get kNoMeter.
    bool meters = false;
    // DSP-041: the kind's parameter table, published through NodeRegistry::paramInfo. Static
    // storage (each node's kParamInfo); empty for kinds without params.
    std::span<const ParamInfo> paramInfo{};
};

class NodeRegistry {
public:
    // Empty: no kind can be built.
    NodeRegistry() = default;

    // The engine's own kinds that exist so far: master (MIX-009) and bus (MIX-004).
    static NodeRegistry withBuiltins();

    // Registers or replaces the factory for `kind`. invalidArgument if `info.create` is empty.
    // An `info` without a param table keeps the one the kind already has: the table describes
    // the kind, not one factory (test nodes registered under real kinds, TEST-004).
    Result<void> set(NodeKind kind, NodeKindInfo info);

    // DSP-041: gives `kind` a param table without touching its factory, before or after set().
    void setParamInfo(NodeKind kind, std::span<const ParamInfo> table);

    // Null when `kind` has no factory.
    const NodeKindInfo* find(NodeKind kind) const;

    // 06 Interfaces, DSP-041: the built-in kinds' parameter tables, independent of any one
    // engine's registry. Empty for kinds without published params (hosted plugins report theirs
    // per instance, PLUG-015). Any thread; non-RT.
    static std::span<const ParamInfo> paramInfo(NodeKind kind);

private:
    static constexpr std::size_t kNumKinds = static_cast<std::size_t>(NodeKind::bus) + 1;
    NodeKindInfo kinds_[kNumKinds];
};

} // namespace daw
