// T-097 hosted-plugin follow-ups (DW-242, DW-211, DW-233, DW-210, DW-225). See
// include/PluginFollowupChecks.h.

#include "PluginFollowupChecks.h"

#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "AUPluginChecks.h"
#include "ExportTestSupport.h"
#include "NodeTestHarness.h"
#include "TestAudio.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "daw/GraphDescription.h"
#include "graph/GraphBuilder.h"
#include "graph/NodeRegistry.h"
#include "plugins/AUInstance.h"
#include "plugins/AUPluginConfig.h"
#include "plugins/AUPluginHost.h"
#include "plugins/AUIdentifier.h"
#include "plugins/VST3Instance.h"
#include "plugins/VST3PluginConfig.h"
#include "plugins/VST3PluginHost.h"

using namespace std::chrono_literals;

namespace daw::testing {

namespace {

using nodes::baseDescription;
using nodes::kRate;
using nodes::kSamplesPerTick;
using nodes::makeAsset;
using nodes::Rig;

constexpr float kNaN = std::numeric_limits<float>::quiet_NaN();
constexpr const char* kEffectUID = "E4B3E71A000000000000000000000001";
constexpr const char* kSynthUID = "E4B3E71A000000000000000000000002";
constexpr const char* kFake = "aumf:fAke:Embr";
constexpr const char* kDelay = "aufx:dely:appl";
// EmberTest's parameters (EmberTestPlugin.cpp).
constexpr uint32_t kGain = 0, kMix = 1, kMod = 3, kAllOff = 4;

std::filesystem::path repoRoot() {
    return std::filesystem::path(__FILE__).parent_path().parent_path().parent_path();
}

bool ensureTestPlugins() {
    static const bool built = [] {
        const std::string command = "\"" + (repoRoot() / "scripts/build-test-vst3.sh").string() + "\"";
        return std::system(command.c_str()) == 0;
    }();
    return built;
}

std::string emberIdentifier(const char* uid) {
    return (repoRoot() / ".build/test-plugins/EmberTest.vst3").string() + "#" + uid;
}

// EmberTest's per-instance probes (EmberTestPlugin.cpp): other suites run EmberTest at the same
// time, so everything here is read from the instance's own processor, through its controller.
struct EmberAPI {
    int32_t (*points)(void*, uint32_t, int32_t*, double*, int32_t, int64_t*) = nullptr;
    int32_t (*stats)(void*, int64_t*, int32_t*, int32_t*, int32_t*, int64_t*, int64_t*) = nullptr;
    void (*setLatency)(void*, uint32_t, int32_t) = nullptr;
    int32_t (*processorLive)(int64_t) = nullptr;
};

const EmberAPI& ember() {
    static const EmberAPI api = [] {
        EmberAPI a;
        if (!ensureTestPlugins()) return a;
        const auto path = repoRoot() / ".build/test-plugins/EmberTest.vst3/Contents/MacOS/EmberTest";
        void* image = dlopen(path.c_str(), RTLD_NOW);
        if (!image) return a;
        a.points = reinterpret_cast<decltype(a.points)>(dlsym(image, "ember_test_probe_points"));
        a.stats = reinterpret_cast<decltype(a.stats)>(dlsym(image, "ember_test_probe_stats"));
        a.setLatency = reinterpret_cast<decltype(a.setLatency)>(dlsym(image, "ember_test_probe_set_latency"));
        a.processorLive = reinterpret_cast<decltype(a.processorLive)>(dlsym(image, "ember_test_processor_live"));
        return a;
    }();
    return api;
}

bool emberReady() {
    const EmberAPI& a = ember();
    return a.points && a.stats && a.setLatency && a.processorLive;
}

void* controllerOf(const std::shared_ptr<VST3Instance>& instance) {
    return instance ? static_cast<void*>(instance->editController()) : nullptr;
}

struct Points {
    std::vector<int32_t> offsets;
    std::vector<double> values;
    int64_t block = -1;
};

Points points(const std::shared_ptr<VST3Instance>& instance, uint32_t id) {
    Points p;
    int32_t offsets[256];
    double values[256];
    const int32_t n = ember().points(controllerOf(instance), id, offsets, values, 256, &p.block);
    p.offsets.assign(offsets, offsets + n);
    p.values.assign(values, values + n);
    return p;
}

struct ProcessStats {
    int64_t blocks = 0, noteOffs = 0, processorID = 0;
    int32_t setupMode = -1, dataMode = -1, activations = 0;
    bool ok = false;
};

ProcessStats stats(const std::shared_ptr<VST3Instance>& instance) {
    ProcessStats s;
    s.ok = ember().stats(controllerOf(instance), &s.blocks, &s.setupMode, &s.dataMode, &s.activations, &s.noteOffs,
                         &s.processorID) != 0;
    return s;
}

FakeProbe fake(const std::shared_ptr<AUInstance>& instance) {
    return instance ? fakeAudioUnitProbe(instance->audioUnit()) : FakeProbe{};
}

template <class F>
bool eventually(F done, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

ParamID allocate(Rig& rig, uint32_t count, float value = kNaN) {
    auto first = rig.engine().params().allocate(count, value);
    return first ? first.value() : 0;
}

float peak(const std::vector<float>& v, size_t from = 0) {
    float p = 0;
    for (size_t i = from; i < v.size(); ++i) p = std::max(p, std::fabs(v[i]));
    return p;
}

void renderBlocks(Rig& rig, int64_t frames, uint32_t block = 256) {
    rig.renderFrames(frames, [block] { return block; });
}

// MARK: DW-242

// One tail scenario on `rig`: a node 20 (`kind`, `configJSON`) fed by clip player 10. Phase 1 plays
// a constant into it for `fill` frames, filling its delay; phase 2 continues with no clip (silence
// in) and returns what came out: the tail, unless `before` (run between the phases) reset the
// plugin. `published` runs once the plugin exists (to give it a delay).
template <class Published, class Before>
std::vector<float> tailAfter(Rig& rig, NodeKind kind, const std::string& configJSON, int64_t fill, int64_t listen,
                             Published published, Before before) {
    auto graph = [&](bool withClip) {
        GraphDescription d = baseDescription();
        // A new configVersion: the player is re-created with its new clips (none).
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, withClip ? 1u : 2u, 0, 0, {}});
        d.nodes.push_back(NodeDesc{20, kind, 1, 0, 0, configJSON});
        d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
        if (withClip) d.audioClips.push_back(nodes::clip(10, 1, 0, 960 * 16, 7));
        return d;
    };
    if (!rig.publish(graph(true))) return {};
    published();
    (void)rig.transport().locate(0);
    (void)rig.transport().play();
    renderBlocks(rig, fill);
    if (!rig.publish(graph(false))) return {};
    before();
    rig.clearOutput();
    renderBlocks(rig, listen);
    std::vector<float> out = rig.left();
    (void)rig.transport().stop();
    renderBlocks(rig, 256);
    return out;
}

template <class Host>
std::unique_ptr<Rig> rigWith(NodeKind kind, const std::shared_ptr<Host>& host, float input) {
    auto rig = std::make_unique<Rig>([kind, host](NodeRegistry& r) { (void)r.set(kind, host->kindInfo()); });
    rig->addAsset(makeAsset(7, 1, 480000, [input](uint32_t, int64_t) { return input; }));
    return rig;
}

} // namespace

