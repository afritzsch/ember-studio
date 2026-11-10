#include "AUPluginChecks.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "NodeTestHarness.h"
#include "TestAudio.h"
#include "ExportTestSupport.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "daw/GraphDescription.h"
#include "graph/NodeRegistry.h"
#include "plugins/AUIdentifier.h"
#include "plugins/AUInstance.h"
#include "plugins/AUPluginConfig.h"
#include "plugins/AUPluginHost.h"
#include "plugins/AUPluginNode.h"

using namespace std::chrono_literals;

namespace daw::testing {

namespace {

using nodes::baseDescription;
using nodes::kRate;
using nodes::kSamplesPerTick;
using nodes::makeAsset;
using nodes::Rig;

constexpr const char* kDelay = "aufx:dely:appl";
constexpr const char* kSampler = "aumu:samp:appl";
constexpr const char* kFake = "aumf:fAke:Embr";
constexpr float kNaN = std::numeric_limits<float>::quiet_NaN();

template <class F>
bool eventually(F done, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

std::string config(const char* identifier, const std::vector<uint8_t>& state = {}) {
    return AUPluginConfig::makeJSON(identifier, state);
}

// A rig whose registry has `host`'s auPlugin kind.
std::unique_ptr<Rig> makeRig(const std::shared_ptr<AUPluginHost>& host) {
    return std::make_unique<Rig>([host](NodeRegistry& r) { (void)r.set(NodeKind::auPlugin, host->kindInfo()); });
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

size_t firstAbove(const std::vector<float>& v, float threshold) {
    for (size_t i = 0; i < v.size(); ++i)
        if (std::fabs(v[i]) > threshold) return i;
    return v.size();
}

// The param value the facade's pluginInfoJSON reports at `index`, NaN if not found.
double infoParamValue(const std::string& json, int index) {
    const std::string key = "{\"index\":" + std::to_string(index) + ",";
    const auto at = json.find(key);
    if (at == std::string::npos) return std::nan("");
    const auto value = json.find("\"value\":", at);
    if (value == std::string::npos) return std::nan("");
    return std::strtod(json.c_str() + value + 8, nullptr);
}

} // namespace

// MARK: Identifier and config

CheckResult auIdentifierAndConfig() {
    CheckResult checks;
    auto delay = parseAUIdentifier("aufx:dely:appl");
    DAW_CHECK(delay.ok());
    if (delay) {
        DAW_CHECK(delay->type == AUComponentID::fourCC("aufx"));
        DAW_CHECK(delay->subtype == AUComponentID::fourCC("dely"));
        DAW_CHECK(delay->manufacturer == AUComponentID::fourCC("appl"));
        DAW_CHECK(!delay->isInstrument());
        DAW_CHECK(formatAUIdentifier(*delay) == "aufx:dely:appl");
    }
    auto sampler = parseAUIdentifier("aumu:samp:appl");
    DAW_CHECK(sampler.ok() && sampler->isInstrument());
    // DLS synth's subtype has a trailing space; hex for non-printable codes and ':' (PLUG-002).
    DAW_CHECK(parseAUIdentifier("aumu:dls :appl").ok());
    auto hex = parseAUIdentifier("0x00000001:a:bc:0x6170706C");
    DAW_CHECK(!hex.ok());  // "a:bc" is no field
    auto hex2 = parseAUIdentifier("0x00000001:0x3A3A3A3A:appl");
    DAW_CHECK(hex2.ok() && hex2->type == 1 && hex2->subtype == 0x3A3A3A3A);
    if (hex2) DAW_CHECK(formatAUIdentifier(*hex2) == "0x00000001:0x3A3A3A3A:appl");
    for (const char* bad : {"", "aufx", "aufx:dely", "aufx:dely:appl:x", "aufx:dly:appl", "aufx:delay:appl",
                            "0xZZZZZZZZ:dely:appl"})
        DAW_CHECK(!parseAUIdentifier(bad).ok());

    const std::vector<uint8_t> state{0x62, 0x70, 0x00, 0xFF, 0x2F};
    const std::string json = AUPluginConfig::makeJSON("aufx:dely:appl", state);
    DAW_CHECK(json.find("\"identifier\":\"aufx:dely:appl\"") != std::string::npos);
    auto parsed = AUPluginConfig::parse(json);
    DAW_CHECK(parsed.ok());
    if (parsed) {
        DAW_CHECK(parsed->identifier == "aufx:dely:appl");
        DAW_CHECK(parsed->state == state);
    }
    auto plain = AUPluginConfig::parse(R"({"identifier": "aumu:samp:appl", "state": "", "other": 1})");
    DAW_CHECK(plain.ok() && plain->state.empty() && plain->component.isInstrument());
    for (const char* bad : {"", "[]", "{}", R"({"identifier": 5})", R"({"identifier": "x:y:z"})",
                            R"({"identifier": "aufx:dely:appl", "state": 3})",
                            R"({"identifier": "aufx:dely:appl", "state": "***"})"})
        DAW_CHECK(!AUPluginConfig::parse(bad).ok());
    return checks;
}

// MARK: AUDelay

CheckResult auDelayThroughGraph() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    auto host = std::make_shared<AUPluginHost>();
    auto rig = makeRig(host);
    rig->addAsset(makeAsset(7, 1, 48000, [](uint32_t, int64_t i) { return i == 0 ? 1.0f : 0.0f; }));
    // AUDelay's parameters (allParameters order): 0 dry/wet mix %, 1 delay time s, 2 feedback %,
    // 3 lowpass cutoff Hz.
    const ParamID p = allocate(*rig, 4);
    rig->engine().params().set(p + 0, 100.0f);
    rig->engine().params().set(p + 1, 0.25f);
    rig->engine().params().set(p + 2, 0.0f);
    rig->engine().params().set(p + 3, 1e9f);  // clamped to the parameter's maximum

    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{20, NodeKind::auPlugin, 1, p, 4, config(kDelay)});
    d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
    d.audioClips.push_back(nodes::clip(10, 1, 0, 1920, 7));
    DAW_CHECK(rig->publish(d));
    auto instance = host->instance(20);
    DAW_CHECK(instance != nullptr);
    if (!instance) return checks;
    DAW_CHECK(instance->isPrepared() && instance->outputChannels() == 2 && instance->inputChannels() == 2);
    DAW_CHECK(instance->params().size() == 4);

