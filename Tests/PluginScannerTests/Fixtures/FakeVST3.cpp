// Test-only VST3 module for PluginScannerTests (PLUG-001, PLUG-003). Built at test time with
// only pluginterfaces, so it doesn't depend on any installed plugin.
//
// Behaviour depends on the bundle it is loaded from, so one binary serves every case:
//   name contains "Crash" → bundleEntry segfaults (PLUG-001 crash → blocked)
//   name contains "Hang"  → bundleEntry never returns (PLUG-001 timeout → blocked)
//   otherwise             → prints to stdout (the scanner must keep it out of its JSON), then
//                           exposes the classes below.
//
// Classes: "Fake Sidechain Comp" (effect, aux input bus, separate controller with 3 params),
// "Fake Synth" (instrument, no audio inputs, controller with 1 param), and the two controller
// classes, which the scanner must not list.

#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"

#include <CoreFoundation/CoreFoundation.h>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <unistd.h>

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

DECLARE_UID(kCompUID, 0x5A1D3C01, 0x00000000, 0x00000000, 0x00000001)
DECLARE_UID(kCompControllerUID, 0x5A1D3C01, 0x00000000, 0x00000000, 0x00000002)
DECLARE_UID(kSynthUID, 0x5A1D3C01, 0x00000000, 0x00000000, 0x00000003)
DECLARE_UID(kSynthControllerUID, 0x5A1D3C01, 0x00000000, 0x00000000, 0x00000004)

void copyString16(String128 dst, const char* src) {
    int i = 0;
    for (; src[i] && i < 127; ++i) dst[i] = static_cast<char16>(src[i]);
    dst[i] = 0;
}

class FakeController : public IEditController {
public:
    explicit FakeController(int32 numParams) : numParams_(numParams) { FUNKNOWN_CTOR }
    virtual ~FakeController() = default;

    tresult PLUGIN_API initialize(FUnknown*) override { return kResultOk; }
    tresult PLUGIN_API terminate() override { return kResultOk; }
    tresult PLUGIN_API setComponentState(IBStream*) override { return kResultOk; }
    tresult PLUGIN_API setState(IBStream*) override { return kResultOk; }
    tresult PLUGIN_API getState(IBStream*) override { return kResultOk; }
    int32 PLUGIN_API getParameterCount() override { return numParams_; }
    tresult PLUGIN_API getParameterInfo(int32, ParameterInfo&) override { return kResultFalse; }
    tresult PLUGIN_API getParamStringByValue(ParamID, ParamValue, String128) override { return kResultFalse; }
    tresult PLUGIN_API getParamValueByString(ParamID, TChar*, ParamValue&) override { return kResultFalse; }
    ParamValue PLUGIN_API normalizedParamToPlain(ParamID, ParamValue v) override { return v; }
    ParamValue PLUGIN_API plainParamToNormalized(ParamID, ParamValue v) override { return v; }
    ParamValue PLUGIN_API getParamNormalized(ParamID) override { return 0; }
    tresult PLUGIN_API setParamNormalized(ParamID, ParamValue) override { return kResultOk; }
    tresult PLUGIN_API setComponentHandler(IComponentHandler*) override { return kResultOk; }
    IPlugView* PLUGIN_API createView(FIDString) override { return nullptr; }

    DECLARE_FUNKNOWN_METHODS

private:
    int32 numParams_;
};
IMPLEMENT_REFCOUNT(FakeController)
tresult PLUGIN_API FakeController::queryInterface(const TUID iid, void** obj) {
    QUERY_INTERFACE(iid, obj, FUnknown::iid, IEditController)
    QUERY_INTERFACE(iid, obj, IPluginBase::iid, IPluginBase)
    QUERY_INTERFACE(iid, obj, IEditController::iid, IEditController)
    *obj = nullptr;
    return kNoInterface;
}

class FakeComponent : public IComponent {
public:
    explicit FakeComponent(bool instrument) : instrument_(instrument) { FUNKNOWN_CTOR }
    virtual ~FakeComponent() = default;

    tresult PLUGIN_API initialize(FUnknown*) override { return kResultOk; }
    tresult PLUGIN_API terminate() override { return kResultOk; }
    tresult PLUGIN_API getControllerClassId(TUID classId) override {
        std::memcpy(classId, instrument_ ? kSynthControllerUID : kCompControllerUID, sizeof(TUID));
        return kResultOk;
    }
    tresult PLUGIN_API setIoMode(IoMode) override { return kResultOk; }
    int32 PLUGIN_API getBusCount(MediaType type, BusDirection dir) override {
        if (type == kEvent) return instrument_ && dir == kInput ? 1 : 0;
        if (dir == kOutput) return 1;
        return instrument_ ? 0 : 2;  // effect: main + sidechain
    }
    tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo& bus) override {
        if (index < 0 || index >= getBusCount(type, dir)) return kInvalidArgument;
        bus = BusInfo{};
        bus.mediaType = type;
        bus.direction = dir;
        bus.channelCount = type == kAudio ? 2 : 16;
        bus.busType = index == 0 ? kMain : kAux;
        copyString16(bus.name, index == 0 ? "Main" : "Sidechain");
        return kResultOk;
    }
    tresult PLUGIN_API getRoutingInfo(RoutingInfo&, RoutingInfo&) override { return kNotImplemented; }
    tresult PLUGIN_API activateBus(MediaType, BusDirection, int32, TBool) override { return kResultOk; }
    tresult PLUGIN_API setActive(TBool) override { return kResultOk; }
    tresult PLUGIN_API setState(IBStream*) override { return kResultOk; }
    tresult PLUGIN_API getState(IBStream*) override { return kResultOk; }

    DECLARE_FUNKNOWN_METHODS

