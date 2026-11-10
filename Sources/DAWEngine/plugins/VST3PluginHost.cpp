#include "plugins/VST3PluginHost.h"

#include <utility>

#include "plugins/PluginJSON.h"
#include "plugins/VST3PluginConfig.h"
#include "plugins/VST3PluginNode.h"

namespace daw {

namespace {

constexpr std::size_t kMaxFailures = 256;

Error slotError(NodeID slot, Error error) {
    error.message = "vst3Plugin " + std::to_string(slot) + ": " + error.message;
    return error;
}

} // namespace

NodeKindInfo VST3PluginHost::kindInfo() {
    std::weak_ptr<VST3PluginHost> weak = weak_from_this();
    return NodeKindInfo{[weak](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
        auto host = weak.lock();
        if (!host) return makeError(ErrorCode::internal, "vst3Plugin: the plugin host is gone");
        return host->create(info);
    }};
}

Result<std::unique_ptr<Node>> VST3PluginHost::create(const NodeCreateInfo& info) {
    const NodeDesc& desc = info.desc;
    auto parsed = VST3PluginConfig::parse(desc.configJSON);
    if (!parsed) return slotError(desc.id, parsed.error());
    const VST3PluginConfig config = std::move(parsed).value();

    std::shared_ptr<VST3Instance> live, parked;
    std::optional<std::vector<uint8_t>> pending;
    std::vector<uint8_t> previousConfigState;
    {
        std::lock_guard lock(mutex_);
        Slot& slot = slots_[desc.id];
        live = slot.live.lock();
        if (live && live->plugin() != config.plugin) live.reset();
        if (slot.parked && slot.parked->plugin() == config.plugin) parked = slot.parked;
        pending = slot.pending;
        previousConfigState = slot.configState;
        slot.error.reset();
    }

    std::shared_ptr<VST3Instance> instance;
    bool adopted = false;
    if (live) {
        instance = live;
        adopted = true;
    } else if (parked) {
        instance = parked;
    } else {
        auto made = VST3Instance::instantiate(config.plugin);
        if (!made) {
            reportFailure(desc.id, slotError(desc.id, made.error()));
            std::lock_guard lock(mutex_);
            Slot& slot = slots_[desc.id];
            slot.identifier = config.identifier;
            slot.configState = config.state;
            // The plugin renders as absent; its state is kept for getPluginState (saving).
            return std::unique_ptr<Node>(std::make_unique<VST3PluginNode>(
                desc.id, nullptr, desc.firstParam, desc.numParams, info.latency, weak_from_this()));
        }
        instance = std::move(made).value();
    }

    const std::vector<uint8_t>* apply = nullptr;
    if (pending) apply = &*pending;
    else if (!adopted && !config.state.empty()) apply = &config.state;
    else if (adopted && !config.state.empty() && config.state != previousConfigState) apply = &config.state;
    if (apply) {
        if (auto set = instance->setState(*apply); !set) reportFailure(desc.id, slotError(desc.id, set.error()));
    }

    {
        std::lock_guard lock(mutex_);
        Slot& slot = slots_[desc.id];
        slot.identifier = config.identifier;
        slot.live = instance;
        if (slot.parked == instance) slot.parked.reset();
        slot.configState = config.state;
        if (pending) slot.pending.reset();
    }
    return std::unique_ptr<Node>(std::make_unique<VST3PluginNode>(desc.id, instance, desc.firstParam, desc.numParams,
                                                                  info.latency, weak_from_this()));
}

Result<void> VST3PluginHost::instantiate(NodeID slotID, std::string_view identifier) {
    auto plugin = parseVST3Identifier(identifier);
    if (!plugin) return plugin.error();
    auto made = VST3Instance::instantiate(plugin.value());
    if (!made) return made.error();
    std::lock_guard lock(mutex_);
    Slot& slot = slots_[slotID];
    slot.parked = std::move(made).value();
    if (slot.identifier.empty()) slot.identifier = plugin.value().identifier();
    return {};
}

bool VST3PluginHost::knows(NodeID slotID) const {
    std::lock_guard lock(mutex_);
    auto it = slots_.find(slotID);
    return it != slots_.end() && !it->second.identifier.empty();
}

Result<std::vector<uint8_t>> VST3PluginHost::state(NodeID slotID) const {
    std::shared_ptr<VST3Instance> instance;
    {
        std::lock_guard lock(mutex_);
        auto it = slots_.find(slotID);
        if (it == slots_.end()) return std::vector<uint8_t>{};
        const Slot& slot = it->second;
        instance = slot.live.lock();
        if (!instance) instance = slot.parked;
        if (!instance) return slot.pending ? *slot.pending : slot.configState;
    }
    return instance->state();
}

Result<void> VST3PluginHost::setState(NodeID slotID, const std::vector<uint8_t>& state) {
    std::shared_ptr<VST3Instance> instance;
    {
        std::lock_guard lock(mutex_);
        Slot& slot = slots_[slotID];
        instance = slot.live.lock();
        if (!instance) instance = slot.parked;
        if (!instance) {
            slot.pending = state;  // for the slot's first instance
            return {};
        }
    }
    return instance->setState(state);
}

std::shared_ptr<VST3Instance> VST3PluginHost::instance(NodeID slotID) const {
    std::lock_guard lock(mutex_);
    auto it = slots_.find(slotID);
    return it == slots_.end() ? nullptr : it->second.live.lock();
}

Result<std::shared_ptr<VST3Instance>> VST3PluginHost::reinstantiate(NodeID slotID,
                                                                   const std::shared_ptr<VST3Instance>& old) {
    auto made = VST3Instance::instantiate(old->plugin());
    if (!made) return made.error();
    std::shared_ptr<VST3Instance> fresh = std::move(made).value();
    auto state = old->state();
    if (state && !state.value().empty()) {
        if (auto set = fresh->setState(state.value()); !set) reportFailure(slotID, set.error());
    }
    std::lock_guard lock(mutex_);
    Slot& slot = slots_[slotID];
    if (slot.live.lock() == old) slot.live = fresh;
    return fresh;
}

void VST3PluginHost::reportFailure(NodeID slotID, Error error) {
    std::lock_guard lock(mutex_);
    slots_[slotID].error = error;
    if (failures_.size() < kMaxFailures) failures_.push_back(Failure{slotID, std::move(error)});
}

std::vector<VST3PluginHost::Failure> VST3PluginHost::takeFailures() {
    std::lock_guard lock(mutex_);
    return std::exchange(failures_, {});
}

std::string VST3PluginHost::infoJSON(NodeID slotID) const {
    std::shared_ptr<VST3Instance> instance;
    std::string identifier;
    std::optional<Error> error;
    {
        std::lock_guard lock(mutex_);
        auto it = slots_.find(slotID);
        if (it == slots_.end()) return "{\"slot\":" + std::to_string(slotID) + ",\"loaded\":false}";
        instance = it->second.live.lock();
        if (!instance) instance = it->second.parked;
        identifier = it->second.identifier;
        error = it->second.error;
    }
    std::string json = "{\"slot\":" + std::to_string(slotID) + ",\"identifier\":" + pluginJSONString(identifier) +
                       ",\"loaded\":" + (instance ? "true" : "false");
    if (error) json += ",\"error\":" + pluginJSONString(error->message);
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
        const std::vector<VST3ParamInfo> params = instance->params(true);
        for (std::size_t i = 0; i < params.size(); ++i) {
            const VST3ParamInfo& p = params[i];
            if (i) json += ",";
            json += "{\"index\":" + std::to_string(i) + ",\"address\":" + std::to_string(p.id) +
                    ",\"id\":" + pluginJSONString(std::to_string(p.id)) + ",\"name\":" + pluginJSONString(p.name) +
                    ",\"unit\":" + pluginJSONString(p.unit) + ",\"min\":" + pluginJSONNumber(p.min) +
                    ",\"max\":" + pluginJSONNumber(p.max) + ",\"value\":" + pluginJSONNumber(p.value) +
                    ",\"canRamp\":false}";
        }
        json += "]";
    }
    return json + "}";
}

} // namespace daw
