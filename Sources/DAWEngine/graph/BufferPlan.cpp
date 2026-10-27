#include "graph/BufferPlan.h"

#include <set>

namespace daw {

namespace {

// Hands out the lowest free index, so the plan is deterministic.
class BufferAllocator {
public:
    uint32_t allocate() {
        if (free_.empty()) return count_++;
        const uint32_t b = *free_.begin();
        free_.erase(free_.begin());
        return b;
    }
    void release(uint32_t b) { free_.insert(b); }
    uint32_t count() const { return count_; }

private:
    std::set<uint32_t> free_;
    uint32_t count_ = 0;
};

} // namespace

BufferPlan planBuffers(const std::vector<bool>& producesAudio, std::span<const PlanEdge> edges,
                       uint32_t master) {
    const auto numSteps = static_cast<uint32_t>(producesAudio.size());
    BufferPlan plan;
    plan.steps.resize(numSteps);

    std::vector<std::vector<uint32_t>> outEdges(numSteps);  // edge indices, in edge order
    std::vector<uint32_t> inCount(numSteps, 0), sidechainCount(numSteps, 0);
    for (uint32_t i = 0; i < edges.size(); ++i) {
        outEdges[edges[i].from].push_back(i);
        ++(edges[i].sidechain ? sidechainCount : inCount)[edges[i].to];
    }
    // The port reads its single producer's output directly (see BufferPlan.h).
    auto direct = [&](const PlanEdge& e) {
        const uint32_t count = e.sidechain ? sidechainCount[e.to] : inCount[e.to];
        return count == 1 && outEdges[e.from].size() == 1 && e.from != master;
    };

    BufferAllocator buffers;
    for (uint32_t s = 0; s < numSteps; ++s) {
        StepBuffers& step = plan.steps[s];
        if (producesAudio[s]) step.output = buffers.allocate();
        for (RenderPortDesc* port : {&step.input, &step.sidechain})
            if (port->buffer != kNoBuffer) buffers.release(port->buffer);

        bool readDirectly = false;
        for (uint32_t i : outEdges[s]) {
            const PlanEdge& e = edges[i];
            RenderPortDesc& port = e.sidechain ? plan.steps[e.to].sidechain : plan.steps[e.to].input;
            port.fed = true;
            if (direct(e)) {
                port.buffer = step.output;
                readDirectly = true;
            } else if (port.buffer == kNoBuffer) {
                port.buffer = buffers.allocate();
                step.feeds.push_back({port.buffer, false});
            } else {
                step.feeds.push_back({port.buffer, true});
            }
        }
        if (step.output != kNoBuffer && !readDirectly && s != master) buffers.release(step.output);
    }
    plan.numBuffers = buffers.count();
    return plan;
}

} // namespace daw
