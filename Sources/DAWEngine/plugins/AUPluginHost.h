#pragma once
// PLUG-010/012/016 (T-061): a facade's Audio Units, per device slot (the auPlugin node's NodeID).
// It is the NodeKind::auPlugin factory (kindInfo) and what the facade's plugin calls act on
// (instantiatePlugin, get/setPluginState, pluginInfoJSON).
//
// One AU per slot. A slot keeps its AUInstance across node re-creations (a configVersion bump, a
// change of its param range), so editing the project never resets the plugin's DSP or loses state
// changed since it was loaded: the new node adopts the AU the slot's last node used. Only these
// make a new AU:
//   - the slot is new, or its last AU is gone (the node left the graph and was reclaimed);
//   - the identifier changed;
//   - the session rate changed (AUPluginNode::prepare → reinstantiate: the new AU gets the old
//     one's state, since the old graph may still render the old AU).
// instantiatePlugin parks an AU for a slot ahead of the graph (on the caller's thread, PLUG-012),
// so the build adopts it instead of instantiating on daw.compile.
//
// State (PLUG-016), most recent intent first, when a node is made:
//   1. a setPluginState for a slot that had no AU yet (held until one exists);
//   2. a new AU starts from the configJSON state (a project being opened) or, after a rate change,
//      the old AU's state;
//   3. an adopted AU keeps its state unless the configJSON state differs from the one it was made
//      with (the model replaced the state, e.g. an undo), which is then applied.
// getPluginState reads the AU's fullState, or for a slot whose plugin couldn't load, the state it
// was configured with, so saving a project on a machine without the plugin keeps the state.
//
// Threads: every call is non-RT and thread-safe (one mutex; instantiation and state I/O run
// outside it). Failures (a missing component, a prepare that failed) queue up for the facade,
// which turns them into pluginCrashed events (takeFailures, under its own lock: the host never
// calls into the facade).

#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/Result.h"
#include "graph/NodeRegistry.h"
#include "plugins/AUInstance.h"
#include "plugins/PluginNanGuard.h"

namespace daw {

class AUPluginHost : public std::enable_shared_from_this<AUPluginHost> {
public:
    // The registry entry for NodeKind::auPlugin. Keeps a weak reference to the host.
    NodeKindInfo kindInfo();

    // PLUG-012, 08 instantiatePlugin: instantiates `identifier` now, on the calling thread, and
    // parks it for `slot` (replacing an earlier parked one).
    Result<void> instantiate(NodeID slot, std::string_view identifier);

    // True when `slot` has been configured as an AU (T-062: the facade routes plugin calls by
    // this, so a held-state-only slot isn't known).
    bool knows(NodeID slot) const;

    // PLUG-016. state: empty when the slot has neither an AU nor a configured state.
    Result<std::vector<uint8_t>> state(NodeID slot) const;
    Result<void> setState(NodeID slot, const std::vector<uint8_t>& state);

    // {"slot", "identifier", "loaded", "error"?, "name", "instrument", "midi", "sidechain",
    //  "inputChannels", "outputChannels", "latencySamples", "tailSeconds",
    //  "params": [{"index", "address", "id", "name", "unit", "min", "max", "value", "canRamp"}]}
    // or {"slot": n, "loaded": false} for a slot the host doesn't know.
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

    // For AUPluginNode (non-RT).
    void reportFailure(NodeID slot, Error error);
    Result<std::shared_ptr<AUInstance>> reinstantiate(NodeID slot, const std::shared_ptr<AUInstance>& old);
    // The AU the slot's latest node uses (null if none).
    std::shared_ptr<AUInstance> instance(NodeID slot) const;

private:
    Result<std::unique_ptr<Node>> create(const NodeCreateInfo& info);

    struct Slot {
        std::string identifier;
        std::weak_ptr<AUInstance> live;
        std::shared_ptr<AUInstance> parked;
        std::vector<uint8_t> configState;          // the configJSON state the AU was made with
        std::optional<std::vector<uint8_t>> pending;  // setPluginState before an AU existed
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