    DAW_CHECK(rig->transport().locate(0) && rig->transport().play());
    renderRandom(*rig, 24000, 61);
    DAW_CHECK(rig->violations() == 0);
    const auto& l = rig->left();
    const auto& r = rig->right();
    DAW_CHECK(l.size() == 24000);
    if (l.size() != 24000) return checks;
    // Wet only: nothing until the echo, which arrives 0.25 s (12000 frames) after the impulse.
    const size_t onset = firstAbove(l, 1e-4f);
    // AUDelay itself lands the echo one frame late (12001 on macOS 27); allow ±2.
    DAW_CHECK(onset >= 11998 && onset <= 12002);
    const auto peak = std::max_element(l.begin(), l.end(), [](float a, float b) { return std::fabs(a) < std::fabs(b); });
    DAW_CHECK(std::abs(static_cast<long>(peak - l.begin()) - 12000) <= 2);
    DAW_CHECK(std::fabs(*peak) > 0.5f);
    DAW_CHECK(firstAbove(r, 1e-4f) == onset);
    // Each of the four slots was pushed once (they never changed again).
    auto pooled = std::static_pointer_cast<AUPluginNode>(rig->engine().nodes().get(20));
    DAW_CHECK(pooled && pooled->paramEventsPushed() == 4);
    // DW-214: AUDelay is a V2 AU; its parameter tree follows render-thread events from Apple's
    // listener queue a little later (AUInstance.h), so wait for it rather than read once.
    std::vector<AUParamInfo> values;
    DAW_CHECK(eventually([&] {
        values = instance->params(true);
        return values.size() == 4 && std::fabs(values[1].value - 0.25f) < 1e-6f && values[0].value == 100.0f;
    }));
    DAW_CHECK(instance->renderErrors() == 0);
    return checks;
}

// MARK: MIDI

CheckResult auMidiFrameOffsets() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(registerFakeAudioUnit());
    auto host = std::make_shared<AUPluginHost>();

