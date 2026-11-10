#pragma once
// REC-020..022 (T-054): input monitoring, the part the audio thread evaluates.
//
//   - REC-020: a track's mode is off, on or auto. `auto` is on while the track is armed and the
//     transport is stopped or recording, and off while it plays without recording. It is
//     evaluated per block on the audio thread from the transport state (DECISIONS "T-054 auto"),
//     so the switch at play/stop is sample-accurate and the model keeps the mode the user chose.
//   - REC-021: while monitoring is active, the track's device input pair replaces its clip
//     player's output into the track's insert chain (RenderGraph does the swap). MIDI tracks
//     ignore the mode (play-through is REC-011).
//   - REC-022: the mode is a param slot (MonitorDesc::modeSlot); arming and the input pair are in
//     the GraphDescription, so changing them rebuilds.
//
// core/ rather than record/ because RenderGraph applies it, and core doesn't depend on record/.

#include <cstdint>

#include "core/AudioBufferView.h"
#include "core/Realtime.h"

namespace daw {

// The value MonitorDesc::modeSlot holds (rounded to the nearest; anything else is off).
enum class MonitoringMode : uint8_t { off = 0, on = 1, automatic = 2 };

constexpr MonitoringMode monitoringModeFromSlot(float value) DAW_RT {
    if (value > 0.5f && value < 1.5f) return MonitoringMode::on;
    if (value >= 1.5f && value < 2.5f) return MonitoringMode::automatic;
    return MonitoringMode::off;
}

// REC-020's truth table. `playing` and `recording` are the transport's own state for the block
// (TransportBlock::playing/recording); recording counts only while playing.
constexpr bool monitoringActive(MonitoringMode mode, bool armed, bool playing, bool recording) DAW_RT {
    switch (mode) {
    case MonitoringMode::off: return false;
    case MonitoringMode::on: return true;
    case MonitoringMode::automatic: return armed && (!playing || recording);
    }
    return false;
}

// REC-021: frames over which a monitored step crossfades between its clip player and the input
// when monitoring switches (declick).
inline constexpr uint32_t kMonitorFadeFrames = 64;

// What RenderGraph::process monitors this block. `enabled` false (offline renders, a device with
// no input running): nothing is monitored and clip players play. `input` null with `enabled`:
// active steps output silence (Engine's MIX-023 pre-roll, which has no input to give, so no clip
// audio reaches the PDC delay lines of a monitored track).
struct MonitorInput {
    bool enabled = false;
    const AudioBufferView* input = nullptr;
};

} // namespace daw