CheckResult vst3ResetClearsTail() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(emberReady());
    if (!emberReady()) return checks;
    const std::string config = VST3PluginConfig::makeJSON(emberIdentifier(kEffectUID), {});

    for (int path = 0; path < 3; ++path) {  // 0 control (no reset), 1 export path, 2 fallback
        auto host = std::make_shared<VST3PluginHost>();
        auto rig = rigWith(NodeKind::vst3Plugin, host, 0.5f);
        ProcessStats before;
        uint64_t done = 0;
        const auto out = tailAfter(
            *rig, NodeKind::vst3Plugin, config, 9600, 9600,
            // This EmberTest's delay ring: the output is the input 2400 frames late.
            [&] { ember().setLatency(controllerOf(host->instance(20)), 2400, 0); },
            [&] {
                auto instance = host->instance(20);
                done = instance ? instance->resetsDone() : 0;
                before = stats(instance);
                if (path == 1) host->resetAll();  // what the export thread does (EngineFacade)
                if (path >= 1) rig->engine().resetAllNodesBeforeNextBlock();
            });
        DAW_CHECK(out.size() == 9600);
        auto instance = host->instance(20);
        DAW_CHECK(instance != nullptr && before.ok);
        if (!instance) continue;
        if (path == 0) {
            DAW_CHECK(peak(out) > 0.49f);  // the ring plays out: 0.5 × gain 1
            DAW_CHECK(instance->resetsDone() == done);
            DAW_CHECK(stats(instance).activations == before.activations);
        } else {
            DAW_CHECK(peak(out) == 0.0f);
            // One reset each way: the node's reset() found the export's reset fresh (path 1), or
            // asked the worker without waiting and rendered as absent until it was done (path 2).
            DAW_CHECK(eventually([&] { return instance->resetsDone() == done + 1 && !instance->resetBusy(); }));
            DAW_CHECK(stats(instance).activations == before.activations + 1);  // one setActive cycle
        }
        DAW_CHECK(rig->violations() == 0);
    }
    return checks;
}

