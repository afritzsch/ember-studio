#include "graph/GraphBuilder.h"

#include <algorithm>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

#include "core/AudioBufferPool.h"
#include "graph/BufferPlan.h"
#include "graph/TopoSort.h"
#include "time/TempoMap.h"

namespace daw {

namespace {

Error invalid(std::string message) { return makeError(ErrorCode::invalidArgument, std::move(message)); }

std::string nodeName(NodeID id) { return "node " + std::to_string(id); }

// TIME-008: kinds that read the timeline and must be reset on a locate (T-008).
bool resetsOnLocate(NodeKind kind) {
    return kind == NodeKind::audioClipPlayer || kind == NodeKind::midiClipPlayer;
}

// DW-030: the audio thread only DAW_RT_ASSERTs ParamIDs (compiled out in Release), so every range
// is checked here: inside the table, and allocated (a freed slot may already belong to another
// node).
Result<void> checkParams(const NodeDesc& node, const ParamSlotTable& params) {
    if (node.numParams == 0) return {};
    const uint64_t end = uint64_t{node.firstParam} + node.numParams;
    if (end > params.capacity())
        return invalid(nodeName(node.id) + ": params " + std::to_string(node.firstParam) + "+" +
                       std::to_string(node.numParams) + " exceed the param table");
    for (ParamID id = node.firstParam; id < end; ++id)
        if (!params.isAllocated(id))
            return invalid(nodeName(node.id) + ": param " + std::to_string(id) + " is not allocated");
    return {};
}

Result<TempoMap> makeTempoMap(const TempoMapDesc& desc, double sampleRate) {
    TempoEventList tempos;
    tempos.reserve(desc.tempos.size());
    for (const TempoPointDesc& t : desc.tempos) tempos.push_back({t.tick, t.bpm});
    TimeSigEventList sigs;
    sigs.reserve(desc.timeSigs.size());
    for (const TimeSigDesc& t : desc.timeSigs) sigs.push_back({t.tick, t.num, t.den});
    return TempoMap::make(tempos, sigs, sampleRate);
}

} // namespace

GraphBuilder::GraphBuilder(NodeRegistry registry, double sampleRate, uint32_t maxBlock)
    : registry_(std::move(registry)), sampleRate_(sampleRate), maxBlock_(maxBlock) {}

Result<std::unique_ptr<RenderGraph>> GraphBuilder::build(const GraphDescription& desc, NodePool& pool,
                                                         ParamSlotTable& params) {
    if (!(sampleRate_ > 0)) return invalid("sampleRate must be > 0");
    if (maxBlock_ == 0 || maxBlock_ > kMaxBlock) return invalid("maxBlock must be in 1...kMaxBlock");

    // MARK: Validate (nothing is touched until the whole description passes)

    const auto numNodes = static_cast<uint32_t>(desc.nodes.size());
    std::unordered_map<NodeID, uint32_t> index;
    index.reserve(numNodes);
    std::vector<const NodeKindInfo*> kinds(numNodes);
    uint32_t master = kNoNode;
    for (uint32_t i = 0; i < numNodes; ++i) {
        const NodeDesc& node = desc.nodes[i];
        if (!index.emplace(node.id, i).second) return invalid("duplicate " + nodeName(node.id));
        kinds[i] = registry_.find(node.kind);
        if (!kinds[i])
            return makeError(ErrorCode::unsupported,
                             nodeName(node.id) + ": no factory for NodeKind " +
                                 std::to_string(static_cast<unsigned>(node.kind)));
        if (auto r = checkParams(node, params); !r) return r.error();
        if (node.kind == NodeKind::master) {
            if (node.id != desc.master) return invalid(nodeName(node.id) + " is a master but not the graph's master");
            master = i;
        }
    }
    // MIX-009: a graph with nodes has exactly one master; an empty description renders silence.
    if (numNodes > 0 && master == kNoNode)
        return invalid("master " + nodeName(desc.master) + " is missing or not of kind master");
    if (numNodes == 0 && desc.master != 0) return invalid("master " + nodeName(desc.master) + " is missing");

    std::vector<TopoEdge> topoEdges;
    topoEdges.reserve(desc.edges.size());
    std::unordered_set<uint64_t> edgeIDs;
    edgeIDs.reserve(desc.edges.size());
    for (const EdgeDesc& e : desc.edges) {
        const std::string name = "edge " + std::to_string(e.edgeID);
        // MIX-022 keys delay lines by edge ID, so it must identify one edge.
        if (!edgeIDs.insert(e.edgeID).second) return invalid("duplicate " + name);
        const auto from = index.find(e.from);
        const auto to = index.find(e.to);
        if (from == index.end() || to == index.end()) return invalid(name + " connects an unknown node");
        if (e.kind != EdgeKind::audio && e.kind != EdgeKind::midi && e.kind != EdgeKind::sidechain)
            return invalid(name + " has an unknown kind");
        // MIX-004: one main input and one sidechain input per node in v1.
        if (e.toPort != 0) return invalid(name + ": toPort must be 0");
        if (from->second == master) return invalid(name + " leaves the master, which is the final node");
        if (e.kind != EdgeKind::midi && !kinds[from->second]->audioOutput)
            return invalid(name + " carries audio from " + nodeName(e.from) + ", which has no audio output");
        topoEdges.push_back({from->second, to->second});
    }

    // MIX-002
    TopoSortResult sorted = topoSort(numNodes, topoEdges, master);
    if (!sorted.cycle.empty()) {
        std::vector<NodeID> ids;
        for (uint32_t n : sorted.cycle) ids.push_back(desc.nodes[n].id);
        std::sort(ids.begin(), ids.end());
        return makeCycleError(std::move(ids));
    }

    // TIME-003. The model has validated the map already; this is the defensive check.
    auto tempo = makeTempoMap(desc.tempo, sampleRate_);
    if (!tempo) return invalid("tempo map: " + tempo.error().message);

    // MARK: Plan buffers (MIX-003)

    std::vector<uint32_t> stepOf(numNodes);
    for (uint32_t s = 0; s < numNodes; ++s) stepOf[sorted.order[s]] = s;
    std::vector<bool> producesAudio(numNodes);
    for (uint32_t s = 0; s < numNodes; ++s) producesAudio[s] = kinds[sorted.order[s]]->audioOutput;
    std::vector<PlanEdge> planEdges;
    planEdges.reserve(desc.edges.size());
    for (size_t i = 0; i < desc.edges.size(); ++i) {
        const EdgeDesc& e = desc.edges[i];
        if (e.kind == EdgeKind::midi) continue;  // T-040 routes MIDI
        planEdges.push_back({stepOf[topoEdges[i].from], stepOf[topoEdges[i].to], e.kind == EdgeKind::sidechain});
    }
    BufferPlan plan = planBuffers(producesAudio, planEdges, master == kNoNode ? kNoBuffer : stepOf[master]);

    // MARK: Node instances (ENG-013, DW-036)

    // Clips and notes per player, for factories.
    std::vector<std::vector<ClipDesc>> clips(numNodes);
    for (const ClipDesc& c : desc.audioClips)
        if (auto it = index.find(c.player); it != index.end()) clips[it->second].push_back(c);
    std::vector<std::vector<NoteDesc>> notes(numNodes);
    for (const NoteDesc& n : desc.notes)
        if (auto it = index.find(n.player); it != index.end()) notes[it->second].push_back(n);

    std::vector<std::shared_ptr<Node>> nodes(numNodes);
    for (uint32_t i = 0; i < numNodes; ++i) {
        const NodeDesc& d = desc.nodes[i];
        auto known = instances_.find(d.id);
        if (known != instances_.end()) {
            const Instance& inst = known->second;
            std::shared_ptr<Node> pooled = pool.get(d.id);
            if (pooled && pooled == inst.node.lock() && inst.kind == d.kind &&
                inst.configVersion == d.configVersion && inst.firstParam == d.firstParam &&
                inst.numParams == d.numParams) {
                nodes[i] = std::move(pooled);
                continue;
            }
        }
        // New, changed, or replaced in the pool behind our back: a fresh instance, prepared
        // before any graph can render it.
        const MeterID meter = kinds[i]->meters ? assignMeter(d.id) : kNoMeter;
        auto created = kinds[i]->create(NodeCreateInfo{d, clips[i], notes[i], meter});
        if (!created) return created.error();
        if (!created.value()) return makeError(ErrorCode::internal, nodeName(d.id) + ": factory returned null");
        const PrepareInfo info{sampleRate_, maxBlock_, 2, kinds[i]->audioOutput ? 2u : 0u};
        auto put = pool.put(d.id, std::move(created).value(), info);
        if (!put) return put.error();
        nodes[i] = std::move(put).value();
        instances_[d.id] = Instance{d.kind, d.configVersion, d.firstParam, d.numParams, nodes[i]};
    }

    // MARK: Assemble

    RenderGraphDesc graph;
    graph.sampleRate = sampleRate_;
    graph.maxBlock = maxBlock_;
    auto buffers = AudioBufferPool::create(plan.numBuffers, 2, maxBlock_);
    if (!buffers) return buffers.error();
    graph.buffers = std::move(buffers).value();
    graph.steps.reserve(numNodes);
    for (uint32_t s = 0; s < numNodes; ++s) {
        const uint32_t n = sorted.order[s];
        StepBuffers& b = plan.steps[s];
        RenderStepDesc step;
        step.node = nodes[n];
        step.input = std::move(b.input);
        step.sidechain = std::move(b.sidechain);
        step.output = b.output;
        step.feeds = std::move(b.feeds);
        step.resetOnLocate = resetsOnLocate(desc.nodes[n].kind);
        graph.steps.push_back(std::move(step));
    }
    graph.master = master == kNoNode ? kNoBuffer : plan.steps[stepOf[master]].output;
    graph.tempo = std::move(tempo).value();
    graph.version = desc.version;
    auto result = RenderGraph::create(std::move(graph));
    if (!result) return result.error();

    // Forget nodes the description dropped. Graphs that still render them hold their own
    // references, so they're released on daw.reclaim once those graphs are gone (ENG-013).
    for (auto it = instances_.begin(); it != instances_.end();) {
        if (index.count(it->first)) {
            ++it;
            continue;
        }
        if (pool.get(it->first) == it->second.node.lock()) pool.remove(it->first);
        it = instances_.erase(it);
    }
    // DW-048: release the MeterIDs of nodes that left, or whose kind no longer meters.
    for (auto it = meters_.begin(); it != meters_.end();) {
        auto node = index.find(it->first);
        if (node != index.end() && kinds[node->second]->meters) {
            ++it;
            continue;
        }
        freeMeters_.push_back(it->second);
        it = meters_.erase(it);
    }
    return result;
}

MeterID GraphBuilder::assignMeter(NodeID node) {
    if (auto it = meters_.find(node); it != meters_.end()) return it->second;
    MeterID id = kNoMeter;
    if (!freeMeters_.empty()) {
        id = freeMeters_.back();
        freeMeters_.pop_back();
    } else if (nextMeter_ < Telemetry::kMaxMeters) {
        id = nextMeter_++;
    }
    if (id != kNoMeter) meters_[node] = id;
    return id;
}

MeterID GraphBuilder::meterOf(NodeID node) const {
    auto it = meters_.find(node);
    return it == meters_.end() ? kNoMeter : it->second;
}

} // namespace daw