    // The fake writes velocity/127 at each note-on's frame; it has no audio input here.
    {
        auto rig = makeRig(host);
        GraphDescription d = baseDescription();
        d.nodes.push_back(NodeDesc{2, NodeKind::midiClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{3, NodeKind::auPlugin, 1, 0, 0, config(kFake)});
        d.edges.push_back(EdgeDesc{1, 2, 3, EdgeKind::midi, 0});
        d.edges.push_back(EdgeDesc{2, 3, 1, EdgeKind::audio, 0});
        struct N { Tick start, length; uint8_t pitch, velocity; };
        const std::vector<N> notes{{1, 10, 60, 127}, {37, 5, 61, 64}, {38, 100, 62, 32}, {201, 3, 63, 100},
                                   {599, 1, 64, 1}};
        for (const N& n : notes) d.notes.push_back(NoteDesc{2, n.start, n.length, n.pitch, n.velocity, 0});
        DAW_CHECK(rig->publish(d));
        const uint64_t before = fakeAudioUnitNoteOns();
        DAW_CHECK(rig->transport().locate(0) && rig->transport().play());
        renderRandom(*rig, 640 * kSamplesPerTick, 62);
        DAW_CHECK(rig->violations() == 0);
        DAW_CHECK(fakeAudioUnitNoteOns() - before == notes.size());
        const auto& l = rig->left();
        std::vector<float> expected(l.size(), 0.0f);
        for (const N& n : notes) expected[size_t(n.start * kSamplesPerTick)] = n.velocity / 127.0f;
        int wrong = 0;
        for (size_t i = 0; i < l.size(); ++i) wrong += std::fabs(l[i] - expected[i]) > 1e-6f;
        DAW_CHECK(wrong == 0);
        DAW_CHECK(rig->right() == l);
    }

    // AUSampler (an instrument: no input bus) sounds from its note's frame on.
    {
        auto rig = makeRig(host);
        GraphDescription d = baseDescription();
        d.nodes.push_back(NodeDesc{2, NodeKind::midiClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{4, NodeKind::auPlugin, 1, 0, 0, config(kSampler)});
        d.edges.push_back(EdgeDesc{1, 2, 4, EdgeKind::midi, 0});
        d.edges.push_back(EdgeDesc{2, 4, 1, EdgeKind::audio, 0});
        d.notes.push_back(NoteDesc{2, 192, 480, 69, 100, 0});  // frame 4800
        DAW_CHECK(rig->publish(d));
        auto instance = host->instance(4);
        DAW_CHECK(instance && !instance->hasAudioInput() && instance->acceptsMIDI());
        DAW_CHECK(rig->transport().locate(0) && rig->transport().play());
        renderRandom(*rig, 24000, 63);
        DAW_CHECK(rig->violations() == 0);
        const size_t onset = firstAbove(rig->left(), 1e-4f);
        DAW_CHECK(onset >= 4800 && onset < 4800 + 256);
        float peak = 0;
        for (size_t i = 6000; i < 16000 && i < rig->left().size(); ++i) peak = std::max(peak, std::fabs(rig->left()[i]));
        DAW_CHECK(peak > 0.05f);
    }
    return checks;
}

// MARK: Sidechain

CheckResult auSidechain() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(registerFakeAudioUnit());
    auto host = std::make_shared<AUPluginHost>();
    auto rig = makeRig(host);
    rig->addAsset(makeAsset(7, 1, 96000, [](uint32_t, int64_t) { return 0.25f; }));
    rig->addAsset(makeAsset(8, 1, 96000, [](uint32_t, int64_t) { return 0.5f; }));
    // Fake params: 0 gain (left alone: NaN), 1 sidechain mix = 1.
    const ParamID p = allocate(*rig, 2);
    rig->engine().params().set(p + 1, 1.0f);

    auto graph = [&](bool sidechain) {
        GraphDescription d = baseDescription();
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{11, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{20, NodeKind::auPlugin, 1, p, 2, config(kFake)});
        d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
        if (sidechain) d.edges.push_back(EdgeDesc{3, 11, 20, EdgeKind::sidechain, 0});
        d.audioClips.push_back(nodes::clip(10, 1, 0, 3840, 7));
        d.audioClips.push_back(nodes::clip(11, 2, 0, 3840, 8));
        return d;
    };
    auto all = [](const std::vector<float>& v, size_t from, float value) {
        if (v.size() <= from) return false;
        for (size_t i = from; i < v.size(); ++i)
            if (std::fabs(v[i] - value) > 1e-6f) return false;
        return true;
    };

    DAW_CHECK(rig->publish(graph(true)));
    auto instance = host->instance(20);
    DAW_CHECK(instance && instance->hasAuxInput() && instance->sidechainEnabled());
    DAW_CHECK(rig->transport().locate(0) && rig->transport().play());
    renderRandom(*rig, 12000, 64);
    DAW_CHECK(all(rig->left(), 0, 0.75f) && all(rig->right(), 0, 0.75f));  // main + sidechain

    // Without the edge the aux bus hears silence (the same AU, kept across the rebuild).
    rig->clearOutput();
    DAW_CHECK(rig->publish(graph(false)));
    DAW_CHECK(host->instance(20) == instance);
    renderRandom(*rig, 12000, 65);
    DAW_CHECK(all(rig->left(), 1024, 0.25f));
    DAW_CHECK(rig->violations() == 0);

    // AUDelay has no aux input bus.
    auto delay = AUInstance::instantiate(*parseAUIdentifier(kDelay));
    DAW_CHECK(delay.ok() && !delay.value()->hasAuxInput());
    return checks;
}

// MARK: Latency (through the facade)

namespace {

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

// Exports [0, ticks) without a tail into `path` and reads it back (left channel).
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

CheckResult auLatencyChange() {
    CheckResult checks;
    DAW_CHECK(registerFakeAudioUnit());
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

    // A dry path (clip 10 → bus 3) and a latent one (clip 11 → fake 20 → bus 3), summed at the
    // master. PDC (MIX-021) must keep both impulses on frame 0 whatever the fake's latency.
    GraphDescriptionBuilder g;
    g.addNode(1, NodeKind::master, 0, 0, 0, "");
    g.addNode(3, NodeKind::bus, 0, 0, 0, "");
    g.addNode(10, NodeKind::audioClipPlayer, 0, 0, 0, "");
    g.addNode(11, NodeKind::audioClipPlayer, 0, 0, 0, "");
    g.addNode(20, NodeKind::auPlugin, 0, 0, 0, config(kFake));
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
    setFakeAudioUnitLatency(0.01);  // 480 frames, reported through KVO
    DAW_CHECK(eventually([&] { return f->pluginInfoJSON(20).find("\"latencySamples\":480") != std::string::npos; }));
    // MIX-024: the compiler rebuilds on its own (no applyGraph; a latency rebuild republishes the
    // same version), re-planning PDC. Telemetry's graph latency comes from rendering, so export.
    DAW_CHECK(eventually([&] { return check(480, "b.wav"); }, 10000ms));
    DAW_CHECK(f->graphStatus().publishedVersion == before);
    setFakeAudioUnitLatency(0.0);
    DAW_CHECK(eventually([&] { return f->pluginInfoJSON(20).find("\"latencySamples\":0") != std::string::npos; }));
    DAW_CHECK(eventually([&] { return check(0, "c.wav"); }, 10000ms));
    return checks;
}

// MARK: State (PLUG-016)

CheckResult auStateRoundTrip() {
    CheckResult checks;
    TempDir dir;
    std::vector<uint8_t> tweaked, defaults;
    {
        FacadeRef f;
        DAW_CHECK(f.facade != nullptr);
        if (!f.facade) return checks;
        // Defaults, from a parked instance.
        const JobID job = f->instantiatePlugin(99, PluginDescriptorPOD{PluginFormatPOD::audioUnit, kDelay, "", "", ""});
        DAW_CHECK(f->pollJob(job).state == JobState::succeeded);
        defaults = f->getPluginState(99);
        DAW_CHECK(defaults.size() > 8 && std::string(defaults.begin(), defaults.begin() + 6) == "bplist");

        // Slot 20: delay time (param 1) = 0.5 from its slot; the others left alone.
        const ParamID p = f->allocateParams(4);
        for (ParamID i = 0; i < 4; ++i) f->setParam(p + i, kNaN);
        f->setParam(p + 1, 0.5f);
        GraphDescriptionBuilder g;
        g.addNode(1, NodeKind::master, 0, 0, 0, "");
        g.addNode(3, NodeKind::bus, 0, 0, 0, "");
        g.addNode(20, NodeKind::auPlugin, 0, p, 4, config(kDelay));
        g.addEdge(1, 3, 20, EdgeKind::audio, 0);
        g.addEdge(2, 20, 1, EdgeKind::audio, 0);
        g.setTempo(0, 120.0);
        g.setTimeSignature(0, 4, 4);
        g.setMaster(1);
        DAW_CHECK(published(*f.facade, f->applyGraph(g.description())));
        DAW_CHECK(exportLeft(*f.facade, dir.path() / "a.wav", 96).size() == 2400);  // pushes the params
        DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 1) - 0.5) < 1e-6);
        tweaked = f->getPluginState(20);
        DAW_CHECK(!tweaked.empty() && tweaked != defaults);

