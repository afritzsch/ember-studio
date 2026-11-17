#include "plugins/AUPluginHost.h"

#include <utility>

#include "plugins/AUPluginConfig.h"
#include "plugins/AUPluginNode.h"
#include "plugins/PluginJSON.h"

namespace daw {

namespace {

constexpr std::size_t kMaxFailures = 256;

} // namespace

NodeKindInfo AUPluginHost::kindInfo() {
    std::weak_ptr<AUPluginHost> weak = weak_from_this();
    return NodeKindInfo{[weak](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
        auto host = weak.lock();
        if (!host) return makeError(ErrorCode::internal, "auPlugin: the plugin host is gone");
        return host->create(info);
    }};
}

Result<std::unique_ptr<Node>> AUPluginHost::create(const NodeCreateInfo& info) {
    const NodeDesc& desc = info.desc;
    auto parsed = AUPluginConfig::parse(desc.configJSON);
    if (!parsed) {
        Error e = parsed.error();
        e.message = "auPlugin " + std::to_string(desc.id) + ": " + e.message;
        return e;
    }
    const AUPluginConfig config = std::move(parsed).value();
    // PLUG-022 (T-064): every node instance gets its own health, reported at most once.
    auto health = std::make_shared<PluginHealth>();
    Telemetry* telemetry = nullptr;
    {
        std::lock_guard lock(mutex_);
        Slot& slot = slots_[desc.id];
        slot.health = health;
        slot.healthReported = false;
        telemetry = telemetry_;
    }

    // T-083 (DW-224, PLUG-021): safe mode. The slot is built as absent (an effect passes its input
    // through, an instrument is silent) without instantiating or loading the plugin, so one that
    // crashes on load can't take the app down. No failure is reported (it is not one). The
    // configured state is kept for getPluginState, so saving keeps it exactly; a held state
    // (pending) and an instance that still exists (live, parked) are left for when it is enabled.
    if (config.disabled) {
        {
            std::lock_guard lock(mutex_);
            Slot& slot = slots_[desc.id];
            slot.identifier = config.identifier;
            slot.configState = config.state;
            slot.error.reset();
            slot.disabled = true;
        }
        return std::unique_ptr<Node>(std::make_unique<AUPluginNode>(
            desc.id, nullptr, config.component.isInstrument(), desc.firstParam, desc.numParams, info.latency,
            weak_from_this(), health, telemetry));
    }

    std::shared_ptr<AUInstance> live, parked;
    std::optional<std::vector<uint8_t>> pending;
    std::vector<uint8_t> previousConfigState;
    {
        std::lock_guard lock(mutex_);
        Slot& slot = slots_[desc.id];
        live = slot.live.lock();
        if (live && live->component() != config.component) live.reset();
        if (slot.parked && slot.parked->component() == config.component) parked = slot.parked;
        pending = slot.pending;
        previousConfigState = slot.configState;
        slot.error.reset();
    }

    std::shared_ptr<AUInstance> instance;
    bool adopted = false;
    if (live) {
        instance = live;
        adopted = true;
    } else if (parked) {
        instance = parked;
    } else {
        auto made = AUInstance::instantiate(config.component);
        if (!made) {
            Error e = made.error();
            e.message = "auPlugin " + std::to_string(desc.id) + ": " + e.message;
            reportFailure(desc.id, e);
            std::lock_guard lock(mutex_);
            Slot& slot = slots_[desc.id];
            slot.identifier = config.identifier;
            slot.configState = config.state;
            slot.disabled = false;
            // The plugin renders as absent; its state is kept for getPluginState (saving).
            return std::unique_ptr<Node>(std::make_unique<AUPluginNode>(
                desc.id, nullptr, config.component.isInstrument(), desc.firstParam, desc.numParams,
                info.latency, weak_from_this(), health, telemetry));
        }
        instance = std::move(made).value();
    }

    instance->setEditSink(editQueue(), desc.id);  // DW-204 (T-063)

    const std::vector<uint8_t>* apply = nullptr;
    if (pending) apply = &*pending;
    else if (!adopted && !config.state.empty()) apply = &config.state;
    else if (adopted && !config.state.empty() && config.state != previousConfigState) apply = &config.state;
    if (apply) {
        if (auto set = instance->setFullState(*apply); !set) {
            Error e = set.error();
            e.message = "auPlugin " + std::to_string(desc.id) + ": " + e.message;
            reportFailure(desc.id, e);
        }
    }

    {
        std::lock_guard lock(mutex_);
        Slot& slot = slots_[desc.id];
        slot.identifier = config.identifier;
        slot.live = instance;
        if (slot.parked == instance) slot.parked.reset();
        slot.configState = config.state;
        slot.disabled = false;
        if (pending) slot.pending.reset();
    }
    return std::unique_ptr<Node>(std::make_unique<AUPluginNode>(desc.id, instance, !instance->hasAudioInput(),
                                                                desc.firstParam, desc.numParams, info.latency,
                                                                weak_from_this(), health, telemetry));
}

Result<void> AUPluginHost::instantiate(NodeID slotID, std::string_view identifier) {
    auto component = parseAUIdentifier(identifier);
    if (!component) return component.error();
    auto made = AUInstance::instantiate(component.value());
    if (!made) return made.error();
    made.value()->setEditSink(editQueue(), slotID);  // DW-204 (T-063)
    std::lock_guard lock(mutex_);
    Slot& slot = slots_[slotID];
    slot.parked = std::move(made).value();
    if (slot.identifier.empty()) slot.identifier = formatAUIdentifier(component.value());
    return {};
}

bool AUPluginHost::knows(NodeID slotID) const {
    std::lock_guard lock(mutex_);
    auto it = slots_.find(slotID);
    return it != slots_.end() && !it->second.identifier.empty();
}

Result<std::vector<uint8_t>> AUPluginHost::state(NodeID slotID) const {
    std::shared_ptr<AUInstance> instance;
    {
        std::lock_guard lock(mutex_);
        auto it = slots_.find(slotID);
        if (it == slots_.end()) return std::vector<uint8_t>{};
        const Slot& slot = it->second;
        instance = slot.live.lock();
        if (!instance) instance = slot.parked;
        if (!instance) return slot.pending ? *slot.pending : slot.configState;
    }
    return instance->fullState();
}

Result<void> AUPluginHost::setState(NodeID slotID, const std::vector<uint8_t>& state) {
    std::shared_ptr<AUInstance> instance;
    {
        std::lock_guard lock(mutex_);
        Slot& slot = slots_[slotID];
        instance = slot.live.lock();
        if (!instance) instance = slot.parked;
        if (!instance) {
            slot.pending = state;  // for the slot's first AU
            return {};
        }
    }
    return instance->setFullState(state);
}

std::shared_ptr<AUInstance> AUPluginHost::instance(NodeID slotID) const {
    std::lock_guard lock(mutex_);
    auto it = slots_.find(slotID);
    return it == slots_.end() ? nullptr : it->second.live.lock();
}

Result<std::shared_ptr<AUInstance>> AUPluginHost::reinstantiate(NodeID slotID, const std::shared_ptr<AUInstance>& old) {
    auto made = AUInstance::instantiate(old->component());
    if (!made) return made.error();
    std::shared_ptr<AUInstance> fresh = std::move(made).value();
    fresh->setEditSink(editQueue(), slotID);  // DW-204 (T-063)
    auto state = old->fullState();
    if (state && !state.value().empty()) {
        if (auto set = fresh->setFullState(state.value()); !set) reportFailure(slotID, set.error());
    }
    std::lock_guard lock(mutex_);
    Slot& slot = slots_[slotID];
    if (slot.live.lock() == old) slot.live = fresh;
    return fresh;
}

void AUPluginHost::reportFailure(NodeID slotID, Error error) {
    std::lock_guard lock(mutex_);
    slots_[slotID].error = error;
    if (failures_.size() < kMaxFailures) failures_.push_back(Failure{slotID, std::move(error)});
}

std::vector<AUPluginHost::Failure> AUPluginHost::takeFailures() {
    std::lock_guard lock(mutex_);
    return std::exchange(failures_, {});
}

std::string AUPluginHost::infoJSON(NodeID slotID) const {
    std::shared_ptr<AUInstance> instance;
    std::string identifier;
    std::optional<Error> error;
    bool disabled = false;
    {
        std::lock_guard lock(mutex_);
        auto it = slots_.find(slotID);
        if (it == slots_.end()) return "{\"slot\":" + std::to_string(slotID) + ",\"loaded\":false}";
        instance = it->second.live.lock();
        if (!instance) instance = it->second.parked;
        identifier = it->second.identifier;
        error = it->second.error;
        disabled = it->second.disabled;
        if (disabled) instance.reset();  // T-083: safe mode reports the slot as not loaded
    }
    std::string json = "{\"slot\":" + std::to_string(slotID) + ",\"identifier\":" + pluginJSONString(identifier) +
                       ",\"loaded\":" + (instance ? "true" : "false");
    if (error) json += ",\"error\":" + pluginJSONString(error->message);
    if (disabled) json += ",\"disabled\":true";  // T-083 (DW-224)
    if (instance) {
        json += ",\"name\":" + pluginJSONString(instance->name());
        json += std::string(",\"instrument\":") + (instance->hasAudioInput() ? "false" : "true");
        json += std::string(",\"midi\":") + (instance->acceptsMIDI() ? "true" : "false");
        json += std::string(",\"sidechain\":") + (instance->sidechainEnabled() ? "true" : "false");
        json += ",\"inputChannels\":" + std::to_string(instance->inputChannels());
        json += ",\"outputChannels\":" + std::to_string(instance->outputChannels());
        json += ",\"latencySamples\":" + std::to_string(instance->latencySamples());
        json += ",\"tailSeconds\":" + pluginJSONNumber(instance->tailSeconds());
        json += ",\"params\":[";
        const std::vector<AUParamInfo> params = instance->params(true);
        for (std::size_t i = 0; i < params.size(); ++i) {
            const AUParamInfo& p = params[i];
            if (i) json += ",";
            json += "{\"index\":" + std::to_string(i) + ",\"address\":" + std::to_string(p.address) +
                    ",\"id\":" + pluginJSONString(p.identifier) + ",\"name\":" + pluginJSONString(p.name) +
                    ",\"unit\":" + pluginJSONString(p.unit) + ",\"min\":" + pluginJSONNumber(p.min) +
                    ",\"max\":" + pluginJSONNumber(p.max) + ",\"value\":" + pluginJSONNumber(p.value) +
                    ",\"canRamp\":" + (p.canRamp ? "true" : "false") +
                    pluginJSONParamExtras(p.steps, p.labels, p.display) + "}";
        }
        json += "]";
    }
    return json + "}";
}

// MARK: PLUG-022 (T-064)

std::vector<NodeID> AUPluginHost::takeMisbehaved() {
    std::lock_guard lock(mutex_);
    std::vector<NodeID> out;
    for (auto& [id, slot] : slots_) {
        if (!slot.health || slot.healthReported || !slot.health->raised()) continue;
        slot.healthReported = true;
        out.push_back(id);
    }
    return out;
}

void AUPluginHost::setTelemetry(Telemetry* telemetry) {
    std::lock_guard lock(mutex_);
    telemetry_ = telemetry;
}

// DW-204 (T-063).
void AUPluginHost::setEditQueue(std::shared_ptr<PluginEditQueue> queue) {
    std::lock_guard lock(mutex_);
    editQueue_ = std::move(queue);
}

std::shared_ptr<PluginEditQueue> AUPluginHost::editQueue() const {
    std::lock_guard lock(mutex_);
    return editQueue_;
}

// PLUG-017 (T-063): the instance an editor shows: the slot's latest node's, else a parked one.
std::shared_ptr<AUInstance> AUPluginHost::current(NodeID slotID) const {
    std::lock_guard lock(mutex_);
    auto it = slots_.find(slotID);
    if (it == slots_.end() || it->second.disabled) return nullptr;  // T-083: no editor in safe mode
    if (auto live = it->second.live.lock()) return live;
    return it->second.parked;
}

} // namespace daw
