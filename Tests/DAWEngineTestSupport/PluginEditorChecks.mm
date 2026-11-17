#include "PluginEditorChecks.h"

#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#include <dlfcn.h>

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <memory>
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
#include "plugins/AUInstance.h"
#include "plugins/AUPluginConfig.h"
#include "plugins/AUPluginHost.h"
#include "plugins/AUPluginNode.h"
#include "plugins/PluginEditQueue.h"
#include "plugins/VST3PluginConfig.h"

using namespace std::chrono_literals;

namespace daw::testing {

namespace {

using nodes::baseDescription;
using nodes::kRate;
using nodes::Rig;

constexpr float kNaN = std::numeric_limits<float>::quiet_NaN();
constexpr const char* kEffectUID = "E4B3E71A000000000000000000000001";
constexpr const char* kDelay = "aufx:dely:appl";

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

std::string emberEffect() { return (repoRoot() / ".build/test-plugins/EmberTest.vst3").string() + "#" + kEffectUID; }

// EmberTest's T-063 knobs (EmberTestPlugin.cpp, EmberTestView.mm).
struct EmberEditorAPI {
    int32_t (*edit)(uint32_t, double, int32_t) = nullptr;
    double (*controllerParam)(uint32_t) = nullptr;
    void (*viewInfo)(int32_t*, int32_t*, int32_t*, int32_t*) = nullptr;
    int32_t (*requestResize)(int32_t, int32_t) = nullptr;
    bool ready() const { return edit && controllerParam && viewInfo && requestResize; }
};

const EmberEditorAPI& ember() {
    static const EmberEditorAPI api = [] {
        EmberEditorAPI a;
        if (!ensureTestPlugins()) return a;
        const auto path = repoRoot() / ".build/test-plugins/EmberTest.vst3/Contents/MacOS/EmberTest";
        void* image = dlopen(path.c_str(), RTLD_NOW);  // the image the module loads (one per path)
        if (!image) return a;
        a.edit = reinterpret_cast<decltype(a.edit)>(dlsym(image, "ember_test_edit"));
        a.controllerParam = reinterpret_cast<decltype(a.controllerParam)>(dlsym(image, "ember_test_controller_param"));
        a.viewInfo = reinterpret_cast<decltype(a.viewInfo)>(dlsym(image, "ember_test_view_info"));
        a.requestResize = reinterpret_cast<decltype(a.requestResize)>(dlsym(image, "ember_test_view_request_resize"));
        return a;
    }();
    return api;
}

struct ViewInfo {
    int32_t live = 0, attached = 0, width = 0, height = 0;
};
ViewInfo viewInfo() {
    ViewInfo v;
    ember().viewInfo(&v.live, &v.attached, &v.width, &v.height);
    return v;
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

struct FacadeRef {
    EngineFacade* facade;
    explicit FacadeRef(double rate = kRate) {
        DriverConfigPOD config;
        config.sampleRate = rate;
        facade = EngineFacade::create(EngineMode::offline, config);
    }
    ~FacadeRef() { reset(); }
    void reset() {
        if (facade) releaseFacade(facade);
        facade = nullptr;
    }
    EngineFacade* operator->() const { return facade; }
};

bool published(EngineFacade& f, uint64_t version) {
    const GraphStatusPOD s = f.waitForGraph(version, 10000);
    return s.publishedVersion >= version && s.lastError.ok();
}

// Renders [0, ticks) offline (which pushes changed param slots). False on a failure or an RT
// violation.
bool renderOnce(EngineFacade& f, const std::filesystem::path& path, Tick ticks = 96) {
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

double infoParamValue(const std::string& json, int index) {
    const std::string key = "{\"index\":" + std::to_string(index) + ",";
    const auto at = json.find(key);
    if (at == std::string::npos) return std::nan("");
    const auto value = json.find("\"value\":", at);
    if (value == std::string::npos) return std::nan("");
    return std::strtod(json.c_str() + value + 8, nullptr);
}

// A number field of a flat JSON object ("width":400).
double jsonNumber(const std::string& json, const std::string& key) {
    const auto at = json.find("\"" + key + "\":");
    if (at == std::string::npos) return std::nan("");
    return std::strtod(json.c_str() + at + key.size() + 3, nullptr);
}
bool jsonHas(const std::string& json, const std::string& fragment) { return json.find(fragment) != std::string::npos; }

std::vector<EngineEventPOD> editEvents(EngineFacade& f) {
    std::vector<EngineEventPOD> events(256), edits;
    events.resize(f.pollEvents(events.data(), events.size()));
    for (auto& e : events)
        if (e.type == EngineEventType::pluginParamEdited) edits.push_back(e);
    return edits;
}

// An offline facade with EmberTest's effect at slot 20 (3 params from `p`) on the master.
bool emberGraph(EngineFacade& f, ParamID p) {
    GraphDescriptionBuilder g;
    g.addNode(1, NodeKind::master, 0, 0, 0, "");
    g.addNode(20, NodeKind::vst3Plugin, 0, p, 3, VST3PluginConfig::makeJSON(emberEffect(), {}));
    g.addEdge(1, 20, 1, EdgeKind::audio, 0);
    g.setTempo(0, 120.0);
    g.setTimeSignature(0, 4, 4);
    g.setMaster(1);
    return published(f, f.applyGraph(g.description()));
}

bool auGraph(EngineFacade& f) {
    GraphDescriptionBuilder g;
    g.addNode(1, NodeKind::master, 0, 0, 0, "");
    g.addNode(20, NodeKind::auPlugin, 0, 0, 0, AUPluginConfig::makeJSON(kDelay, {}));
    g.addEdge(1, 20, 1, EdgeKind::audio, 0);
    g.setTempo(0, 120.0);
    g.setTimeSignature(0, 4, 4);
    g.setMaster(1);
    return published(f, f.applyGraph(g.description()));
}

} // namespace

// MARK: DW-204, VST3

CheckResult vst3PluginEditsBecomeEvents() {
    CheckResult checks;
    DAW_CHECK(ember().ready());
    if (!ember().ready()) return checks;
    TempDir dir;
    FacadeRef f;
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    const ParamID p = f->allocateParams(3);
    for (uint32_t i = 0; i < 3; ++i) f->setParam(p + i, kNaN);
    DAW_CHECK(emberGraph(*f.facade, p));
    (void)editEvents(*f.facade);

    // A gesture on Gain (ParamID 0, index 0): begin, three steps, end → begin, the newest value, end.
    DAW_CHECK(ember().edit(0, 0, 0) == 0);
    for (double v : {0.3, 0.4, 0.5}) DAW_CHECK(ember().edit(0, v, 1) == 0);
    DAW_CHECK(ember().edit(0, 0, 2) == 0);
    auto edits = editEvents(*f.facade);
    DAW_CHECK(edits.size() == 3);
    if (edits.size() == 3) {
        DAW_CHECK(edits[0].subject == 20 && edits[0].pluginEdit.phase == PluginEditPhase::begin && edits[0].pluginEdit.index == 0);
        DAW_CHECK(edits[1].pluginEdit.phase == PluginEditPhase::value && std::fabs(edits[1].pluginEdit.value - 0.5f) < 1e-6f);
        DAW_CHECK(edits[2].pluginEdit.phase == PluginEditPhase::end && edits[2].pluginEdit.index == 0);
    }
    // An ungestured edit (Sidechain Mix, index 1) is a value alone; an unknown parameter and an end
    // without a begin are refused and make no event.
    DAW_CHECK(ember().edit(1, 0.7, 1) == 0);
    DAW_CHECK(ember().edit(99, 0.1, 1) != 0);
    DAW_CHECK(ember().edit(0, 0, 2) != 0);
    edits = editEvents(*f.facade);
    DAW_CHECK(edits.size() == 1);
    if (edits.size() == 1)
        DAW_CHECK(edits[0].pluginEdit.index == 1 && edits[0].pluginEdit.phase == PluginEditPhase::value &&
                  std::fabs(edits[0].pluginEdit.value - 0.7f) < 1e-6f);

    // The editor is ahead of the model: an older model value pushed now doesn't overwrite the
    // controller (the knob would jump back)…
    f->setParam(p + 0, 0.9f);
    DAW_CHECK(renderOnce(*f.facade, dir.path() / "a.wav"));
    DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 0) - 0.5) < 1e-6);
    // …until the model has the editor's value (its echo) …
    f->setParam(p + 0, 0.5f);
    DAW_CHECK(renderOnce(*f.facade, dir.path() / "b.wav"));
    DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 0) - 0.5) < 1e-6);
    // …after which the model leads again (undo, automation): the editor shows it (syncEditor).
    f->setParam(p + 0, 0.8f);
    DAW_CHECK(renderOnce(*f.facade, dir.path() / "c.wav"));
    DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 0) - 0.8) < 1e-6);
    DAW_CHECK(std::fabs(ember().controllerParam(0) - 0.8) < 1e-6);

    // During an open gesture the model never overwrites the controller; after the echo wait (1 s)
    // without the model catching up, the model wins.
    DAW_CHECK(ember().edit(0, 0, 0) == 0);
    DAW_CHECK(ember().edit(0, 0.2, 1) == 0);
    f->setParam(p + 0, 0.6f);
    DAW_CHECK(renderOnce(*f.facade, dir.path() / "d.wav"));
    DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 0) - 0.2) < 1e-6);
    DAW_CHECK(ember().edit(0, 0, 2) == 0);
    std::this_thread::sleep_for(1100ms);
    DAW_CHECK(std::fabs(infoParamValue(f->pluginInfoJSON(20), 0) - 0.6) < 1e-6);
    edits = editEvents(*f.facade);
    DAW_CHECK(edits.size() == 3);
    return checks;
}