        // A state the AU refuses changes nothing and is reported.
        f->setPluginState(20, ByteVector{1, 2, 3});
        DAW_CHECK(f->getPluginState(20) == tweaked);
        std::vector<EngineEventPOD> events(64);
        events.resize(f->pollEvents(events.data(), events.size()));
        DAW_CHECK(std::any_of(events.begin(), events.end(), [](const EngineEventPOD& e) {
            return e.type == EngineEventType::pluginCrashed && e.subject == 20 && !e.error.ok();
        }));

        // IO-021 (5): a session-rate change makes a new AU at the new rate with the old one's state.
        DAW_CHECK(f->setSessionSampleRate(96000).ok());
        DAW_CHECK(eventually([&] { return f->pluginInfoJSON(20).find("\"loaded\":true") != std::string::npos; }));
        DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 1) - 0.5) < 1e-6);
    }
    {
        // A new engine restores the slot from the configJSON state (a project being opened)...
        FacadeRef f;
        if (!f.facade) return checks;
        GraphDescriptionBuilder g;
        g.addNode(1, NodeKind::master, 0, 0, 0, "");
        g.addNode(20, NodeKind::auPlugin, 0, 0, 0, config(kDelay, tweaked));
        g.addEdge(2, 20, 1, EdgeKind::audio, 0);
        g.setTempo(0, 120.0);
        g.setTimeSignature(0, 4, 4);
        g.setMaster(1);
        DAW_CHECK(published(*f.facade, f->applyGraph(g.description())));
        DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 1) - 0.5) < 1e-6);
        // ...and setPluginState puts the defaults back (delay time 1 s).
        f->setPluginState(20, defaults);
        DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 1) - 1.0) < 1e-6);
        DAW_CHECK(f->getPluginState(20) != tweaked);
    }
    return checks;
}