CheckResult auResetClearsTail() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(registerFakeAudioUnit());
    const std::string config = AUPluginConfig::makeJSON(kFake, {});

    for (int path = 0; path < 3; ++path) {  // 0 control, 1 export path, 2 fallback
        auto host = std::make_shared<AUPluginHost>();
        auto rig = rigWith(NodeKind::auPlugin, host, 0.5f);
        FakeProbe before;
        uint64_t done = 0;
        const auto out = tailAfter(
            *rig, NodeKind::auPlugin, config, 9600, 9600,
            [&] {
                if (auto instance = host->instance(20)) setFakeAudioUnitLatency(instance->audioUnit(), 0.05);  // 2400 frames
            },
            [&] {
                auto instance = host->instance(20);
                done = instance ? instance->resetsDone() : 0;
                before = fake(instance);
                if (path == 1) host->resetAll();
                if (path >= 1) rig->engine().resetAllNodesBeforeNextBlock();
            });
        DAW_CHECK(out.size() == 9600);
        auto instance = host->instance(20);
        DAW_CHECK(instance != nullptr);
        if (!instance) continue;
        if (path == 0) {
            DAW_CHECK(peak(out) > 0.49f);
            DAW_CHECK(fake(instance).resets == before.resets);
        } else {
            DAW_CHECK(peak(out) == 0.0f);
            DAW_CHECK(eventually([&] { return instance->resetsDone() == done + 1 && !instance->resetBusy(); }));
            DAW_CHECK(fake(instance).resets == before.resets + 1);
        }
        DAW_CHECK(rig->violations() == 0);
    }

    // AUDelay (V2, AudioUnitReset through the bridge): an impulse's 0.25 s echo is pending when the
    // export path resets it, and never comes. Control: it comes.
    for (int reset = 0; reset < 2; ++reset) {
        auto host = std::make_shared<AUPluginHost>();
        Rig rig([host](NodeRegistry& r) { (void)r.set(NodeKind::auPlugin, host->kindInfo()); });
        rig.addAsset(makeAsset(7, 1, 480000, [](uint32_t, int64_t i) { return i == 0 ? 1.0f : 0.0f; }));
        const ParamID p = allocate(rig, 4);
        rig.engine().params().set(p + 0, 100.0f);  // wet only
        rig.engine().params().set(p + 1, 0.25f);   // 12000 frames
        rig.engine().params().set(p + 2, 0.0f);    // no feedback
        auto graph = [&](bool withClip) {
            GraphDescription d = baseDescription();
            d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, withClip ? 1u : 2u, 0, 0, {}});
            d.nodes.push_back(NodeDesc{20, NodeKind::auPlugin, 1, p, 4, AUPluginConfig::makeJSON(kDelay, {})});
            d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
            d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
            if (withClip) d.audioClips.push_back(nodes::clip(10, 1, 0, 960 * 16, 7));
            return d;
        };
        DAW_CHECK(rig.publish(graph(true)));
        DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
        renderBlocks(rig, 6000);  // the impulse is in, its echo 6000 frames away
        DAW_CHECK(rig.publish(graph(false)));
        if (reset) {
            host->resetAll();
            rig.engine().resetAllNodesBeforeNextBlock();
        }
        rig.clearOutput();
        renderBlocks(rig, 12000);
        DAW_CHECK(rig.left().size() == 12000);
        if (reset) DAW_CHECK(peak(rig.left()) < 1e-6f);
        else DAW_CHECK(peak(rig.left()) > 0.5f);
        DAW_CHECK(rig.violations() == 0);
    }
    return checks;
}

