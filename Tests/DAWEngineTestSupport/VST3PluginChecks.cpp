#include "VST3PluginChecks.h"

#include <dlfcn.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <memory>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "ExportTestSupport.h"
#include "NodeTestHarness.h"
#include "TestAudio.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "daw/GraphDescription.h"
#include "graph/NodeRegistry.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "plugins/VST3PluginConfig.h"
#include "plugins/VST3PluginHost.h"
#include "plugins/VST3PluginNode.h"

using namespace std::chrono_literals;

namespace daw::testing {

namespace {

using nodes::baseDescription;
using nodes::kRate;
using nodes::kSamplesPerTick;
using nodes::makeAsset;
using nodes::Rig;

constexpr float kNaN = std::numeric_limits<float>::quiet_NaN();
// AGain's class (the SDK sample names its snapshots after this UID) and our test classes.
constexpr const char* kAgainUID = "84E8DE5F92554F5396FAE4133C935A18";
constexpr const char* kEffectUID = "E4B3E71A000000000000000000000001";
constexpr const char* kSynthUID = "E4B3E71A000000000000000000000002";

// The repository root, from this file's own path (Tests/DAWEngineTestSupport/VST3PluginChecks.cpp).
std::filesystem::path repoRoot() {
    return std::filesystem::path(__FILE__).parent_path().parent_path().parent_path();
}

// scripts/build-test-vst3.sh, once per process; it does nothing when the bundles are current.
// Failing tests when it can't build (rather than skipping) is deliberate: the plugins are in-repo
// sources, so a missing plugin is a broken build.
bool ensureTestPlugins() {
    static const bool built = [] {
        const std::string command = "\"" + (repoRoot() / "scripts/build-test-vst3.sh").string() + "\"";
        return std::system(command.c_str()) == 0;
    }();
    return built;
}

std::string againIdentifier() {
    return (repoRoot() / ".build/test-plugins/again.vst3").string() + "#" + kAgainUID;
}
std::string emberIdentifier(const char* uid) {
    return (repoRoot() / ".build/test-plugins/EmberTest.vst3").string() + "#" + uid;
}

// EmberTest's exported knobs (EmberTestPlugin.cpp).
struct EmberAPI {
    void (*setLatency)(uint32_t) = nullptr;
    void (*requestRestartFromProcess)(uint32_t) = nullptr;
    void (*lastContext)(double*, double*, double*, int64_t*, int32_t*, int32_t*, int32_t*, uint32_t*) = nullptr;
    void (*noteCounts)(int64_t*, int64_t*) = nullptr;
    void (*controllerStats)(int32_t*, double*, float*) = nullptr;
    void (*setControllerValue)(float) = nullptr;
    int32_t (*liveProcessors)() = nullptr;
};

const EmberAPI& ember() {
    static const EmberAPI api = [] {
        EmberAPI a;
        if (!ensureTestPlugins()) return a;
        const auto path = repoRoot() / ".build/test-plugins/EmberTest.vst3/Contents/MacOS/EmberTest";
        // The same image the module loads: dyld keeps one copy per path.
        void* image = dlopen(path.c_str(), RTLD_NOW);
        if (!image) return a;
        a.setLatency = reinterpret_cast<decltype(a.setLatency)>(dlsym(image, "ember_test_set_latency"));
        a.requestRestartFromProcess =
            reinterpret_cast<decltype(a.requestRestartFromProcess)>(dlsym(image, "ember_test_request_restart_from_process"));
        a.lastContext = reinterpret_cast<decltype(a.lastContext)>(dlsym(image, "ember_test_last_context"));
        a.noteCounts = reinterpret_cast<decltype(a.noteCounts)>(dlsym(image, "ember_test_note_counts"));
        a.controllerStats = reinterpret_cast<decltype(a.controllerStats)>(dlsym(image, "ember_test_controller_stats"));
        a.setControllerValue = reinterpret_cast<decltype(a.setControllerValue)>(dlsym(image, "ember_test_set_controller_value"));
        a.liveProcessors = reinterpret_cast<decltype(a.liveProcessors)>(dlsym(image, "ember_test_live_processors"));
        return a;
    }();
    return api;
}

bool emberReady() {
    const EmberAPI& a = ember();
    return a.setLatency && a.requestRestartFromProcess && a.lastContext && a.noteCounts && a.controllerStats &&
           a.setControllerValue && a.liveProcessors;
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

std::string config(const std::string& identifier, const std::vector<uint8_t>& state = {}) {
    return VST3PluginConfig::makeJSON(identifier, state);
}

std::unique_ptr<Rig> makeRig(const std::shared_ptr<VST3PluginHost>& host) {
    return std::make_unique<Rig>([host](NodeRegistry& r) { (void)r.set(NodeKind::vst3Plugin, host->kindInfo()); });
}

ParamID allocate(Rig& rig, uint32_t count, float value = kNaN) {
    auto first = rig.engine().params().allocate(count, value);
    return first ? first.value() : 0;
}

std::vector<uint32_t> randomBlocks(uint32_t seed) {
    std::vector<uint32_t> blocks;
    std::mt19937 rng(seed);
    std::uniform_int_distribution<uint32_t> size(1, 1500);
    for (int i = 0; i < 400; ++i) blocks.push_back(size(rng));
    return blocks;
}

void renderRandom(Rig& rig, int64_t frames, uint32_t seed) {
    const std::vector<uint32_t> blocks = randomBlocks(seed);
    size_t next = 0;
    rig.renderFrames(frames, [&] { return blocks[next++ % blocks.size()]; });
}

bool allEqual(const std::vector<float>& v, size_t from, float value, float eps = 1e-5f) {
    if (v.size() <= from) return false;
    for (size_t i = from; i < v.size(); ++i)
        if (std::fabs(v[i] - value) > eps) return false;
    return true;
}

double infoParamValue(const std::string& json, int index) {
    const std::string key = "{\"index\":" + std::to_string(index) + ",";
    const auto at = json.find(key);
    if (at == std::string::npos) return std::nan("");
    const auto value = json.find("\"value\":", at);
    if (value == std::string::npos) return std::nan("");
    return std::strtod(json.c_str() + value + 8, nullptr);
}

struct FacadeRef {
    EngineFacade* facade;
    explicit FacadeRef(double rate = kRate) {
        DriverConfigPOD config;
        config.sampleRate = rate;
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

// Exports [0, ticks) without a tail and reads the left channel back. Empty on any failure or RT
// violation.
std::vector<float> exportLeft(EngineFacade& f, const std::filesystem::path& path, Tick ticks) {
    ExportSpecPOD spec;
    spec.path = path.string();
    spec.tailEnabled = false;
    const JobID job = f.renderOffline(0, ticks, spec);
    JobStatus status;
    if (!eventually([&] {
            status = f.pollJob(job);
            return status.state == JobState::succeeded || status.state == JobState::failed;
        }, 20000ms))
        return {};
    if (status.state != JobState::succeeded || status.render.rtViolations != 0) return {};
    auto back = readBack(path, kRate);
    if (!back || back->empty()) return {};
    return (*back)[0];
}

uint32_t nodeLatency(EngineFacade& f, NodeID node) {
    for (const NodeLatencyPOD& n : f.nodeLatencies())
        if (n.node == node) return n.samples;
    return 0;
}

} // namespace

// MARK: Identifier and config

CheckResult vst3IdentifierAndConfig() {
    CheckResult checks;
    auto parsed = parseVST3Identifier("/a#b/Plugin.vst3#84e8de5f92554f5396fae4133c935a18");
    DAW_CHECK(parsed.ok());
    if (parsed) {
        DAW_CHECK(parsed->path == "/a#b/Plugin.vst3");
        DAW_CHECK(parsed->classUID == "84E8DE5F92554F5396FAE4133C935A18");
        DAW_CHECK(parsed->identifier() == "/a#b/Plugin.vst3#84E8DE5F92554F5396FAE4133C935A18");
    }
    for (const char* bad : {"", "/x.vst3", "#84E8DE5F92554F5396FAE4133C935A18", "/x.vst3#84E8DE5F",
                            "/x.vst3#84E8DE5F92554F5396FAE4133C935A1G"})
        DAW_CHECK(!parseVST3Identifier(bad).ok());

    const std::vector<uint8_t> state{1, 0, 0xFF, 42};
    const std::string identifier = "/x.vst3#84E8DE5F92554F5396FAE4133C935A18";
    auto config = VST3PluginConfig::parse(VST3PluginConfig::makeJSON(identifier, state));
    DAW_CHECK(config.ok());
    if (config) {
        DAW_CHECK(config->identifier == identifier);
        DAW_CHECK(config->plugin.path == "/x.vst3");
        DAW_CHECK(config->state == state);
    }
    auto plain = VST3PluginConfig::parse(R"({"identifier": "/x.vst3#84E8DE5F92554F5396FAE4133C935A18", "state": ""})");
    DAW_CHECK(plain.ok() && plain->state.empty());
    for (const char* bad : {"", "{}", R"({"identifier": 1})", R"({"identifier": "/x.vst3#nope"})",
                            R"({"identifier": "/x.vst3#84E8DE5F92554F5396FAE4133C935A18", "state": 3})"})
        DAW_CHECK(!VST3PluginConfig::parse(bad).ok());
    return checks;
}

// MARK: again

CheckResult vst3AgainThroughGraph() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(ensureTestPlugins());
    auto host = std::make_shared<VST3PluginHost>();
    auto rig = makeRig(host);
    rig->addAsset(makeAsset(7, 2, 96000, [](uint32_t c, int64_t) { return c == 0 ? 0.25f : -0.5f; }));
    // again's parameters: 0 gain, 1 VU meter (read-only), 2 bypass. Bypass stays NaN (not set).
    const ParamID p = allocate(*rig, 3);
    rig->engine().params().set(p + 0, 0.5f);
    rig->engine().params().set(p + 1, 0.75f);  // read-only: must not be pushed

    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{20, NodeKind::vst3Plugin, 1, p, 3, config(againIdentifier())});
    d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
    d.audioClips.push_back(nodes::clip(10, 1, 0, 3840, 7));
    DAW_CHECK(rig->publish(d));
    auto instance = host->instance(20);
    DAW_CHECK(instance != nullptr);
    if (!instance) return checks;
    DAW_CHECK(instance->isPrepared() && instance->outputChannels() == 2 && instance->inputChannels() == 2);
    DAW_CHECK(instance->params().size() == 3);
    DAW_CHECK(instance->params()[0].writable && !instance->params()[1].writable && instance->params()[2].writable);
    DAW_CHECK(instance->hasAudioInput() && instance->acceptsMIDI() && !instance->hasAuxInput());

    DAW_CHECK(rig->transport().locate(0) && rig->transport().play());
    renderRandom(*rig, 24000, 71);
    DAW_CHECK(rig->violations() == 0);
    DAW_CHECK(allEqual(rig->left(), 0, 0.25f * 0.5f));
    DAW_CHECK(allEqual(rig->right(), 0, -0.5f * 0.5f));

    // Only the gain slot was pushed.
    auto pooled = std::static_pointer_cast<VST3PluginNode>(rig->engine().nodes().get(20));
    DAW_CHECK(pooled && pooled->paramEventsPushed() == 1);
    const auto values = instance->params(true);
    DAW_CHECK(values.size() == 3 && std::fabs(values[0].value - 0.5f) < 1e-6f);

    // A slot change reaches the plugin at the next block (D-13).
    rig->clearOutput();
    rig->engine().params().set(p + 0, 1.0f);
    renderRandom(*rig, 12000, 72);
    DAW_CHECK(rig->violations() == 0);
    DAW_CHECK(allEqual(rig->left(), 0, 0.25f));
    DAW_CHECK(pooled && pooled->paramEventsPushed() == 2);

    // A note's velocity lowers again's gain (again.cpp: gain = fGain - velocity), so the event
    // list reaches the plugin too.
    DAW_CHECK(instance->renderErrors() == 0);
    return checks;
}

// MARK: Notes

CheckResult vst3NoteFrameOffsets() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(emberReady());
    if (!emberReady()) return checks;
    auto host = std::make_shared<VST3PluginHost>();
    auto rig = makeRig(host);
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{2, NodeKind::midiClipPlayer, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{3, NodeKind::vst3Plugin, 1, 0, 0, config(emberIdentifier(kSynthUID))});
    d.edges.push_back(EdgeDesc{1, 2, 3, EdgeKind::midi, 0});
    d.edges.push_back(EdgeDesc{2, 3, 1, EdgeKind::audio, 0});
    struct N { Tick start, length; uint8_t pitch, velocity; };
    const std::vector<N> notes{{1, 10, 60, 127}, {37, 5, 61, 64}, {38, 100, 62, 32}, {201, 3, 63, 100}, {599, 1, 64, 1}};
    for (const N& n : notes) d.notes.push_back(NoteDesc{2, n.start, n.length, n.pitch, n.velocity, 0});
    DAW_CHECK(rig->publish(d));
    int64_t onsBefore = 0, offsBefore = 0;
    ember().noteCounts(&onsBefore, &offsBefore);
    DAW_CHECK(rig->transport().locate(0) && rig->transport().play());
    renderRandom(*rig, 640 * kSamplesPerTick, 73);
    DAW_CHECK(rig->violations() == 0);
    int64_t ons = 0, offs = 0;
    ember().noteCounts(&ons, &offs);
    DAW_CHECK(ons - onsBefore == static_cast<int64_t>(notes.size()));
    DAW_CHECK(offs - offsBefore == static_cast<int64_t>(notes.size()));
    const auto& l = rig->left();
    std::vector<float> expected(l.size(), 0.0f);
    for (const N& n : notes) expected[size_t(n.start * kSamplesPerTick)] = n.velocity / 127.0f;
    int wrong = 0;
    for (size_t i = 0; i < l.size(); ++i) wrong += std::fabs(l[i] - expected[i]) > 1e-6f;
    DAW_CHECK(wrong == 0);
    DAW_CHECK(rig->right() == l);
    // No input bus: an instrument.
    auto instance = host->instance(3);
    DAW_CHECK(instance && !instance->hasAudioInput() && instance->acceptsMIDI() && instance->inputChannels() == 0);
    return checks;
}

// MARK: Process context

CheckResult vst3ProcessContext() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(emberReady());
    if (!emberReady()) return checks;
    auto host = std::make_shared<VST3PluginHost>();
    auto rig = makeRig(host);
    GraphDescription d = baseDescription();  // 120 bpm, 4/4
    d.nodes.push_back(NodeDesc{20, NodeKind::vst3Plugin, 1, 0, 0, config(emberIdentifier(kEffectUID))});
    d.edges.push_back(EdgeDesc{1, 20, 1, EdgeKind::audio, 0});
    DAW_CHECK(rig->publish(d));

    // Locate into the second bar plus one beat: tick 4 × 960 + 960 = 4800.
    DAW_CHECK(rig->transport().locate(4800) && rig->transport().play());
    rig->render(512);
    DAW_CHECK(rig->violations() == 0);

    double tempo = 0, ppq = 0, bar = 0;
    int64_t samples = -1;
    int32_t playing = -1, num = 0, den = 0;
    uint32_t state = 0;
    ember().lastContext(&tempo, &ppq, &bar, &samples, &playing, &num, &den, &state);
    DAW_CHECK(std::fabs(tempo - 120.0) < 1e-9);
    DAW_CHECK(std::fabs(ppq - 5.0) < 1e-9);
    DAW_CHECK(std::fabs(bar - 4.0) < 1e-9);
    DAW_CHECK(samples == 4800 * kSamplesPerTick);
    DAW_CHECK(playing == 1);
    DAW_CHECK(num == 4 && den == 4);
    DAW_CHECK((state & Steinberg::Vst::ProcessContext::kTempoValid) != 0);
    DAW_CHECK((state & Steinberg::Vst::ProcessContext::kProjectTimeMusicValid) != 0);
    DAW_CHECK((state & Steinberg::Vst::ProcessContext::kBarPositionValid) != 0);
    DAW_CHECK((state & Steinberg::Vst::ProcessContext::kTimeSigValid) != 0);

    // Second block carries on where the first ended (samples advance by 512).
    rig->render(256);
    ember().lastContext(&tempo, &ppq, &bar, &samples, &playing, &num, &den, &state);
    DAW_CHECK(samples == 4800 * kSamplesPerTick + 512);

    // Stopped: playing false.
    DAW_CHECK(rig->transport().stop());
    rig->render(256);
    ember().lastContext(&tempo, &ppq, &bar, &samples, &playing, &num, &den, &state);
    DAW_CHECK(playing == 0);
    DAW_CHECK((state & Steinberg::Vst::ProcessContext::kPlaying) == 0);
    DAW_CHECK(rig->violations() == 0);
    return checks;
}

// MARK: Sidechain

CheckResult vst3Sidechain() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(emberReady());
    if (!emberReady()) return checks;
    auto host = std::make_shared<VST3PluginHost>();
    auto rig = makeRig(host);
    rig->addAsset(makeAsset(7, 1, 96000, [](uint32_t, int64_t) { return 0.25f; }));
    rig->addAsset(makeAsset(8, 1, 96000, [](uint32_t, int64_t) { return 0.5f; }));
    // Params: 0 gain (left at its default, 1), 1 sidechain mix = 1.
    const ParamID p = allocate(*rig, 2);
    rig->engine().params().set(p + 1, 1.0f);

    auto graph = [&](bool sidechain) {
        GraphDescription d = baseDescription();
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{11, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{20, NodeKind::vst3Plugin, 1, p, 2, config(emberIdentifier(kEffectUID))});
        d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
        if (sidechain) d.edges.push_back(EdgeDesc{3, 11, 20, EdgeKind::sidechain, 0});
        d.audioClips.push_back(nodes::clip(10, 1, 0, 3840, 7));
        d.audioClips.push_back(nodes::clip(11, 2, 0, 3840, 8));
        return d;
    };

    DAW_CHECK(rig->publish(graph(true)));
    auto instance = host->instance(20);
    DAW_CHECK(instance && instance->hasAuxInput() && instance->sidechainEnabled());
    DAW_CHECK(rig->transport().locate(0) && rig->transport().play());
    renderRandom(*rig, 12000, 74);
    DAW_CHECK(allEqual(rig->left(), 0, 0.75f) && allEqual(rig->right(), 0, 0.75f));  // main + sidechain

    // Without the edge the aux bus hears silence (the same plugin, kept across the rebuild).
    rig->clearOutput();
    DAW_CHECK(rig->publish(graph(false)));
    DAW_CHECK(host->instance(20) == instance);
    renderRandom(*rig, 12000, 75);
    DAW_CHECK(allEqual(rig->left(), 1024, 0.25f));
    DAW_CHECK(rig->violations() == 0);
    return checks;
}

// MARK: Latency (through the facade)

CheckResult vst3LatencyChange() {
    CheckResult checks;
    DAW_CHECK(emberReady());
    if (!emberReady()) return checks;
    ember().setLatency(0);
    TempDir dir;
    FacadeRef f;
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    const auto file = dir.path() / "impulse.wav";
    std::vector<float> impulse(48000, 0.0f);
    impulse[0] = 1.0f;
    DAW_CHECK(writeTestFile(file, "wav-f32", kRate, Channels{impulse}).ok());
    const JobID load = f->loadAsset(7, file.string());
    DAW_CHECK(eventually([&] { return f->pollJob(load).state == JobState::succeeded; }));

    // A dry path and a plugin path, summed at the master; PDC must keep both impulses on frame 0.
    GraphDescriptionBuilder g;
    g.addNode(1, NodeKind::master, 0, 0, 0, "");
    g.addNode(3, NodeKind::bus, 0, 0, 0, "");
    g.addNode(10, NodeKind::audioClipPlayer, 0, 0, 0, "");
    g.addNode(11, NodeKind::audioClipPlayer, 0, 0, 0, "");
    g.addNode(20, NodeKind::vst3Plugin, 0, 0, 0, config(emberIdentifier(kEffectUID)));
    g.addEdge(1, 10, 3, EdgeKind::audio, 0);
    g.addEdge(2, 11, 20, EdgeKind::audio, 0);
    g.addEdge(3, 20, 3, EdgeKind::audio, 0);
    g.addEdge(4, 3, 1, EdgeKind::audio, 0);
    g.addClip(10, 1, 0, 1920, 7, 0, 1.0f, 0, 0);
    g.addClip(11, 2, 0, 1920, 7, 0, 1.0f, 0, 0);
    g.setTempo(0, 120.0);
    g.setTimeSignature(0, 4, 4);
    g.setMaster(1);
    DAW_CHECK(published(*f.facade, f->applyGraph(g.description())));

    auto check = [&](uint32_t latency, const char* name) {
        const auto out = exportLeft(*f.facade, dir.path() / name, 960);
        bool ok = out.size() == 24000 && std::fabs(out[0] - 2.0f) < 1e-6f;
        for (size_t i = 1; ok && i < out.size(); ++i) ok = std::fabs(out[i]) < 1e-6f;
        return ok && f->telemetry().graphLatency == latency && nodeLatency(*f.facade, 20) == latency;
    };
    DAW_CHECK(check(0, "a.wav"));
    const uint64_t before = f->graphStatus().publishedVersion;

    // restartComponent from a plain thread.
    ember().setLatency(480);
    DAW_CHECK(eventually([&] { return f->pluginInfoJSON(20).find("\"latencySamples\":480") != std::string::npos; }));
    DAW_CHECK(eventually([&] { return check(480, "b.wav"); }, 10000ms));
    DAW_CHECK(f->graphStatus().publishedVersion == before);

    // restartComponent on the audio thread: the handler only flips an atomic (an export rendering
    // in an RtScope would report a violation otherwise; exportLeft requires 0).
    ember().requestRestartFromProcess(240);
    DAW_CHECK(exportLeft(*f.facade, dir.path() / "c.wav", 96).size() == 2400);  // runs process()
    DAW_CHECK(eventually([&] { return f->pluginInfoJSON(20).find("\"latencySamples\":240") != std::string::npos; }));
    DAW_CHECK(eventually([&] { return check(240, "d.wav"); }, 10000ms));

    ember().setLatency(0);
    DAW_CHECK(eventually([&] { return f->pluginInfoJSON(20).find("\"latencySamples\":0") != std::string::npos; }));
    DAW_CHECK(eventually([&] { return check(0, "e.wav"); }, 10000ms));
    return checks;
}

// MARK: State (PLUG-016)

CheckResult vst3StateRoundTrip() {
    CheckResult checks;
    DAW_CHECK(emberReady());
    if (!emberReady()) return checks;
    TempDir dir;
    const std::string identifier = emberIdentifier(kEffectUID);
    std::vector<uint8_t> tweaked, defaults;

    auto graph = [&](EngineFacade& f, const std::vector<uint8_t>& state, ParamID p, uint32_t count) {
        GraphDescriptionBuilder g;
        g.addNode(1, NodeKind::master, 0, 0, 0, "");
        g.addNode(20, NodeKind::vst3Plugin, 0, p, count, config(identifier, state));
        g.addEdge(1, 20, 1, EdgeKind::audio, 0);
        g.setTempo(0, 120.0);
        g.setTimeSignature(0, 4, 4);
        g.setMaster(1);
        return published(f, f.applyGraph(g.description()));
    };

    {
        FacadeRef f;
        DAW_CHECK(f.facade != nullptr);
        if (!f.facade) return checks;
        // Defaults, from a parked instance.
        const JobID job = f->instantiatePlugin(99, PluginDescriptorPOD{PluginFormatPOD::vst3, identifier, "", "", ""});
        DAW_CHECK(f->pollJob(job).state == JobState::succeeded);
        defaults = f->getPluginState(99);
        DAW_CHECK(defaults.size() > 24 && std::string(defaults.begin(), defaults.begin() + 4) == "EVS3");

        // Slot 20: gain (param 0) = 0.25 from its slot; mix left alone.
        const ParamID p = f->allocateParams(2);
        f->setParam(p + 0, 0.25f);
        f->setParam(p + 1, kNaN);
        DAW_CHECK(graph(*f.facade, {}, p, 2));
        DAW_CHECK(exportLeft(*f.facade, dir.path() / "a.wav", 96).size() == 2400);  // pushes the slot
        ember().setControllerValue(7.5f);
        tweaked = f->getPluginState(20);
        DAW_CHECK(!tweaked.empty() && tweaked != defaults);
        DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 0) - 0.25) < 1e-6);