// MARK: Failure and adoption

CheckResult auFailureAndAdoption() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(registerFakeAudioUnit());
    auto host = std::make_shared<AUPluginHost>();
    auto rig = makeRig(host);
    rig->addAsset(makeAsset(7, 1, 96000, [](uint32_t, int64_t) { return 0.25f; }));

    auto graph = [&](const std::string& fx, uint32_t version, ParamID first = 0, uint32_t count = 0,
                     const std::string& instrument = "") {
        GraphDescription d = baseDescription();
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{20, NodeKind::auPlugin, version, first, count, fx});
        d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
        if (!instrument.empty()) {
            d.nodes.push_back(NodeDesc{2, NodeKind::midiClipPlayer, 1, 0, 0, {}});
            d.nodes.push_back(NodeDesc{30, NodeKind::auPlugin, 1, 0, 0, instrument});
            d.edges.push_back(EdgeDesc{3, 2, 30, EdgeKind::midi, 0});
            d.edges.push_back(EdgeDesc{4, 30, 1, EdgeKind::audio, 0});
            d.notes.push_back(NoteDesc{2, 0, 960, 60, 100, 0});
        }
        d.audioClips.push_back(nodes::clip(10, 1, 0, 3840, 7));
        return d;
    };

    // Missing AUs: the effect passes its input, the instrument is silent, each reported once.
    DAW_CHECK(rig->publish(graph(config("aufx:none:Embr"), 1, 0, 0, config("aumu:none:Embr"))));
    DAW_CHECK(rig->transport().locate(0) && rig->transport().play());
    renderRandom(*rig, 4800, 66);
    DAW_CHECK(rig->violations() == 0);
    DAW_CHECK(rig->left().size() == 4800 && std::all_of(rig->left().begin(), rig->left().end(),
                                                      [](float x) { return std::fabs(x - 0.25f) < 1e-6f; }));
    auto failures = host->takeFailures();
    DAW_CHECK(failures.size() == 2);
    DAW_CHECK(std::all_of(failures.begin(), failures.end(),
                          [](const AUPluginHost::Failure& f) { return f.error.code == ErrorCode::notFound; }));
    DAW_CHECK(host->infoJSON(20).find("\"loaded\":false") != std::string::npos);
    DAW_CHECK(host->infoJSON(20).find("\"error\":") != std::string::npos);
    // Its configured state survives for saving.
    const std::vector<uint8_t> kept{9, 8, 7};
    DAW_CHECK(rig->publish(graph(config("aufx:none:Embr", kept), 2)));
    DAW_CHECK(host->state(20).ok() && host->state(20).value() == kept);
    (void)host->takeFailures();

    // A real AU, kept across a configVersion bump and a param-range change.
    DAW_CHECK(rig->publish(graph(config(kDelay), 3)));
    auto first = host->instance(20);
    DAW_CHECK(first != nullptr);
    const ParamID p = allocate(*rig, 2);
    DAW_CHECK(rig->publish(graph(config(kDelay), 4, p, 2)));
    DAW_CHECK(host->instance(20) == first);
    // A configJSON state that differs from the one it was made with is applied (an undo of a
    // state change); the same one again isn't.
    auto state = first->fullState();
    DAW_CHECK(state.ok());
    if (state) {
        DAW_CHECK(rig->publish(graph(config(kDelay, state.value()), 5, p, 2)));
        DAW_CHECK(host->instance(20) == first);
    }
    // A new identifier is a new AU.
    DAW_CHECK(rig->publish(graph(config(kFake), 6)));
    DAW_CHECK(host->instance(20) != first && host->instance(20) != nullptr);
    renderRandom(*rig, 4800, 67);
    DAW_CHECK(rig->violations() == 0);

    // instantiatePlugin parks an AU; the build adopts it instead of making a second one.
    rig->clearOutput();
    DAW_CHECK(rig->publish(baseDescription()));  // slot 20's fake leaves the graph
    DAW_CHECK(rig->reclaimPasses(2));
    const int fakesBefore = liveFakeAudioUnits();
    DAW_CHECK(host->instantiate(40, kFake).ok());
    DAW_CHECK(liveFakeAudioUnits() == fakesBefore + 1);
    DAW_CHECK(!host->instantiate(41, "aufx:none:Embr").ok());
    DAW_CHECK(host->infoJSON(40).find("\"loaded\":true") != std::string::npos);
    // A state set before slot 41 had an AU is applied to its first one (here: a state the AU
    // refuses, which shows up as a failure when the node is made).
    DAW_CHECK(host->setState(41, std::vector<uint8_t>{1, 2, 3}).ok());
    DAW_CHECK(host->state(41).ok() && host->state(41).value() == std::vector<uint8_t>({1, 2, 3}));
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{40, NodeKind::auPlugin, 1, 0, 0, config(kFake)});
    d.nodes.push_back(NodeDesc{41, NodeKind::auPlugin, 1, 0, 0, config(kDelay)});
    d.edges.push_back(EdgeDesc{1, 40, 41, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{2, 41, 1, EdgeKind::audio, 0});
    DAW_CHECK(rig->publish(d));
    DAW_CHECK(liveFakeAudioUnits() == fakesBefore + 1);
    DAW_CHECK(host->instance(40) != nullptr && host->instance(41) != nullptr);
    failures = host->takeFailures();
    DAW_CHECK(failures.size() == 1 && failures[0].slot == 41 && failures[0].error.code == ErrorCode::invalidArgument);
    auto later = host->state(41);
    DAW_CHECK(later.ok() && later.value() != std::vector<uint8_t>({1, 2, 3}));  // the pending state is used up
    renderRandom(*rig, 4800, 68);
    DAW_CHECK(rig->violations() == 0);
    return checks;
}

