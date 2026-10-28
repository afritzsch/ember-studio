#include "TestNodeChecks.h"

#include <cmath>
#include <numbers>
#include <vector>

#include "NodeTestHarness.h"
#include "TestNodes.h"
#include "core/RtTrap.h"

namespace daw::testing {

namespace {

using nodes::kRate;

bool near(double a, double b, double tol = 1e-6) { return std::fabs(a - b) <= tol; }

double sine(double hz, double level, int64_t n) {
    return level * std::sin(2.0 * std::numbers::pi * hz / kRate * static_cast<double>(n));
}

// Drives one node block by block on the calling thread, two channels in and out, counting RT
// violations in each block's own scope (DW-019).
struct NodeRig {
    explicit NodeRig(Node& node) : node(node) {
        // No Engine here to install the trap (ENG-030); without it the scope would count nothing.
        (void)RtTrap::install();
        node.prepare(PrepareInfo{kRate, kMaxBlock, 2, 2});
    }

    // One block of `n` frames; `in(i)` is the input at frame i of this block (both channels).
    template <typename In>
    void process(uint32_t n, In in) {
        std::vector<float> inL(n), inR(n), outL(n, -99.0f), outR(n, -99.0f);
        for (uint32_t i = 0; i < n; ++i) inL[i] = inR[i] = in(i);
        float* ins[2] = {inL.data(), inR.data()};
        float* outs[2] = {outL.data(), outR.data()};
        NodeIO io;
        io.audioIn = AudioBufferView{ins, 2, n};
        io.audioOut = AudioBufferView{outs, 2, n};
        TransportBlock block{false, false, 0, {}, &tempo};
        ProcessContext ctx{n, kRate, block, params};
        {
            RtScope scope;
            node.process(ctx, io);
            violations += scope.violations();
        }
        left.insert(left.end(), outL.begin(), outL.end());
        right.insert(right.end(), outR.begin(), outR.end());
    }
    void process(uint32_t n) {
        process(n, [](uint32_t) { return 0.0f; });
    }
    void reset() {
        RtScope scope;
        node.reset();
        violations += scope.violations();
    }

