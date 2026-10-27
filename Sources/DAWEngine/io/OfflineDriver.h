#pragma once
// IO-010..013: renders a tick range of the current graph to a file, without a device.
//
// render() runs on the calling thread, which must not be an RT thread: it calls Engine::render
// in a loop with a fixed block size, as fast as it can, and writes each block with an
// AudioFileWriter between calls. Engine::render must have no other caller meanwhile (02: one
// render thread at a time), so the device driver is stopped before an offline render starts.
//
// Transport (TIME-004, TIME-008): the render plays the range through the engine's transport,
// with the loop off and no output latency, starting with a locate that resets the timeline
// nodes, so renders on one engine are bit-identical (IO-011). Afterwards the transport is
// stopped and its position, loop and output latency are restored. Commands only apply at the
// start of a block, so the driver also renders a 0-frame block before (to read the real
// transport state) and after (to apply the restore); these aren't audio blocks and aren't
// counted in `blocks`. Effects keep their state
// across a locate (TIME-008), so an effect's tail still ringing from an earlier render or
// playback carries into the next export.
//
// IO-013: Engine::render runs in its RtScope as always, so the RT trap stays active offline.
// The driver also counts each render call in its own RtScope and reports the sum: the render
// thread's own count (DW-019), unaffected by what other threads do.

#include <cstdint>

#include "core/Engine.h"
#include "core/Result.h"
#include "io/ExportSpec.h"
#include "time/TempoMap.h"

namespace daw {

enum class TailEnd : uint8_t {
    none,       // no tail: disabled, or a zero quiet/max length
    quiet,      // IO-012: the output stayed below the threshold for quietSeconds
    maxLength,  // IO-012: maxSeconds ran out first
};

// About the last render() call, valid once it returns (successfully or not).
struct OfflineRenderStats {
    int64_t rangeFrames = 0;    // tickToSample(to) − tickToSample(from)
    int64_t tailFrames = 0;     // written after the range end
    int64_t framesWritten = 0;  // rangeFrames + tailFrames once complete
    uint64_t blocks = 0;        // Engine::render calls of blockSize frames
    TailEnd tailEnd = TailEnd::none;
    uint64_t rtViolations = 0;  // IO-013: this thread's RT trap count over all render calls (0 in Release)
    uint64_t clippedSamples = 0;
    double renderSeconds = 0;   // wall time of the render loop, file writes included
};

class OfflineDriver {
public:
    // 04 Interfaces. Renders [from, to) plus the tail (IO-012) into spec.file. Fails without
    // rendering on invalid arguments (to < from, block size 0 or above kMaxBlock, bad tail
    // settings) and when the file can't be created. It stops, removes the partial file and
    // fails when a write fails or the transport doesn't follow spec.tempo (see ExportSpec).
    // `progress` may be empty.
    Result<void> render(Engine& engine, Tick from, Tick to, const ExportSpec& spec,
                        ProgressFn progress);

    const OfflineRenderStats& lastRender() const { return stats_; }

private:
    OfflineRenderStats stats_;
};

} // namespace daw