// MARK: DW-211 + DW-242 through the builder and the facade

namespace {

struct FacadeRef {
    EngineFacade* facade;
    FacadeRef() {
        DriverConfigPOD config;
        config.sampleRate = kRate;
        facade = EngineFacade::create(EngineMode::offline, config);
    }
    ~FacadeRef() {
        if (facade) releaseFacade(facade);
    }
    EngineFacade* operator->() const { return facade; }
};

bool published(EngineFacade& f, uint64_t version) {
    const GraphStatusPOD s = f.waitForGraph(version, 10000);
    return s.publishedVersion >= version && s.lastError.ok();
}

// Exports [0, ticks) without a tail; true when it succeeded with 0 RT violations.
bool exportOK(EngineFacade& f, const std::filesystem::path& path, Tick ticks) {
    ExportSpecPOD spec;
    spec.path = path.string();
    spec.tailEnabled = false;
    const JobID job = f.renderOffline(0, ticks, spec);
    JobStatus status;
    if (!eventually([&] {
            status = f.pollJob(job);
            return status.state == JobState::succeeded || status.state == JobState::failed;
        }, 20000ms))
        return false;
    return status.state == JobState::succeeded && status.render.rtViolations == 0;
}

// An EmberTest state container (VST3Instance's "EVS3" blob) whose component state is gain, mix.
std::vector<uint8_t> emberState(float gain, float mix) {
    std::vector<uint8_t> out;
    auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) out.push_back(static_cast<uint8_t>(v >> (8 * i))); };
    auto u64 = [&](uint64_t v) { for (int i = 0; i < 8; ++i) out.push_back(static_cast<uint8_t>(v >> (8 * i))); };
    auto f32 = [&](float v) { uint32_t b; std::memcpy(&b, &v, 4); u32(b); };
    u32(0x33535645);  // "EVS3"
    u32(1);
    u64(8);
    f32(gain);
    f32(mix);
    u64(0);
    return out;
}

} // namespace

