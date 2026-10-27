#include "VST3Probe.h"

#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/connectionproxy.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/module.h"

#include <algorithm>
#include <cstring>

namespace daw::scan {

namespace {

using namespace Steinberg;
using namespace Steinberg::Vst;

// Some plugins show the host name or branch on it, so the scanner identifies as the DAW.
class ScannerHostApplication : public HostApplication {
public:
    tresult PLUGIN_API getName(String128 name) override {
        static constexpr char16 hostName[] = u"Ember Studio";
        std::memcpy(name, hostName, sizeof(hostName));
        return kResultOk;
    }
};

bool hasAuxAudioInput(IComponent& component) {
    const int32 count = component.getBusCount(kAudio, kInput);
    for (int32 i = 0; i < count; ++i) {
        BusInfo info{};
        if (component.getBusInfo(kAudio, kInput, i, info) == kResultOk && info.busType == kAux)
            return true;
    }
    return false;
}

VST3ClassProbe probeClass(const VST3::Hosting::PluginFactory& factory,
                          const VST3::Hosting::ClassInfo& info, FUnknown* host) {
    VST3ClassProbe probe;
    probe.classUID = info.ID().toString(false);
    probe.name = info.name();
    probe.vendor = info.vendor();
    probe.version = info.version();
    probe.subCategories = info.subCategoriesString();
    const auto& subs = info.subCategories();
    probe.isInstrument = std::find(subs.begin(), subs.end(), PlugType::kInstrument) != subs.end();

    auto component = factory.createInstance<IComponent>(info.ID());
    if (!component) {
        probe.error = "could not create IComponent";
        return probe;
    }
    if (component->initialize(host) != kResultOk) {
        probe.error = "IComponent::initialize failed";
        return probe;
    }
    probe.hasSidechain = hasAuxAudioInput(*component);

    // The controller is either the component itself (single-component effect) or a separate
    // class named by getControllerClassId.
    IPtr<IEditController> controller = FUnknownPtr<IEditController>(component);
    bool separateController = false;
    if (!controller) {
        TUID controllerID{};
        if (component->getControllerClassId(controllerID) == kResultOk) {
            controller = factory.createInstance<IEditController>(VST3::UID::fromTUID(controllerID));
            if (controller && controller->initialize(host) == kResultOk)
                separateController = true;
            else
                controller = nullptr;
        }
    }
    // A separate controller may only build its parameter list once it is connected to the
    // component and has its state (JUCE plugins report 0 otherwise), so set up as a host would.
    IPtr<ConnectionProxy> componentLink, controllerLink;
    if (separateController) {
        FUnknownPtr<IConnectionPoint> componentPoint(component), controllerPoint(controller);
        if (componentPoint && controllerPoint) {
            componentLink = owned(new ConnectionProxy(componentPoint));
            controllerLink = owned(new ConnectionProxy(controllerPoint));
            componentLink->connect(controllerPoint);
            controllerLink->connect(componentPoint);
        }
        MemoryStream state;
        if (component->getState(&state) == kResultOk) {
            state.seek(0, IBStream::kIBSeekSet, nullptr);
            controller->setComponentState(&state);
        }
    }
    if (controller)
        probe.numParams = static_cast<uint32_t>(std::max<int32>(0, controller->getParameterCount()));

    if (componentLink) {
        componentLink->disconnect();
        controllerLink->disconnect();
    }
    if (separateController)
        controller->terminate();
    controller = nullptr;
    component->terminate();
    probe.ok = true;
    return probe;
}

}  // namespace

VST3ModuleProbe probeVST3Module(const std::string& bundlePath) {
    VST3ModuleProbe result;
    std::string error;
    auto module = VST3::Hosting::Module::create(bundlePath, error);
    if (!module) {
        result.error = error.empty() ? "could not load module" : error;
        return result;
    }
    result.loaded = true;

    IPtr<FUnknown> host = owned(new ScannerHostApplication());
    const auto& factory = module->getFactory();
    factory.setHostContext(host);
    result.factoryVendor = factory.info().vendor();
    for (const auto& info : factory.classInfos()) {
        if (info.category() == kVstAudioEffectClass)
            result.classes.push_back(probeClass(factory, info, host));
    }
    // Unloading (bundleExit) happens here, inside the scanner, so a plugin that crashes on
    // unload is caught too.
    module.reset();
    return result;
}

}  // namespace daw::scan