private:
    bool instrument_;
};
IMPLEMENT_REFCOUNT(FakeComponent)
tresult PLUGIN_API FakeComponent::queryInterface(const TUID iid, void** obj) {
    QUERY_INTERFACE(iid, obj, FUnknown::iid, IComponent)
    QUERY_INTERFACE(iid, obj, IPluginBase::iid, IPluginBase)
    QUERY_INTERFACE(iid, obj, IComponent::iid, IComponent)
    *obj = nullptr;
    return kNoInterface;
}

struct ClassEntry {
    const TUID* cid;
    const char* category;
    const char* name;
    const char* subCategories;
};
const ClassEntry kClasses[] = {
    {&kCompUID, kVstAudioEffectClass, "Fake Sidechain Comp", "Fx|Dynamics"},
    {&kCompControllerUID, kVstComponentControllerClass, "Fake Sidechain Comp Controller", ""},
    {&kSynthUID, kVstAudioEffectClass, "Fake Synth", "Instrument|Synth"},
    {&kSynthControllerUID, kVstComponentControllerClass, "Fake Synth Controller", ""},
};

class FakeFactory : public IPluginFactory2 {
public:
    FakeFactory() { FUNKNOWN_CTOR }
    virtual ~FakeFactory() = default;

    tresult PLUGIN_API getFactoryInfo(PFactoryInfo* info) override {
        *info = PFactoryInfo("macDAW Tests", "", "", PFactoryInfo::kUnicode);
        return kResultOk;
    }
    int32 PLUGIN_API countClasses() override { return 4; }
    tresult PLUGIN_API getClassInfo(int32 index, PClassInfo* info) override {
        if (index < 0 || index >= countClasses()) return kInvalidArgument;
        const auto& c = kClasses[index];
        *info = PClassInfo(*c.cid, PClassInfo::kManyInstances, c.category, c.name);
        return kResultOk;
    }
    tresult PLUGIN_API getClassInfo2(int32 index, PClassInfo2* info) override {
        if (index < 0 || index >= countClasses()) return kInvalidArgument;
        const auto& c = kClasses[index];
        *info = PClassInfo2(*c.cid, PClassInfo::kManyInstances, c.category, c.name, 0,
                            c.subCategories, "", "1.2.3", kVstVersionString);
        return kResultOk;
    }
    tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void** obj) override {
        FUnknown* instance = nullptr;
        if (FUnknownPrivate::iidEqual(cid, kCompUID)) instance = static_cast<IComponent*>(new FakeComponent(false));
        else if (FUnknownPrivate::iidEqual(cid, kSynthUID)) instance = static_cast<IComponent*>(new FakeComponent(true));
        else if (FUnknownPrivate::iidEqual(cid, kCompControllerUID)) instance = static_cast<IEditController*>(new FakeController(3));
        else if (FUnknownPrivate::iidEqual(cid, kSynthControllerUID)) instance = static_cast<IEditController*>(new FakeController(1));
        if (!instance) {
            *obj = nullptr;
            return kInvalidArgument;
        }
        tresult result = instance->queryInterface(iid, obj);
        instance->release();
        return result;
    }

    DECLARE_FUNKNOWN_METHODS
};
IMPLEMENT_REFCOUNT(FakeFactory)
tresult PLUGIN_API FakeFactory::queryInterface(const TUID iid, void** obj) {
    QUERY_INTERFACE(iid, obj, FUnknown::iid, IPluginFactory)
    QUERY_INTERFACE(iid, obj, IPluginFactory::iid, IPluginFactory)
    QUERY_INTERFACE(iid, obj, IPluginFactory2::iid, IPluginFactory2)
    *obj = nullptr;
    return kNoInterface;
}

}  // namespace

extern "C" {

SMTG_EXPORT_SYMBOL bool bundleEntry(CFBundleRef bundle) {
    char path[4096] = {};
    if (CFURLRef url = CFBundleCopyBundleURL(bundle)) {
        CFURLGetFileSystemRepresentation(url, true, reinterpret_cast<UInt8*>(path), sizeof(path));
        CFRelease(url);
    }
    if (std::strstr(path, "Crash")) std::raise(SIGSEGV);
    if (std::strstr(path, "Hang"))
        for (;;) sleep(1);
    std::printf("fake plugin chatter on stdout\n");
    std::fflush(stdout);
    return true;
}

SMTG_EXPORT_SYMBOL bool bundleExit() { return true; }

SMTG_EXPORT_SYMBOL IPluginFactory* PLUGIN_API GetPluginFactory() {
    static FakeFactory* factory = new FakeFactory();
    factory->addRef();
    return factory;
}

}  // extern "C"