CheckResult pluginOfflineModeAndExportReset() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(emberReady());
    DAW_CHECK(registerFakeAudioUnit());
    if (!emberReady()) return checks;

    // A builder with PrepareInfo::offline (an offline engine's) and one without.
    for (bool offline : {true, false}) {
        auto vst3 = std::make_shared<VST3PluginHost>();
        auto au = std::make_shared<AUPluginHost>();
        NodeRegistry registry = NodeRegistry::withBuiltins();
        (void)registry.set(NodeKind::vst3Plugin, vst3->kindInfo());
        (void)registry.set(NodeKind::auPlugin, au->kindInfo());
        Engine engine;
        GraphBuilder builder(std::move(registry), kRate, kMaxBlock, offline);
        GraphDescription d = baseDescription();
        d.nodes.push_back(NodeDesc{20, NodeKind::vst3Plugin, 1, 0, 0, VST3PluginConfig::makeJSON(emberIdentifier(kEffectUID), {})});
        d.nodes.push_back(NodeDesc{21, NodeKind::auPlugin, 1, 0, 0, AUPluginConfig::makeJSON(kFake, {})});
        d.edges.push_back(EdgeDesc{1, 20, 21, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, 21, 1, EdgeKind::audio, 0});
        auto graph = builder.build(d, engine.nodes(), engine.params());
        DAW_CHECK(graph.ok());
        if (!graph) continue;
        engine.publish(std::move(graph).value());
        std::vector<float> l(512), r(512);
        float* ptrs[2] = {l.data(), r.data()};
        RenderTarget target;
        target.output = AudioBufferView{ptrs, 2, 512};
        uint64_t violations = 0;
        for (int b = 0; b < 4; ++b) {
            RtScope scope;
            engine.render(target, 512);
            violations += scope.violations();
        }
        DAW_CHECK(violations == 0);
        const auto instance = vst3->instance(20);
        const ProcessStats s = stats(instance);
        // DW-211: kOffline is 2, kRealtime 0, in setupProcessing and in every process call.
        DAW_CHECK(s.ok && s.setupMode == (offline ? 2 : 0) && s.dataMode == (offline ? 2 : 0) && s.blocks >= 4);
        DAW_CHECK(instance && instance->preparedOffline() == offline);
        const auto unit = au->instance(21);
        DAW_CHECK(unit && unit->preparedOffline() == offline);
        DAW_CHECK(fake(unit).renderingOffline == (offline ? 1 : 0));
        // A mode change re-prepares the same instance in the other mode.
        if (instance) {
            DAW_CHECK(instance->prepare(kRate, kMaxBlock, !offline).ok() && instance->preparedOffline() == !offline);
            DAW_CHECK(stats(instance).setupMode == (offline ? 0 : 2));
        }
    }

    // Through an offline facade: kOffline, and every export resets the plugin once (one setActive
    // cycle) before its first block. The facade hides its hosts, so the instance is found by a
    // unique gain in its state.
    TempDir dir;
    FacadeRef f;
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    constexpr float kTag = 0.3141593f;
    GraphDescriptionBuilder g;
    g.addNode(1, NodeKind::master, 0, 0, 0, "");
    g.addNode(20, NodeKind::vst3Plugin, 0, 0, 0, VST3PluginConfig::makeJSON(emberIdentifier(kEffectUID), emberState(kTag, 0)));
    g.addEdge(1, 20, 1, EdgeKind::audio, 0);
    g.setTempo(0, 120.0);
    g.setTimeSignature(0, 4, 4);
    g.setMaster(1);
    DAW_CHECK(published(*f.facade, f->applyGraph(g.description())));
    using Find = void* (*)(float);
    static const Find find = [] {
        void* image = dlopen((repoRoot() / ".build/test-plugins/EmberTest.vst3/Contents/MacOS/EmberTest").c_str(), RTLD_NOW);
        return image ? reinterpret_cast<Find>(dlsym(image, "ember_test_probe_find_by_gain")) : nullptr;
    }();
    DAW_CHECK(find != nullptr);
    if (!find) return checks;
    void* controller = find(kTag);
    DAW_CHECK(controller != nullptr);
    auto facadeStats = [&] {
        ProcessStats s;
        s.ok = ember().stats(controller, &s.blocks, &s.setupMode, &s.dataMode, &s.activations, &s.noteOffs,
                             &s.processorID) != 0;
        return s;
    };
    DAW_CHECK(facadeStats().ok && facadeStats().setupMode == 2);
    for (int i = 0; i < 2; ++i) {
        const int32_t activations = facadeStats().activations;
        DAW_CHECK(exportOK(*f.facade, dir.path() / ("e" + std::to_string(i) + ".wav"), 96));
        DAW_CHECK(facadeStats().activations == activations + 1);
        DAW_CHECK(facadeStats().dataMode == 2);
    }
    return checks;
}

// MARK: DW-233

