#pragma once
// PLUG-011/012/016 (T-062): a facade's VST3 plugins, per device slot (the vst3Plugin node's
// NodeID), the VST3 twin of AUPluginHost: same slot model and state precedence (see AUPluginHost.h).
//
// One instance per slot, surviving node re-creations. Only these make a new instance: a new slot
// (or one whose last instance is gone), a changed identifier, a session-rate change (the new
// instance gets the old one's state). instantiate() parks an instance for a slot ahead of the
// graph, on the caller's thread (PLUG-012), and the build adopts it.
//
// Threads: every call is non-RT and thread-safe (one mutex; instantiation and state I/O run
// outside it). Failures queue up for the facade, which turns them into pluginCrashed events.

#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/Result.h"
#include "graph/NodeRegistry.h"
#include "plugins/VST3Instance.h"
#include "plugins/PluginNanGuard.h"

namespace daw {

class VST3PluginHost : public std::enable_shared_from_this<VST3PluginHost> {
public:
    // The registry entry for NodeKind::vst3Plugin. Keeps a weak reference to the host.
    NodeKindInfo kindInfo();

    Result<void> instantiate(NodeID slot, std::string_view identifier);

    // True when `slot` has been configured as a VST3 plugin (by a node or instantiate), even if
    // it failed to load. A held-state-only slot isn't: the facade routes plugin calls by this.
    bool knows(NodeID slot) const;

    Result<std::vector<uint8_t>> state(NodeID slot) const;
    Result<void> setState(NodeID slot, const std::vector<uint8_t>& state);

    // Same JSON shape as AUPluginHost::infoJSON ({"slot", "identifier", "loaded", "error"?,
    // "name", "instrument", "midi", "sidechain", "inputChannels", "outputChannels",
    // "latencySamples", "tailSeconds", "params": [{"index", "address", "id", "name", "unit",
    // "min", "max", "value", "canRamp"}]}). address and id carry the ParamID; min/max are 0/1
    // (VST3 parameters are normalized), and canRamp is false (one point per block, D-13).
    std::string infoJSON(NodeID slot) const;

    struct Failure {
        NodeID slot;
        Error error;
    };
    std::vector<Failure> takeFailures();

    // PLUG-022 (T-064): the slots whose current node output NaN/inf since its creation, each
    // reported once (the facade turns them into pluginMisbehaved events). A new node instance of
    // the slot (a rebuild that re-creates it) can be reported again.
    std::vector<NodeID> takeMisbehaved();
    // PLUG-022: where nodes count their silenced blocks (Telemetry::countNanBlock). Set before the
    // first build; the telemetry must outlive every node.
    void setTelemetry(Telemetry* telemetry);

    // For VST3PluginNode (non-RT).
    void reportFailure(NodeID slot, Error error);
    Result<std::shared_ptr<VST3Instance>> reinstantiate(NodeID slot, const std::shared_ptr<VST3Instance>& old);
    std::shared_ptr<VST3Instance> instance(NodeID slot) const;

private:
    Result<std::unique_ptr<Node>> create(const NodeCreateInfo& info);

    struct Slot {
        std::string identifier;
        std::weak_ptr<VST3Instance> live;
        std::shared_ptr<VST3Instance> parked;
        std::vector<uint8_t> configState;          // the configJSON state the instance was made with
        std::optional<std::vector<uint8_t>> pending;  // setState before an instance existed
        std::optional<Error> error;                // the latest failure
        std::shared_ptr<PluginHealth> health;      // PLUG-022: the latest node's
        bool healthReported = false;
    };

    mutable std::mutex mutex_;
    std::map<NodeID, Slot> slots_;
    std::vector<Failure> failures_;
    Telemetry* telemetry_ = nullptr;  // PLUG-022
};

} // namespace daw