// MARK: DW-214 probes

namespace {

// One AU outside any graph: prepared, fed silence, rendered in 512-frame blocks.
struct BareAU {
    explicit BareAU(const char* identifier) {
        auto id = parseAUIdentifier(identifier);
        if (!id) return;
        auto made = AUInstance::instantiate(*id);
        if (!made) return;
        instance = std::move(made).value();
        if (!instance->prepare(kRate, 512)) instance.reset();
    }
    void render(uint32_t frames = 512) {
        float* in[2] = {silence.data(), silence.data() + 512};
        float* out[2] = {output.data(), output.data() + 512};
        NodeIO io;
        io.audioIn = AudioBufferView{in, 2, frames};
        io.audioOut = AudioBufferView{out, 2, frames};
        (void)instance->render(io, frames);
    }
    std::shared_ptr<AUInstance> instance;
    std::vector<float> silence = std::vector<float>(1024, 0.0f);
    std::vector<float> output = std::vector<float>(1024, 0.0f);
};

} // namespace

double auParamTreeLagMicros(uint32_t trials) {
    BareAU au(kDelay);
    if (!au.instance) return -1;
    double worst = 0;
    uint32_t stale = 0;
    for (uint32_t t = 0; t < trials; ++t) {
        const float value = 0.1f + 0.01f * static_cast<float>(t % 50);  // delay time, s
        au.instance->scheduleParam(1, value, 0);
        au.render();
        if (std::fabs(au.instance->params(true)[1].value - value) >= 1e-6f) ++stale;  // read at once
        const auto start = std::chrono::steady_clock::now();
        bool arrived = false;
        while (std::chrono::steady_clock::now() - start < 2s) {
            const auto values = au.instance->params(true);
            if (std::fabs(values[1].value - value) < 1e-6f) {
                arrived = true;
                break;
            }
            std::this_thread::sleep_for(50us);
        }
        if (!arrived) return -1;
        worst = std::max(worst, std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count());
    }
    std::printf("DW-214 tree reads stale right after render: %u of %u\n", stale, trials);
    return worst;
}