CheckResult pluginWrapJump() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(emberReady());
    DAW_CHECK(registerFakeAudioUnit());
    if (!emberReady()) return checks;

    // One lane from 0 at tick 0 to 1 at tick 1920, linear; loop [960, 1920). Located at tick 1900,
    // a 1000-frame block plays 500 frames to the loop end and wraps at frame 500 to tick 960.
    auto lane = [](GraphDescription& d, ParamID target) {
        AutomationDesc a{1, target, {}, true};
        a.points.push_back(AutomationPointDesc{0, 0.0f, 0, 0.0f});
        a.points.push_back(AutomationPointDesc{1920, 1.0f, 0, 0.0f});
        d.automation.push_back(a);
    };
    const float before = 1900.0f / 1920.0f, after = 0.5f;

    // VST3: EmberTest's gain gets (0, before), (499, before), (500, after).
    {
        auto host = std::make_shared<VST3PluginHost>();
        Rig rig([host](NodeRegistry& r) { (void)r.set(NodeKind::vst3Plugin, host->kindInfo()); });
        const ParamID p = allocate(rig, 2);
        GraphDescription d = baseDescription();
        d.nodes.push_back(NodeDesc{20, NodeKind::vst3Plugin, 1, p, 2, VST3PluginConfig::makeJSON(emberIdentifier(kEffectUID), {})});
        d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
        lane(d, p + kGain);
        DAW_CHECK(rig.publish(d));
        auto instance = host->instance(20);
        DAW_CHECK(rig.transport().setLoop(true, 960, 1920) && rig.transport().locate(1900) && rig.transport().play());
        rig.render(0);  // applies the commands
        rig.render(1000);
        const Points gain = points(instance, kGain);
        DAW_CHECK(gain.offsets == (std::vector<int32_t>{0, 499, 500}));
        DAW_CHECK(gain.values.size() == 3);
        if (gain.values.size() == 3) {
            DAW_CHECK(std::fabs(gain.values[0] - before) < 1e-6 && std::fabs(gain.values[1] - before) < 1e-6);
            DAW_CHECK(std::fabs(gain.values[2] - after) < 1e-6);
        }
        // The next block (no wrap): one point at 0 again.
        rig.render(1000);
        const Points next = points(instance, kGain);
        DAW_CHECK(next.block > gain.block && next.offsets == (std::vector<int32_t>{0}));
        // A param without automation (mix, NaN: not set) gets nothing, wrap or not.
        renderBlocks(rig, 48000);
        DAW_CHECK(points(instance, kMix).block == -1);
        DAW_CHECK(rig.violations() == 0);
    }

    // AU: the fake applies parameter events at their frame; output = gain × its input.
    {
        auto host = std::make_shared<AUPluginHost>();
        Rig rig([host](NodeRegistry& r) { (void)r.set(NodeKind::auPlugin, host->kindInfo()); });
        rig.addAsset(makeAsset(7, 1, 480000, [](uint32_t, int64_t) { return 0.25f; }));
        const ParamID p = allocate(rig, 2);
        rig.engine().params().set(p + 1, 0.0f);  // sidechain mix
        GraphDescription d = baseDescription();
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{20, NodeKind::auPlugin, 1, p, 2, AUPluginConfig::makeJSON(kFake, {})});
        d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
        d.audioClips.push_back(nodes::clip(10, 1, 0, 960 * 16, 7));
        lane(d, p + 0);
        DAW_CHECK(rig.publish(d));
        DAW_CHECK(rig.transport().setLoop(true, 960, 1920) && rig.transport().locate(1900) && rig.transport().play());
        rig.render(0);
        rig.render(1000);
        const auto& l = rig.left();
        DAW_CHECK(l.size() == 1000);
        if (l.size() == 1000) {
            // The input level as the plugin gets it, from the last frame (gain `after`).
            const float in = l[999] / after;
            DAW_CHECK(in > 0.2f);
            int wrong = 0;
            for (size_t i = 0; i < 1000; ++i) wrong += std::fabs(l[i] - in * (i < 500 ? before : after)) > 1e-6f;
            DAW_CHECK(wrong == 0);
        }
        DAW_CHECK(rig.violations() == 0);
    }
    return checks;
}

// MARK: DW-210

