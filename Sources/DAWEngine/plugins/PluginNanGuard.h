#pragma once
// PLUG-022 (T-064): what the engine does when a hosted plugin outputs NaN or infinity. The plugin
// node checks its output after every block it rendered; a block with any non-finite sample is
// replaced by silence (so it can't poison the mix, PDC delay lines or a downstream filter), counted
// in Telemetry's nanBlocks (DSP-040's counter, T-070), and the node's PluginHealth is raised. The
// node's host (AUPluginHost, VST3PluginHost) reports a raised health once, as a pluginMisbehaved
// event for the slot (takeMisbehaved → EngineFacade); every new node instance of the slot gets a
// fresh PluginHealth, so a rebuilt node can be reported again. The plugin keeps running: a plugin
// that misbehaves for one block (a denormal blow-up, a bad parameter) may recover.

#include <atomic>
#include <cstdint>
#include <cstring>

#include "core/AudioBufferView.h"
#include "core/Realtime.h"
#include "core/Telemetry.h"

namespace daw {

// One per plugin node instance, shared with its host. The audio thread only raises it.
class PluginHealth {
public:
    void raise() DAW_RT { raised_.store(true, std::memory_order_relaxed); }
    bool raised() const { return raised_.load(std::memory_order_relaxed); }

private:
    std::atomic<bool> raised_{false};
};

// True when the first `numFrames` frames of every channel are finite. x × 0 is ±0 for a finite x
// and NaN otherwise, so the sum is NaN exactly when some sample isn't finite (no -ffast-math).
inline bool isFinite(const AudioBufferView& out, uint32_t numFrames) DAW_RT {
    float probe = 0.0f;
    for (uint32_t c = 0; c < out.numChannels; ++c)
        for (uint32_t f = 0; f < numFrames; ++f) probe += out.channels[c][f] * 0.0f;
    return probe == probe;
}

// The guard (PLUG-022): silences a non-finite block, counts it and raises `health`. Returns true
// when it had to.
inline bool guardPluginOutput(const AudioBufferView& out, uint32_t numFrames, Telemetry* telemetry,
                              PluginHealth* health) DAW_RT {
    if (isFinite(out, numFrames)) return false;
    for (uint32_t c = 0; c < out.numChannels; ++c)
        std::memset(out.channels[c], 0, std::size_t{out.numFrames} * sizeof(float));
    if (telemetry != nullptr) telemetry->countNanBlock();
    if (health != nullptr) health->raise();
    return true;
}

} // namespace daw