    Node& node;
    ParamSlotTable params{16};
    TempoMap tempo;
    std::vector<float> left, right;
    uint64_t violations = 0;
};

// Odd sizes, a 0-frame block (ENG-004) and the largest one.
const std::vector<uint32_t> kBlocks = {1, 127, 0, 512, 33, kMaxBlock};

} // namespace

CheckResult testSineNode() {
    CheckResult checks;
    SineNode node(997.0, 0.5f);
    NodeRig rig(node);
    for (uint32_t n : kBlocks) rig.process(n);
    bool exact = rig.left.size() == rig.right.size();
    for (std::size_t i = 0; exact && i < rig.left.size(); ++i)
        exact = near(rig.left[i], sine(997.0, 0.5, static_cast<int64_t>(i))) && rig.left[i] == rig.right[i];
    DAW_CHECK(exact);
    DAW_CHECK(rig.left[0] == 0.0f);

    // reset() (a locate) starts over at phase 0.
    const std::size_t before = rig.left.size();
    rig.reset();
    rig.process(64);
    bool restarted = true;
    for (std::size_t i = 0; i < 64; ++i) restarted = restarted && rig.left[before + i] == rig.left[i];
    DAW_CHECK(restarted);
    DAW_CHECK(rig.violations == 0);
    return checks;
}

CheckResult testImpulseNode() {
    CheckResult checks;
    {
        ImpulseNode node(100, 0.75f, 10);
        NodeRig rig(node);
        for (uint32_t n : kBlocks) rig.process(n);
        bool exact = true;
        for (std::size_t i = 0; i < rig.left.size(); ++i) {
            const bool hit = i >= 10 && (i - 10) % 100 == 0;
            exact = exact && rig.left[i] == (hit ? 0.75f : 0.0f) && rig.right[i] == rig.left[i];
        }
        DAW_CHECK(exact);
        rig.reset();
        const std::size_t before = rig.left.size();
        rig.process(20);
        DAW_CHECK(rig.left[before + 10] == 0.75f && rig.left[before + 9] == 0.0f);
        DAW_CHECK(rig.violations == 0);
    }
    {
        ImpulseNode once(0, 1.0f);
        NodeRig rig(once);
        rig.process(300);
        rig.process(300);
        int hits = 0;
        for (float x : rig.left) hits += x != 0.0f;
        DAW_CHECK(hits == 1 && rig.left[0] == 1.0f);
        DAW_CHECK(rig.violations == 0);
    }
    return checks;
}

CheckResult testFakeLatencyNode() {
    CheckResult checks;
    for (uint32_t latency : {0u, 1u, 64u, 1000u}) {
        FakeLatencyNode node(latency);
        DAW_CHECK(node.latencySamples() == latency);
        NodeRig rig(node);
        // Input: frame index + 1, so the delay shows exactly and silence (0) stands out.
        int64_t frame = 0;
        for (uint32_t n : kBlocks) {
            rig.process(n, [&](uint32_t i) { return static_cast<float>(frame + i + 1); });
            frame += n;
        }
        bool delayed = true;
        for (std::size_t i = 0; i < rig.left.size(); ++i) {
            const float want = i < latency ? 0.0f : static_cast<float>(i - latency + 1);
            delayed = delayed && rig.left[i] == want && rig.right[i] == want;
        }
        DAW_CHECK(delayed);

        // reset() empties the delay line.
        rig.reset();
        const std::size_t before = rig.left.size();
        rig.process(latency + 4, [](uint32_t) { return 2.0f; });
        bool cleared = true;
        for (uint32_t i = 0; i < latency + 4; ++i)
            cleared = cleared && rig.left[before + i] == (i < latency ? 0.0f : 2.0f);
        DAW_CHECK(cleared);
        DAW_CHECK(rig.violations == 0);
    }
    return checks;
}

CheckResult testNaNNode() {
    CheckResult checks;
    NaNNode node;
    NodeRig rig(node);
    rig.process(64);
    bool nan = true;
    for (std::size_t i = 0; i < rig.left.size(); ++i) nan = nan && std::isnan(rig.left[i]) && std::isnan(rig.right[i]);
    DAW_CHECK(nan);
    DAW_CHECK(rig.violations == 0);
    return checks;
}

CheckResult testNodeRegistration() {
    CheckResult checks;
    const TestNodeSpec sineSpec{NodeKind::audioClipPlayer, TestNodeType::sine, 1000.0, 0.5f, 0, 0};
    const TestNodeSpec latencySpec{NodeKind::eq, TestNodeType::fakeLatency, 0, 0, 5, 0};
    auto registerBoth = [&](NodeRegistry& registry) {
        DAW_CHECK(registerTestNode(registry, sineSpec).ok());
        DAW_CHECK(registerTestNode(registry, latencySpec).ok());
    };

    // A clip-less player is the sine; the eq is a 5-frame FakeLatencyNode. The player is a
    // timeline kind, so MIX-023 schedules it 5 frames early and the output stays aligned.
    {
        nodes::Rig rig(registerBoth);
        GraphDescription d = nodes::baseDescription();
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{20, NodeKind::eq, 1, 0, 0, {}});
        d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
        DAW_CHECK(rig.publish(d));
        DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
        rig.render(256);
        rig.render(256);
        bool aligned = rig.left().size() == 512;
        for (std::size_t i = 0; aligned && i < rig.left().size(); ++i)
            aligned = near(rig.left()[i], sine(1000.0, 0.5, static_cast<int64_t>(i))) && rig.right()[i] == rig.left()[i];
        DAW_CHECK(aligned);
        DAW_CHECK(rig.engine().telemetry().snapshot().graphLatency == 5);
        DAW_CHECK(rig.violations() == 0);
    }

    // A player with clips stays the real clip player (DSP-001).
    {
        nodes::Rig rig(registerBoth);
        rig.addAsset(nodes::makeAsset(7, 2, 48000, [](uint32_t, int64_t) { return 0.25f; }));
        GraphDescription d = nodes::baseDescription();
        d.nodes.push_back(NodeDesc{11, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.edges.push_back(EdgeDesc{1, 11, 1, EdgeKind::audio, 0});
        d.audioClips.push_back(nodes::clip(11, 1, 0, 960, 7));
        DAW_CHECK(rig.publish(d));
        DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
        rig.render(512);
        bool clipPlays = rig.left().size() == 512;
        for (std::size_t i = 0; clipPlays && i < rig.left().size(); ++i)
            clipPlays = rig.left()[i] == 0.25f && rig.right()[i] == 0.25f;
        DAW_CHECK(clipPlays);
        DAW_CHECK(rig.violations() == 0);
    }

    // The facade variant: a kind given twice is rejected; otherwise a facade exists.
    DAW_CHECK(makeTestFacade(48000.0, {sineSpec, sineSpec}) == nullptr);
    DAW_CHECK(makeTestFacade(1.0, {sineSpec}) == nullptr);
    EngineFacade* facade = makeTestFacade(48000.0, {sineSpec, latencySpec});
    DAW_CHECK(facade != nullptr);
    if (facade) ::releaseFacade(facade);
    return checks;
}

uint64_t allocatingNodeViolations(uint32_t blocks) {
    AllocatingNode node;
    NodeRig rig(node);
    for (uint32_t b = 0; b < blocks; ++b) rig.process(64);
    rig.process(0);  // an empty block allocates nothing
    return rig.violations;
}

} // namespace daw::testing