CheckResult vst3MidiMapping() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(emberReady());
    if (!emberReady()) return checks;
    auto made = VST3Instance::instantiate(*parseVST3Identifier(emberIdentifier(kSynthUID)));
    DAW_CHECK(made.ok());
    if (!made) return checks;
    std::shared_ptr<VST3Instance> instance = std::move(made).value();
    DAW_CHECK(instance->prepare(kRate, 512).ok());

    std::vector<float> l(512), r(512);
    float* out[2] = {l.data(), r.data()};
    NodeIO io;
    io.audioOut = AudioBufferView{out, 2, 512};
    auto render = [&](const std::vector<MidiEvent>& events) {
        RtScope scope;
        for (const MidiEvent& e : events) instance->addMidi(e, 512);
        const bool ok = instance->render(io, 512);
        return ok && scope.violations() == 0;
    };

    DAW_CHECK(render({
        MidiEvent{10, 3, {0xB0, 7, 64}},      // CC 7, channel 1 → Gain
        MidiEvent{20, 3, {0xB1, 1, 127}},     // CC 1, channel 2 → Mod
        MidiEvent{30, 2, {0xD0, 32, 0}},      // channel aftertouch → Mod
        MidiEvent{40, 3, {0xE0, 0x00, 0x40}}, // pitch bend centre → Sidechain Mix 0.5
        MidiEvent{50, 3, {0xE0, 0x7F, 0x7F}}, // pitch bend max → 1
        MidiEvent{60, 3, {0xB0, 10, 5}},      // CC 10: not mapped
        MidiEvent{70, 3, {0xB5, 7, 1}},       // channel 6: not mapped
    }));
    const Points gain = points(instance, kGain), mod = points(instance, kMod), mix = points(instance, kMix);
    DAW_CHECK(gain.offsets == (std::vector<int32_t>{10}) && gain.values.size() == 1 &&
              std::fabs(gain.values[0] - 64.0 / 127.0) < 1e-6);
    DAW_CHECK(mod.offsets == (std::vector<int32_t>{20, 30}) && mod.values.size() == 2 &&
              std::fabs(mod.values[0] - 1.0) < 1e-6 && std::fabs(mod.values[1] - 32.0 / 127.0) < 1e-6);
    DAW_CHECK(mix.offsets == (std::vector<int32_t>{40, 50}) && mix.values.size() == 2 &&
              std::fabs(mix.values[0] - 8192.0 / 16383.0) < 1e-6 && std::fabs(mix.values[1] - 1.0) < 1e-6);
    // The controller follows the mapped values (what an open editor shows).
    const auto values = instance->params(true);
    DAW_CHECK(values.size() == 5 && std::fabs(values[kGain].value - 64.0f / 127.0f) < 1e-6f);

    // A slot push and a CC on one parameter in one block: both points, in offset order.
    const int64_t block = gain.block;
    {
        RtScope scope;
        instance->addMidi(MidiEvent{100, 3, {0xB0, 7, 127}}, 512);
        instance->pushParam(kGain, 0.25f);
        DAW_CHECK(instance->render(io, 512));
        DAW_CHECK(scope.violations() == 0);
    }
    const Points both = points(instance, kGain);
    DAW_CHECK(both.block > block && both.offsets == (std::vector<int32_t>{0, 100}));
    DAW_CHECK(both.values.size() == 2 && std::fabs(both.values[0] - 0.25) < 1e-6 && std::fabs(both.values[1] - 1.0) < 1e-6);
    // More changes than a queue holds: the block still ends at the newest value.
    {
        std::vector<MidiEvent> many;
        for (uint32_t k = 0; k < 300; ++k) many.push_back(MidiEvent{k, 3, {0xB0, 7, static_cast<uint8_t>(k % 128)}});
        DAW_CHECK(render(many));
        const Points full = points(instance, kGain);
        DAW_CHECK(!full.values.empty() && full.offsets.back() == 299 && std::fabs(full.values.back() - (299 % 128) / 127.0) < 1e-6);
    }
    return checks;
}

// MARK: DW-225

CheckResult pluginBypassReleasesNotes() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(emberReady());
    DAW_CHECK(registerFakeAudioUnit());
    if (!emberReady()) return checks;

    // A note from tick 1 to 1000 (frames 25…25 000) into an instrument with a bypass slot.
    // `counts(host)` returns {note-offs received, a marker that changes with each All Notes Off the
    // host sends on channel 1 only}. (A new clip player sends its own CC 123 on every channel in its
    // first block, so only changes count.)
    auto run = [&](NodeKind kind, const std::string& configJSON, auto host, auto counts) {
        Rig rig([&](NodeRegistry& r) { (void)r.set(kind, host->kindInfo()); });
        const ParamID bypass = allocate(rig, 1, 0.0f);
        GraphDescription d = baseDescription();
        d.nodes.push_back(NodeDesc{2, NodeKind::midiClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{3, kind, 1, 0, 0, configJSON, bypass});
        d.edges.push_back(EdgeDesc{1, 2, 3, EdgeKind::midi, 0});
        d.edges.push_back(EdgeDesc{2, 3, 1, EdgeKind::audio, 0});
        d.notes.push_back(NoteDesc{2, 1, 999, 60, 100, 0});
        DAW_CHECK(rig.publish(d));
        DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
        renderBlocks(rig, 4800);
        const auto start = counts(host);
        DAW_CHECK(start.first == 0);  // the note is held
        // Bypass on: the toggle block (the plugin's last) releases the note and sends CC 123.
        rig.engine().params().set(bypass, 1.0f);
        renderBlocks(rig, 256);
        const auto toggled = counts(host);
        DAW_CHECK(toggled.first == 1 && toggled.second != start.second);
        // The note ends while bypassed (its note-off never reaches the plugin), then enable it.
        renderBlocks(rig, 24000);
        rig.engine().params().set(bypass, 0.0f);
        renderBlocks(rig, 4800);
        // Bypassing with nothing held sends nothing.
        rig.engine().params().set(bypass, 1.0f);
        renderBlocks(rig, 1024);
        DAW_CHECK(counts(host) == toggled);
        DAW_CHECK(rig.violations() == 0);
    };

    // VST3: CC 123 goes through the mapping, as a point (value 0) on "All Notes Off".
    run(NodeKind::vst3Plugin, VST3PluginConfig::makeJSON(emberIdentifier(kSynthUID), {}),
        std::make_shared<VST3PluginHost>(), [](const std::shared_ptr<VST3PluginHost>& host) {
            auto instance = host->instance(3);
            // The newest block with an "All Notes Off" point, if it had exactly one (channel 1's) at 0.
            const Points allOff = points(instance, kAllOff);
            const bool ours = allOff.values == std::vector<double>{0.0};
            return std::make_pair<int64_t, int64_t>(stats(instance).noteOffs, ours ? allOff.block : -2);
        });
    run(NodeKind::auPlugin, AUPluginConfig::makeJSON(kFake, {}), std::make_shared<AUPluginHost>(),
        [](const std::shared_ptr<AUPluginHost>& host) {
            const FakeProbe p = fake(host->instance(3));
            return std::make_pair(static_cast<int64_t>(p.noteOffs), static_cast<int64_t>(p.allNotesOff));
        });
    return checks;
}