// MARK: PLUG-017, VST3

CheckResult vst3EditorView() {
    CheckResult checks;
    DAW_CHECK(pthread_main_np() != 0);
    DAW_CHECK(ember().ready());
    if (!ember().ready()) return checks;
    @autoreleasepool {
        FacadeRef f;
        DAW_CHECK(f.facade != nullptr);
        if (!f.facade) return checks;
        DAW_CHECK(f->createPluginView(20) == nullptr);  // no plugin yet
        const ParamID p = f->allocateParams(3);
        for (uint32_t i = 0; i < 3; ++i) f->setParam(p + i, kNaN);
        DAW_CHECK(emberGraph(*f.facade, p));
        DAW_CHECK(f->pluginViewJSON(20) == "{\"slot\":20,\"open\":false}");

        // Off the main thread: refused.
        void* offMain = reinterpret_cast<void*>(1);
        std::thread([&] { offMain = f->createPluginView(20); }).join();
        DAW_CHECK(offMain == nullptr);

        void* raw = f->createPluginView(20);
        DAW_CHECK(raw != nullptr);
        if (!raw) return checks;
        NSView* container = (__bridge NSView*)raw;
        DAW_CHECK(f->createPluginView(20) == raw);  // the same editor
        DAW_CHECK(f->openPluginViews() == std::vector<NodeID>{20});
        std::string json = f->pluginViewJSON(20);
        DAW_CHECK(jsonHas(json, "\"open\":true") && jsonHas(json, "\"ready\":true") && jsonHas(json, "\"kind\":\"vst3\"") &&
                  jsonHas(json, "\"title\":\"Ember Test Effect\"") && jsonHas(json, "\"resizable\":true") &&
                  jsonHas(json, "\"stale\":false"));
        DAW_CHECK(jsonNumber(json, "width") == 400 && jsonNumber(json, "height") == 300);
        DAW_CHECK(container.frame.size.width == 400 && container.frame.size.height == 300);
        ViewInfo v = viewInfo();
        DAW_CHECK(v.live == 1 && v.attached == 1 && v.width == 400 && v.height == 300);
        DAW_CHECK(container.subviews.count == 1);  // the plugin's own NSView

        // The plugin asks for a new size (IPlugFrame::resizeView): the container takes it.
        DAW_CHECK(ember().requestResize(520, 360) == 0 /* kResultTrue */);
        DAW_CHECK(container.frame.size.width == 520 && container.frame.size.height == 360);
        json = f->pluginViewJSON(20);
        DAW_CHECK(jsonNumber(json, "width") == 520 && jsonNumber(json, "height") == 360);
        v = viewInfo();
        DAW_CHECK(v.width == 520 && v.height == 360);

        // The window resizes the container: the view is constrained (≥ 200 × 150) and told.
        [container setFrameSize:NSMakeSize(150, 100)];
        v = viewInfo();
        DAW_CHECK(v.width == 200 && v.height == 150);
        [container setFrameSize:NSMakeSize(640, 480)];
        v = viewInfo();
        DAW_CHECK(v.width == 640 && v.height == 480);

        // A session-rate change replaces the instance: the open editor is stale; opening again
        // closes it and shows the new instance.
        DAW_CHECK(f->setSessionSampleRate(96000).ok());
        DAW_CHECK(eventually([&] { return jsonHas(f->pluginViewJSON(20), "\"stale\":true"); }));
        void* fresh = f->createPluginView(20);
        DAW_CHECK(fresh != nullptr);
        DAW_CHECK(jsonHas(f->pluginViewJSON(20), "\"stale\":false"));
        v = viewInfo();
        DAW_CHECK(v.live == 1 && v.attached == 1 && v.width == 400);

        f->destroyPluginView(20);
        DAW_CHECK(f->pluginViewJSON(20) == "{\"slot\":20,\"open\":false}" && f->openPluginViews().empty());
        DAW_CHECK(viewInfo().live == 0);

        // The facade's end closes what is still open.
        DAW_CHECK(f->createPluginView(20) != nullptr);
        DAW_CHECK(viewInfo().live == 1);
        f.reset();
    }
    DAW_CHECK(viewInfo().live == 0);
    return checks;
}

