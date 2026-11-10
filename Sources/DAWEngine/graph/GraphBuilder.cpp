#include "graph/GraphBuilder.h"

#include <algorithm>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

#include "automation/AutomationCompiler.h"
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

// MIX-023: kinds scheduled `latency` samples early (RenderStepDesc::timeline). The metronome
// (TIME-010, T-024) places its clicks from the timeline too.
bool readsTimeline(NodeKind kind) {
    return resetsOnLocate(kind) || kind == NodeKind::metronome;
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
        // MIX-004: one main input and one sidechain input per node in v1. MIX-008: a sidechain
        // edge feeds the target's sidechain port; its tap (pre/post-fader) is simply where the
        // model starts it (MODEL-020), so the builder treats it like any audio edge otherwise.
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

    // AUTO-001 (T-074): lanes are well formed before anything is touched.
    if (auto r = validateAutomation(desc, params); !r) return r.error();

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
        auto created = kinds[i]->create(
            NodeCreateInfo{d, clips[i], notes[i], meter, LatencyReporter(relay_, d.id)});
        if (!created) return created.error();
        if (!created.value()) return makeError(ErrorCode::internal, nodeName(d.id) + ": factory returned null");
        const PrepareInfo info{sampleRate_, maxBlock_, 2, kinds[i]->audioOutput ? 2u : 0u};
        auto put = pool.put(d.id, std::move(created).value(), info);
        if (!put) return put.error();
        nodes[i] = std::move(put).value();
        instances_[d.id] = Instance{d.kind, d.configVersion, d.firstParam, d.numParams, nodes[i]};
    }

    // MARK: PDC (MIX-020, MIX-021)

    // Path latencies in topological order. A sum over a path of uint32 latencies fits easily in
    // 64 bits; anything above kMaxGraphLatency is rejected.
    std::vector<uint64_t> arrival(numNodes, 0), path(numNodes, 0);
    std::vector<std::vector<uint32_t>> inEdges(numNodes);
    for (uint32_t i = 0; i < topoEdges.size(); ++i) inEdges[topoEdges[i].to].push_back(i);
    for (uint32_t s = 0; s < numNodes; ++s) {
        const uint32_t n = sorted.order[s];
        for (uint32_t e : inEdges[n]) arrival[n] = std::max(arrival[n], path[topoEdges[e].from]);
        path[n] = arrival[n] + nodes[n]->latencySamples();
        if (path[n] > kMaxGraphLatency)
            return invalid(nodeName(desc.nodes[n].id) + ": path latency " + std::to_string(path[n]) +
                           " exceeds " + std::to_string(kMaxGraphLatency) + " samples");
    }

    // MARK: Plan buffers (MIX-003)

    std::vector<uint32_t> stepOf(numNodes);
    for (uint32_t s = 0; s < numNodes; ++s) stepOf[sorted.order[s]] = s;
    std::vector<bool> producesAudio(numNodes);
    for (uint32_t s = 0; s < numNodes; ++s) producesAudio[s] = kinds[sorted.order[s]]->audioOutput;
    std::vector<PlanEdge> planEdges;
    std::vector<uint32_t> planEdgeDesc;  // planEdges[i] is desc.edges[planEdgeDesc[i]]
    planEdges.reserve(desc.edges.size());
    for (uint32_t i = 0; i < desc.edges.size(); ++i) {
        const EdgeDesc& e = desc.edges[i];
        if (e.kind == EdgeKind::midi) continue;  // MIDI isn't in buffers (T-045, below)
        const TopoEdge& t = topoEdges[i];
        const auto delay = static_cast<uint32_t>(arrival[t.to] - path[t.from]);  // MIX-021
        planEdges.push_back({stepOf[t.from], stepOf[t.to], e.kind == EdgeKind::sidechain, delay});
        planEdgeDesc.push_back(i);
    }
    BufferPlan plan = planBuffers(producesAudio, planEdges, master == kNoNode ? kNoBuffer : stepOf[master]);

    // MIX-022: one delay line per delayed edge, kept from the last build when it still fits.
    std::unordered_map<uint64_t, EdgeDelay> lines;
    for (StepBuffers& step : plan.steps)
        for (size_t f = 0; f < step.feeds.size(); ++f) {
            RenderFeedDesc& feed = step.feeds[f];
            if (feed.delay == 0) continue;
            const EdgeDesc& e = desc.edges[planEdgeDesc[step.feedEdges[f]]];
            std::shared_ptr<DelayLine> line;
            if (auto old = delayLines_.find(e.edgeID); old != delayLines_.end() &&
                old->second.from == e.from && old->second.to == e.to &&
                old->second.line->maxDelay() >= feed.delay)
                line = old->second.line;
            else
                line = std::make_shared<DelayLine>(2, feed.delay, maxBlock_);
            feed.delayLine = line;
            lines[e.edgeID] = EdgeDelay{e.from, e.to, std::move(line)};
        }

    // MARK: MIDI edges (T-045, DW-099)

    // A node with an outgoing MIDI edge writes into kMidiCapacity events per block; every
    // consumer pulls from that storage (RenderGraph.h). Inputs keep description order, which is
    // the tie order of a merge. MIX-021: a MIDI edge is delayed like an audio one; its line is
    // kept by edge ID for the same endpoints whatever the delay (a MidiDelayLine's capacity
    // doesn't depend on it), even at delay 0, so in-flight events, note-offs included, still
    // arrive after a latency change.
    std::vector<uint32_t> midiCapacity(numNodes, 0);
    std::vector<std::vector<RenderMidiInputDesc>> midiInputs(numNodes);
    std::unordered_map<uint64_t, MidiEdgeDelay> midiLines;
    for (uint32_t i = 0; i < desc.edges.size(); ++i) {
        const EdgeDesc& e = desc.edges[i];
        if (e.kind != EdgeKind::midi) continue;
        const TopoEdge& t = topoEdges[i];
        midiCapacity[t.from] = kMidiCapacity;
        RenderMidiInputDesc input;
        input.fromStep = stepOf[t.from];
        input.delay = static_cast<uint32_t>(arrival[t.to] - path[t.from]);
        if (auto old = midiDelayLines_.find(e.edgeID);
            old != midiDelayLines_.end() && old->second.from == e.from && old->second.to == e.to)
            input.delayLine = old->second.line;
        else if (input.delay > 0)
            input.delayLine = std::make_shared<MidiDelayLine>(kMidiDelayCapacity, kMidiCapacity);
        if (input.delayLine) midiLines[e.edgeID] = MidiEdgeDelay{e.from, e.to, input.delayLine};
        midiInputs[t.to].push_back(std::move(input));
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
        step.timeline = readsTimeline(desc.nodes[n].kind);
        step.midiCapacity = midiCapacity[n];
        step.midiInputs = std::move(midiInputs[n]);
        graph.steps.push_back(std::move(step));
        // MIX-020: telemetry's per-node table lists the latent nodes.
        if (const uint32_t latency = nodes[n]->latencySamples(); latency > 0)
            graph.nodeLatencies.push_back(NodeLatency{desc.nodes[n].id, latency});
    }
    graph.latency = master == kNoNode ? 0 : static_cast<uint32_t>(path[master]);  // MIX-023
    graph.master = master == kNoNode ? kNoBuffer : plan.steps[stepOf[master]].output;
    graph.tempo = std::move(tempo).value();
    graph.version = desc.version;
    // AUTO-001/008 (T-074): lanes become players, mapped through the prepared nodes' ranges.
    graph.automation = compileAutomation(desc, kinds, nodes);
    auto result = RenderGraph::create(std::move(graph));
    if (!result) return result.error();
    // MIX-022: lines this graph doesn't use are dropped here; graphs still rendering them hold
    // their own references.
    delayLines_ = std::move(lines);
    midiDelayLines_ = std::move(midiLines);

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