// MARK: DW-218, DW-217 audits

CheckResult vst3TeardownVsLatencyTimer(uint32_t iterations) {
    CheckResult checks;
    DAW_CHECK(emberReady());
    if (!emberReady()) return checks;
    const auto id = parseVST3Identifier(emberIdentifier(kEffectUID));
    std::vector<float> l(256), r(256), in(256, 0.25f);
    float* out[2] = {l.data(), r.data()};
    float* inPtrs[2] = {in.data(), in.data()};
    NodeIO io;
    io.audioIn = AudioBufferView{inPtrs, 2, 256};
    io.audioOut = AudioBufferView{out, 2, 256};
    int lagged = 0;
    for (uint32_t i = 0; i < iterations; ++i) {
        auto made = VST3Instance::instantiate(*id);
        DAW_CHECK(made.ok());
        if (!made) break;
        std::shared_ptr<VST3Instance> instance = std::move(made).value();
        DAW_CHECK(instance->prepare(kRate, 256).ok());
        // Latency changes from this thread and from the audio thread keep the 50 ms timer busy.
        void* controller = controllerOf(instance);
        ember().setLatency(controller, i % 2 ? 64 : 0, 0);
        ember().setLatency(controller, i % 3 ? 32 : 0, 1);
        for (int b = 0; b < 4; ++b) (void)instance->render(io, 256);
        std::this_thread::sleep_for(std::chrono::microseconds((i * 7919) % 60000));  // across a timer tick
        const int64_t processor = stats(instance).processorID;
        DAW_CHECK(processor > 0 && ember().processorLive(processor));
        instance.reset();
        lagged += ember().processorLive(processor) != 0;  // gone with the instance, on this thread
    }
    DAW_CHECK(lagged == 0);
    return checks;
}

CheckResult auInstantiateVsLifecycle(uint32_t iterations) {
    CheckResult checks;
    const auto delay = *parseAUIdentifier(kDelay);
    const auto sampler = *parseAUIdentifier("aumu:samp:appl");
    std::atomic<int> failures{0};
    std::atomic<uint64_t> renderErrors{0};
    std::thread instantiator([&] {
        for (uint32_t i = 0; i < iterations; ++i) {
            auto made = AUInstance::instantiate(i % 2 ? delay : sampler);
            if (!made) failures.fetch_add(1);
        }
    });
    std::thread lifecycle([&] {
        std::vector<float> l(256), r(256);
        float* out[2] = {l.data(), r.data()};
        NodeIO io;
        io.audioOut = AudioBufferView{out, 2, 256};
        for (uint32_t i = 0; i < iterations; ++i) {
            auto made = AUInstance::instantiate(i % 2 ? sampler : delay);
            if (!made || !made.value()->prepare(kRate, 256).ok()) {
                failures.fetch_add(1);
                continue;
            }
            (void)made.value()->render(io, 256);
            renderErrors += made.value()->renderErrors();
        }
    });
    instantiator.join();
    lifecycle.join();
    DAW_CHECK(failures.load() == 0);
    DAW_CHECK(renderErrors.load() == 0);
    DAW_CHECK(eventually([] { return AUInstance::pendingV2Releases() == 0; }, 10000ms));
    return checks;
}

} // namespace daw::testing