// MARK: PLUG-017, AU

namespace {
FacadeRef* gAUEditorFacade = nullptr;
}

bool auEditorBegin() {
    delete gAUEditorFacade;
    gAUEditorFacade = new FacadeRef();
    FacadeRef& f = *gAUEditorFacade;
    if (!f.facade || !auGraph(*f.facade)) return false;
    return f->createPluginView(20) != nullptr && jsonHas(f->pluginViewJSON(20), "\"open\":true");
}

std::string auEditorJSON() { return gAUEditorFacade && gAUEditorFacade->facade ? (*gAUEditorFacade)->pluginViewJSON(20) : ""; }

CheckResult auEditorFinish() {
    CheckResult checks;
    DAW_CHECK(gAUEditorFacade != nullptr && gAUEditorFacade->facade != nullptr);
    if (!gAUEditorFacade || !gAUEditorFacade->facade) return checks;
    @autoreleasepool {
        FacadeRef& f = *gAUEditorFacade;
        const std::string json = f->pluginViewJSON(20);
        DAW_CHECK(jsonHas(json, "\"ready\":true"));
        DAW_CHECK(jsonHas(json, "\"kind\":\"au\"") || jsonHas(json, "\"kind\":\"auGeneric\""));
        DAW_CHECK(jsonHas(json, "\"title\":\"AUDelay\""));
        DAW_CHECK(jsonNumber(json, "width") >= 50 && jsonNumber(json, "height") >= 20);
        NSView* container = (__bridge NSView*)f->createPluginView(20);
        DAW_CHECK(container != nil && container.subviews.count == 1);  // the controller's view
        DAW_CHECK(std::fabs(container.frame.size.width - jsonNumber(json, "width")) < 0.5);
        f->destroyPluginView(20);
        DAW_CHECK(!jsonHas(f->pluginViewJSON(20), "\"open\":true"));
        delete gAUEditorFacade;
        gAUEditorFacade = nullptr;
    }
    return checks;
}