uint32_t auTeardownStress(uint32_t iterations, uint32_t blocksPerInstance) {
    uint32_t done = 0;
    std::mt19937 rng(214);
    for (uint32_t i = 0; i < iterations; ++i) {
        BareAU au(i % 2 == 0 ? kDelay : kSampler);
        if (!au.instance) continue;
        const auto& params = au.instance->params();
        for (uint32_t b = 0; b < blocksPerInstance; ++b) {
            if (!params.empty()) {
                const uint32_t index = static_cast<uint32_t>(rng() % params.size());
                const AUParamInfo& p = params[index];
                const float x = std::uniform_real_distribution<float>(0.0f, 1.0f)(rng);
                au.instance->scheduleParam(index, p.min + (p.max - p.min) * x, 0);
            }
            au.render();
        }
        au.instance.reset();  // destroyed right after the last render, with tree messages pending
        ++done;
        if (done % 100 == 0) {
            std::printf("DW-214 teardown progress: %u\n", done);
            std::fflush(stdout);
        }
    }
    return done;
}

CheckResult auTeardownRegression(uint32_t iterations) {
    CheckResult checks;
    DAW_CHECK(auTeardownStress(iterations, 8) == iterations);
    DAW_CHECK(eventually([] { return AUInstance::pendingV2Releases() == 0; }, 6000ms));
    return checks;
}

