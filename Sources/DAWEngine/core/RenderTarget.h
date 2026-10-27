#pragma once
// ENG-040: where Engine::render writes the master output. The caller (CoreAudioDriver or
// OfflineDriver, 04) points it at the device buffer or the export buffer for each block.

#include "core/AudioBufferView.h"

namespace daw {

struct RenderTarget {
    // Receives the master bus. Channels the master doesn't have are written as silence.
    AudioBufferView output;
    // Device input for this block (recording/monitoring, 09). Empty for offline renders.
    AudioBufferView input;
};

} // namespace daw