// MARK: DW-204, AU

CheckResult auPluginEditsBecomeEvents() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    auto host = std::make_shared<AUPluginHost>();
    auto queue = std::make_shared<PluginEditQueue>();
    host->setEditQueue(queue);
    auto rig = std::make_unique<Rig>([host](NodeRegistry& r) { (void)r.set(NodeKind::auPlugin, host->kindInfo()); });
    auto allocated = rig->engine().params().allocate(4, kNaN);
    DAW_CHECK(allocated.ok());
    if (!allocated) return checks;
    const ParamID p = allocated.value();
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{20, NodeKind::auPlugin, 1, p, 4, AUPluginConfig::makeJSON(kDelay, {})});
    d.edges.push_back(EdgeDesc{1, 20, 1, EdgeKind::audio, 0});
    DAW_CHECK(rig->publish(d));
    auto instance = host->current(20);
    DAW_CHECK(instance != nullptr);
    if (!instance) return checks;
    rig->render(256);

    @autoreleasepool {
        AUAudioUnit* unit = (__bridge AUAudioUnit*)instance->audioUnit();
        AUParameter* mix = unit.parameterTree.allParameters.firstObject;  // index 0: dry/wet mix %
        DAW_CHECK(mix != nil);
        if (mix == nil) return checks;

        // DW-276 (T-094): robust under load. Every wait polls with a generous deadline (the V2
        // bridge reports on its own queue, late on a loaded machine). The hold after a release or an
        // ungestured edit lasts kHold from when the observer saw it, which is after `since` was
        // taken; so a check made less than kHoldSure after `since` must still see the hold, and a
        // later one (a starved test thread at load 20+) can't tell, so it only checks what holds
        // either way. The window is measured after the decision it vouches for.
        constexpr auto kWait = 15000ms;
        constexpr auto kHoldSure = 250ms;  // < AUInstance's 300 ms hold
        using Clock = std::chrono::steady_clock;
        auto withinHold = [=](Clock::time_point since) { return Clock::now() - since < kHoldSure; };

        // An editor's gesture: Touch, values, Release.
        std::vector<PluginParamEdit> edits;
        auto collect = [&](size_t atLeast) {
            return eventually([&] {
                for (const auto& e : queue->take()) edits.push_back(e);
                return edits.size() >= atLeast;
            }, kWait);
        };
        [mix setValue:30 originator:nil atHostTime:0 eventType:AUParameterAutomationEventTypeTouch];
        // The gesture is open: a model value isn't pushed (it would fight the knob).
        DAW_CHECK(eventually([&] { return instance->pushDecision(0, 10.0f) == AUInstance::PushDecision::defer; }, kWait));
        for (float v : {40.0f, 50.0f}) [mix setValue:v originator:nil atHostTime:0 eventType:AUParameterAutomationEventTypeValue];
        const auto released = Clock::now();
        [mix setValue:50 originator:nil atHostTime:0 eventType:AUParameterAutomationEventTypeRelease];
        DAW_CHECK(collect(3));
        DAW_CHECK(eventually([&] {
            for (const auto& e : queue->take()) edits.push_back(e);
            return !edits.empty() && edits.back().phase == PluginEditKind::end;
        }, kWait));
        if (edits.size() >= 3) {
            DAW_CHECK(edits.front().slot == 20 && edits.front().index == 0 && edits.front().phase == PluginEditKind::begin);
            DAW_CHECK(edits.back().phase == PluginEditKind::end);
            const auto& last = edits[edits.size() - 2];
            DAW_CHECK(last.phase == PluginEditKind::value && std::fabs(last.value - 50.0f) < 1e-4f);
        }

        // Released at 50: an older model value (20) waits, the model's echo (50) isn't pushed again
        // (the AU has it), then the model leads.
        rig->engine().params().set(p + 0, 20.0f);
        rig->render(256);
        const bool heldAfterRelease = withinHold(released);  // so the render's decision was inside it
        if (heldAfterRelease) DAW_CHECK(std::fabs(mix.value - 50.0f) < 1e-4f);  // 20 deferred, never scheduled
        rig->engine().params().set(p + 0, 50.0f);
        rig->render(256);
        auto pooled = std::static_pointer_cast<AUPluginNode>(rig->engine().nodes().get(20));
        const uint64_t pushedBefore = pooled ? pooled->paramEventsPushed() : 0;
        rig->engine().params().set(p + 0, 80.0f);
        rig->render(256);
        DAW_CHECK(pooled && pooled->paramEventsPushed() == pushedBefore + 1);
        DAW_CHECK(eventually([&] { return std::fabs(instance->params(true)[0].value - 80.0f) < 1e-3f; }, kWait));
        // The tree reports the push back (V2 bridge): that echo is no edit.
        std::this_thread::sleep_for(100ms);
        edits.clear();
        for (const auto& e : queue->take()) edits.push_back(e);
        DAW_CHECK(edits.empty());

        // A plain value change (a menu, a preset) is an ungestured edit; the model's older value is
        // held back until it matches or 300 ms pass.
        const auto edited = Clock::now();
        mix.value = 25;
        DAW_CHECK(collect(1));
        if (!edits.empty()) DAW_CHECK(edits.back().phase == PluginEditKind::value && std::fabs(edits.back().value - 25.0f) < 1e-4f);
        // pushDecision never returns skip here (80 isn't the held 25), so defer, or push once the hold
        // ran out; only a check inside the window can insist on defer.
        const AUInstance::PushDecision decision = instance->pushDecision(0, 80.0f);
        const bool heldAfterEdit = withinHold(edited);  // measured after the decision
        DAW_CHECK(decision != AUInstance::PushDecision::skip);
        if (heldAfterEdit) DAW_CHECK(decision == AUInstance::PushDecision::defer);
        // The hold lasts ~300 ms (its deadline is checked when the node asks).
        DAW_CHECK(eventually([&] { return instance->pushDecision(0, 80.0f) == AUInstance::PushDecision::push; }, kWait));
    }
    DAW_CHECK(rig->violations() == 0);
    return checks;
}

} // namespace daw::testing
