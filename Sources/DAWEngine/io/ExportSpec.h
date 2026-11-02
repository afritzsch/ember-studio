#pragma once
// What OfflineDriver::render (04 Interfaces, IO-010..013) renders and where it goes. The facade's
// ExportSpecPOD (08) maps onto this.

#include <cstdint>
#include <filesystem>
#include <functional>

#include "core/AudioBufferView.h"
#include "io/AudioFileWriter.h"
#include "time/TempoMap.h"

namespace daw {

// IO-012: after the range end, rendering continues until every output channel stays below
// `thresholdDb` for `quietSeconds`, or for at most `maxSeconds`, whichever comes first. The
// quiet stretch that ends the tail is part of the file.
struct TailSpec {
    bool enabled = true;
    double thresholdDb = -90.0;  // a sample is quiet when |x| < 10^(thresholdDb / 20)
    double quietSeconds = 1.0;
    double maxSeconds = 10.0;
};

// Rendered audio as it is written, for analysis or meters: the first `numFrames` frames of each
// block that belong to the export (the last block is cut where the render ends).
using OfflineBlockSink = std::function<void(const AudioBufferView&)>;

struct ExportSpec {
    // Empty: render without writing a file (only `sink` sees the audio).
    std::filesystem::path file;
    AudioFileType fileType = AudioFileType::wav;
    AudioSampleFormat sampleFormat = AudioSampleFormat::float32;
    // IO-035: TPDF dither for int16/int24, seeded so the export stays bit-identical (IO-011).
    bool dither = false;
    uint64_t ditherSeed = kDefaultDitherSeed;
    uint32_t numChannels = 2;
    // IO-010: every Engine::render call is this long; at most the graph's maxBlock (kMaxBlock).
    uint32_t blockSize = 512;
    // The tempo map of the graph being rendered (RenderGraph::tempoMap(), the project's map at
    // the session rate). It converts the range and the tail to frames up front, and its rate is
    // the file's. A copy is passed because the driver runs off the audio thread, where the
    // current graph may be retired at any moment; the facade has the map it built the graph
    // from. The driver checks every block that the transport, playing the graph's own map, is
    // where this map says, and fails on a mismatch.
    TempoMap tempo;
    TailSpec tail;
    OfflineBlockSink sink;
    // T-036 (TIME-005/006 goldens): false, the default, plays [from, to) straight through with
    // the loop off. True keeps the transport's loop as it is: the export is still
    // tickToSample(to) − tickToSample(from) frames (plus the tail) of playback from `from`, but
    // it wraps at the loop end the way live playback does (03 "Transport semantics").
    bool followLoop = false;
};

// Reported after every block. The total isn't known up front: the tail ends early when the
// output goes quiet, so `maxFrames` is the upper bound (range + maximum tail).
struct OfflineProgress {
    int64_t framesRendered;
    int64_t rangeFrames;
    int64_t maxFrames;
};
using ProgressFn = std::function<void(const OfflineProgress&)>;

} // namespace daw