        // A state the plugin refuses changes nothing and is reported.
        f->setPluginState(20, ByteVector{1, 2, 3});
        DAW_CHECK(f->getPluginState(20) == tweaked);
        std::vector<EngineEventPOD> events(64);
        events.resize(f->pollEvents(events.data(), events.size()));
        DAW_CHECK(std::any_of(events.begin(), events.end(), [](const EngineEventPOD& e) {
            return e.type == EngineEventType::pluginCrashed && e.subject == 20 && !e.error.ok();
        }));

        // IO-021 (5): a session-rate change makes a new instance at the new rate with the old state.
        DAW_CHECK(f->setSessionSampleRate(96000).ok());
        DAW_CHECK(eventually([&] { return f->pluginInfoJSON(20).find("\"loaded\":true") != std::string::npos; }));
        DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 0) - 0.25) < 1e-6);
    }
    {
        // A new engine restores the slot from the configJSON state (a project being opened), and
        // the controller is told about the component's state.
        ember().setControllerValue(0.0f);
        int32_t callsBefore = 0;
        double gainBefore = 0;
        float controllerBefore = 0;
        ember().controllerStats(&callsBefore, &gainBefore, &controllerBefore);
        FacadeRef f;
        if (!f.facade) return checks;
        DAW_CHECK(graph(*f.facade, tweaked, 0, 0));
        DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 0) - 0.25) < 1e-6);
        int32_t calls = 0;
        double lastGain = 0;
        float controllerValue = 0;
        ember().controllerStats(&calls, &lastGain, &controllerValue);
        DAW_CHECK(calls > callsBefore);                 // setComponentState reached the controller
        DAW_CHECK(std::fabs(lastGain - 0.25) < 1e-6);
        DAW_CHECK(std::fabs(controllerValue - 7.5f) < 1e-6f);  // the controller state round trips
        // And setPluginState puts the defaults back.
        f->setPluginState(20, defaults);
        DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 0) - 1.0) < 1e-6);
        DAW_CHECK(f->getPluginState(20) != tweaked);
    }
    return checks;
}

