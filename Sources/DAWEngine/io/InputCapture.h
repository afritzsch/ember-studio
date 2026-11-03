#pragma once
// REC-001: where a device IO cycle hands its input to the recorder. DeviceRenderer calls it after
// every Engine::render block with the block's device input and the transport that block was laid
// out with, on the render thread. 09-recording's Recorder (record/Recorder.h) implements it; the
// io layer only knows this seam, so drivers don't depend on record/.

#include <cstdint>

#include "core/AudioBufferView.h"
#include "core/Realtime.h"

namespace daw {

class Transport;

class InputCapture {
public:
    virtual ~InputCapture() = default;
    // RT, the engine's render thread (CONV-RT). `transport` has just advanced for this block
    // (Transport::block(), samplePos()), unless no graph was published: then it didn't move and
    // the capture must tell (Recorder compares samplePos with the last call). `input` holds the
    // block's device input (0 channels when input is off).
    virtual void captureBlock(const Transport& transport, const AudioBufferView& input,
                              uint32_t numFrames) DAW_RT = 0;
};

} // namespace daw