CheckResult auConcurrentLifecycle(uint32_t iterations) {
    CheckResult checks;
    std::atomic<uint32_t> made{0}, renderErrors{0};
    auto churn = [&](uint32_t seed) {
        std::mt19937 rng(seed);
        for (uint32_t i = 0; i < iterations; ++i) {
            BareAU au((rng() & 1) ? kDelay : kSampler);
            if (!au.instance) continue;
            ++made;
            const auto& params = au.instance->params();
            for (uint32_t b = 0; b < 4; ++b) {
                if (!params.empty()) {
                    const uint32_t index = static_cast<uint32_t>(rng() % params.size());
                    au.instance->scheduleParam(index, params[index].min, 0);
                }
                au.render();
            }
            renderErrors += static_cast<uint32_t>(au.instance->renderErrors());
        }
    };
    std::thread a(churn, 1), b(churn, 2);
    a.join();
    b.join();
    DAW_CHECK(made == 2 * iterations);
    DAW_CHECK(renderErrors == 0);
    DAW_CHECK(eventually([] { return AUInstance::pendingV2Releases() == 0; }, 6000ms));
    return checks;
}

// MARK: T-064 (PLUG-022, PLUG-018)

CheckResult auNanGuardAndBypass() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    DAW_CHECK(registerFakeAudioUnit());
    auto host = std::make_shared<AUPluginHost>();
    auto rig = makeRig(host);
    host->setTelemetry(&rig->engine().telemetry());
    const auto signal = [](uint32_t c, int64_t i) {
        return 0.5f * static_cast<float>(std::sin(0.011 * static_cast<double>(i) + c));
    };
    rig->addAsset(makeAsset(7, 2, 96000, signal));
    const ParamID p = allocate(*rig, 2);  // gain (0…2, default 1), sidechain mix: the fake's own
    auto bypassSlot = rig->engine().params().allocate(1, 0.0f);
    DAW_CHECK(bypassSlot.ok());
    if (!bypassSlot) return checks;
    const ParamID bypass = bypassSlot.value();
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{20, NodeKind::auPlugin, 1, p, 2, config(kFake), bypass});
    d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
    d.audioClips.push_back(nodes::clip(10, 1, 0, 3840, 7));
    DAW_CHECK(rig->publish(d));
    DAW_CHECK(rig->transport().locate(0) && rig->transport().play());

    // PLUG-022: NaN from the AU → silence, nanBlocks, one report for the slot.
    setFakeAudioUnitEmitsNaN(true);
    renderRandom(*rig, 12000, 101);
    setFakeAudioUnitEmitsNaN(false);
    bool silent = true;
    for (size_t i = 0; i < rig->left().size(); ++i) silent = silent && rig->left()[i] == 0.0f && rig->right()[i] == 0.0f;
    DAW_CHECK(silent);
    auto inner = std::static_pointer_cast<AUPluginNode>(rig->engine().nodes().get(20));
    DAW_CHECK(inner && inner->nanBlocks() > 0 && rig->engine().telemetry().snapshot().nanBlocks == inner->nanBlocks());
    DAW_CHECK(host->takeMisbehaved() == std::vector<NodeID>{20});
    DAW_CHECK(host->takeMisbehaved().empty());

    // Recovered (gain 1, latency 0): the input on the timeline.
    rig->clearOutput();
    renderRandom(*rig, 12000, 102);
    bool same = true;
    for (size_t i = 1500; i < 12000; ++i) same = same && std::fabs(rig->left()[i] - signal(0, static_cast<int64_t>(12000 + i))) < 1e-6f;
    DAW_CHECK(same);

    // PLUG-018: gain 0 makes the AU silent; bypassed (a slot write) the input passes, untouched,
    // and the AU instance stays the same.
    const auto instance = host->instance(20);
    rig->engine().params().set(p + 0, 0.0f);
    rig->clearOutput();
    renderRandom(*rig, 12000, 103);
    DAW_CHECK(std::fabs(rig->left().back()) == 0.0f && std::fabs(rig->left()[6000]) == 0.0f);
    rig->engine().params().set(bypass, 1.0f);
    rig->clearOutput();
    renderRandom(*rig, 12000, 104);
    bool passes = true;
    for (size_t i = 1500; i < 12000; ++i) passes = passes && rig->left()[i] == signal(0, static_cast<int64_t>(36000 + i));
    DAW_CHECK(passes);
    DAW_CHECK(host->instance(20) == instance);
    DAW_CHECK(host->takeMisbehaved().empty());
    DAW_CHECK(rig->violations() == 0);
    return checks;
}

} // namespace daw::testing