// MARK: Failure and adoption

CheckResult vst3FailureAndAdoption() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(emberReady());
    if (!emberReady()) return checks;
    auto host = std::make_shared<VST3PluginHost>();
    auto rig = makeRig(host);
    rig->addAsset(makeAsset(7, 1, 96000, [](uint32_t, int64_t) { return 0.25f; }));
    const std::string missing = "/nonexistent/Missing.vst3#84E8DE5F92554F5396FAE4133C935A18";
    const std::string effect = emberIdentifier(kEffectUID);

    auto graph = [&](const std::string& fx, uint32_t version, ParamID first = 0, uint32_t count = 0) {
        GraphDescription d = baseDescription();
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{20, NodeKind::vst3Plugin, version, first, count, fx});
        d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
        d.audioClips.push_back(nodes::clip(10, 1, 0, 3840, 7));
        return d;
    };

    // A missing plugin passes through, is reported once, and keeps its configured state.
    DAW_CHECK(rig->publish(graph(config(missing), 1)));
    DAW_CHECK(rig->transport().locate(0) && rig->transport().play());
    renderRandom(*rig, 4800, 76);
    DAW_CHECK(rig->violations() == 0);
    DAW_CHECK(allEqual(rig->left(), 0, 0.25f));
    auto failures = host->takeFailures();
    DAW_CHECK(failures.size() == 1 && failures[0].slot == 20 && failures[0].error.code == ErrorCode::notFound);
    DAW_CHECK(host->infoJSON(20).find("\"loaded\":false") != std::string::npos);
    DAW_CHECK(host->infoJSON(20).find("\"error\":") != std::string::npos);
    const std::vector<uint8_t> kept{9, 8, 7};
    DAW_CHECK(rig->publish(graph(config(missing, kept), 2)));
    DAW_CHECK(host->state(20).ok() && host->state(20).value() == kept);
    (void)host->takeFailures();

    // A real plugin, kept across a configVersion bump and a param-range change.
    DAW_CHECK(rig->publish(graph(config(effect), 3)));
    auto first = host->instance(20);
    DAW_CHECK(first != nullptr);
    const ParamID p = allocate(*rig, 2);
    DAW_CHECK(rig->publish(graph(config(effect), 4, p, 2)));
    DAW_CHECK(host->instance(20) == first);
    // A new identifier is a new instance.
    DAW_CHECK(rig->publish(graph(config(emberIdentifier(kSynthUID)), 5)));
    DAW_CHECK(host->instance(20) != first && host->instance(20) != nullptr);
    renderRandom(*rig, 4800, 77);
    DAW_CHECK(rig->violations() == 0);

    // instantiate parks an instance; the build adopts it instead of making a second one.
    rig->clearOutput();
    DAW_CHECK(rig->publish(baseDescription()));
    DAW_CHECK(rig->reclaimPasses(2));
    const int processorsBefore = ember().liveProcessors();
    DAW_CHECK(host->instantiate(40, effect).ok());
    DAW_CHECK(ember().liveProcessors() == processorsBefore + 1);
    DAW_CHECK(!host->instantiate(41, missing).ok());
    DAW_CHECK(host->infoJSON(40).find("\"loaded\":true") != std::string::npos);
    // A state set before slot 41 had a plugin is applied to its first one (here a state the
    // plugin refuses, which shows up as a failure when the node is made).
    DAW_CHECK(host->setState(41, std::vector<uint8_t>{1, 2, 3}).ok());
    DAW_CHECK(host->state(41).ok() && host->state(41).value() == std::vector<uint8_t>({1, 2, 3}));
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{40, NodeKind::vst3Plugin, 1, 0, 0, config(effect)});
    d.nodes.push_back(NodeDesc{41, NodeKind::vst3Plugin, 1, 0, 0, config(emberIdentifier(kEffectUID))});
    d.edges.push_back(EdgeDesc{1, 40, 41, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{2, 41, 1, EdgeKind::audio, 0});
    DAW_CHECK(rig->publish(d));
    DAW_CHECK(ember().liveProcessors() == processorsBefore + 2);  // 40 adopted, 41 new
    DAW_CHECK(host->instance(40) != nullptr && host->instance(41) != nullptr);
    failures = host->takeFailures();
    DAW_CHECK(failures.size() == 1 && failures[0].slot == 41 && failures[0].error.code == ErrorCode::invalidArgument);
    auto later = host->state(41);
    DAW_CHECK(later.ok() && later.value() != std::vector<uint8_t>({1, 2, 3}));  // the pending state is used up
    renderRandom(*rig, 4800, 78);
    DAW_CHECK(rig->violations() == 0);
    return checks;
}

} // namespace daw::testing
