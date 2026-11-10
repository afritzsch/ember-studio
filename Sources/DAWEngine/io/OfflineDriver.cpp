#include "io/OfflineDriver.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <string>
#include <system_error>
#include <vector>

#include "core/Node.h"
#include "core/RtTrap.h"

namespace daw {

namespace {

bool validSeconds(double s) { return std::isfinite(s) && s >= 0; }

// T-036 (ExportSpec::followLoop): where the transport starts its next block after `numFrames`
// of playback from `pos`, by Transport's rule (03 "Transport semantics"): it wraps only when it
// crosses the loop end from before it, and then as often as the block's frames reach the loop
// end again (DW-125: a loop shorter than a block wraps several times in it).
SamplePos nextLoopedStart(SamplePos pos, uint32_t numFrames, bool looping, SamplePos loopStart,
                          SamplePos loopEnd) {
    const SamplePos end = pos + numFrames;
    if (!looping || pos >= loopEnd || end < loopEnd) return end;
    return loopStart + (end - loopEnd) % (loopEnd - loopStart);
}

// T-082 (ExportSpec::normalize): the rendered export as interleaved float32 in an anonymous temp
// file (tmpfile(): a unique name, removed when closed, so parallel exports never share it, 00 §9).
// Pass one appends every kept block; pass two reads it back in blockSize chunks.
class FloatSpool {
public:
    explicit FloatSpool(uint32_t numChannels, uint32_t blockSize)
        : numChannels_(numChannels), interleaved_(std::size_t{numChannels} * blockSize) {}
    ~FloatSpool() {
        if (file_) std::fclose(file_);
    }
    FloatSpool(const FloatSpool&) = delete;
    FloatSpool& operator=(const FloatSpool&) = delete;

    Result<void> open() {
        file_ = std::tmpfile();
        if (!file_) return makeError(ErrorCode::io, "offline render: can't create the normalize temp file");
        return {};
    }

    Result<void> append(const AudioBufferView& block) {
        for (uint32_t f = 0; f < block.numFrames; ++f)
            for (uint32_t c = 0; c < numChannels_; ++c) interleaved_[std::size_t{f} * numChannels_ + c] = block.channels[c][f];
        const std::size_t count = std::size_t{block.numFrames} * numChannels_;
        if (std::fwrite(interleaved_.data(), sizeof(float), count, file_) != count)
            return makeError(ErrorCode::io, "offline render: writing the normalize temp file failed");
        return {};
    }

    Result<void> rewind() {
        if (std::fflush(file_) != 0 || std::fseek(file_, 0, SEEK_SET) != 0)
            return makeError(ErrorCode::io, "offline render: reading the normalize temp file failed");
        return {};
    }

    // Reads `numFrames` frames into `channels`, each scaled by `gain`.
    Result<void> read(float* const* channels, uint32_t numFrames, float gain) {
        const std::size_t count = std::size_t{numFrames} * numChannels_;
        if (std::fread(interleaved_.data(), sizeof(float), count, file_) != count)
            return makeError(ErrorCode::io, "offline render: reading the normalize temp file failed");
        for (uint32_t f = 0; f < numFrames; ++f)
            for (uint32_t c = 0; c < numChannels_; ++c) channels[c][f] = interleaved_[std::size_t{f} * numChannels_ + c] * gain;
        return {};
    }

private:
    uint32_t numChannels_;
    std::vector<float> interleaved_;
    std::FILE* file_ = nullptr;
};

} // namespace

Result<void> OfflineDriver::render(Engine& engine, Tick from, Tick to, const ExportSpec& spec,
                                   ProgressFn progress) {
    stats_ = {};
    if (to < from) return makeError(ErrorCode::invalidArgument, "offline render: range end before start");
    if (spec.blockSize == 0 || spec.blockSize > kMaxBlock)
        return makeError(ErrorCode::invalidArgument, "offline render: block size out of range");
    if (spec.numChannels == 0 || spec.numChannels > kMaxFileChannels)
        return makeError(ErrorCode::invalidArgument, "offline render: unsupported channel count");
    const TailSpec& tail = spec.tail;
    if (tail.enabled && !(std::isfinite(tail.thresholdDb) && validSeconds(tail.quietSeconds) &&
                          validSeconds(tail.maxSeconds)))
        return makeError(ErrorCode::invalidArgument, "offline render: invalid tail settings");

    // The export's own copy of the tempo map gives the frame counts; the transport plays the
    // graph's map. They must agree, which the loop checks block by block (see below).
    const TempoMap& tempo = spec.tempo;
    const double rate = tempo.sampleRate();
    const int64_t rangeFrames = tempo.tickToSample(to) - tempo.tickToSample(from);

    // IO-012
    int64_t maxTail = 0, quietNeeded = 0;
    double quietBelow = 0;
    if (tail.enabled) {
        maxTail = std::llround(tail.maxSeconds * rate);
        quietNeeded = std::llround(tail.quietSeconds * rate);
        quietBelow = std::pow(10.0, tail.thresholdDb / 20.0);
        if (quietNeeded == 0) maxTail = 0;  // quiet at once: nothing to wait for
    }
    const int64_t maxFrames = rangeFrames + maxTail;
    stats_.rangeFrames = rangeFrames;

    std::unique_ptr<AudioFileWriter> writer;
    if (!spec.file.empty()) {
        const AudioFileFormat format{spec.fileType, spec.sampleFormat, rate, spec.numChannels,
                                     spec.dither, spec.ditherSeed};
        auto created = AudioFileWriter::create(spec.file, format);
        if (!created) return created.error();
        writer = std::move(created).value();
    }
    // T-082: with normalize, pass one goes to a float spool instead of the writer and the sink.
    std::unique_ptr<FloatSpool> spool;
    if (spec.normalize && maxFrames > 0) {
        spool = std::make_unique<FloatSpool>(spec.numChannels, spec.blockSize);
        if (auto opened = spool->open(); !opened) {
            if (writer) {
                writer.reset();
                std::error_code ec;
                std::filesystem::remove(spec.file, ec);
            }
            return opened;
        }
    }

    // The render target: allocated here, before the loop, never inside it.
    const uint32_t numChannels = spec.numChannels;
    const uint32_t blockSize = spec.blockSize;
    std::vector<float> samples(std::size_t{numChannels} * blockSize);
    std::vector<float*> channels(numChannels);
    for (uint32_t c = 0; c < numChannels; ++c) channels[c] = samples.data() + std::size_t{c} * blockSize;
    RenderTarget target{AudioBufferView{channels.data(), numChannels, blockSize}, AudioBufferView{}};

    // IO-013: every Engine::render call is counted in this thread's own RtScope (DW-019).
    auto renderCounted = [&](uint32_t numFrames) {
        RtScope scope;
        engine.render(target, numFrames);
        stats_.rtViolations += scope.violations();
    };

    // TIME-004: commands apply in order at the start of the next block, and the playhead only
    // shows what the last block applied. So a 0-frame block (ENG-004) first applies whatever is
    // queued, making the playhead the transport's real state to restore afterwards.
    //
    // Then, all before the first exported frame: no output latency (offline output isn't
    // delayed, and it makes the playhead the exact block start), the loop off so the range plays
    // straight through, and play() before locate(): a locate applied while playing resets the
    // timeline nodes (TIME-008), so every render starts them from the same state, however the
    // previous render or playback left them (IO-011).
    Transport& transport = engine.transport();
    TransportPlayhead before;
    const uint32_t latencyBefore = transport.outputLatency();
    Result<void> failure;
    if (maxFrames > 0) {
        renderCounted(0);
        before = transport.playhead();
        transport.setOutputLatency(0);
        // T-036: followLoop leaves the loop as the transport has it.
        if (!((spec.followLoop || transport.setLoop(false, before.loopStart, before.loopEnd)) &&
              transport.play() && transport.locate(from)))
            failure = makeError(ErrorCode::internal, "offline render: transport command queue full");
        // DW-063 (T-089): and every node starts from a clean state, effect tails included, so
        // renders on one engine are bit-identical whatever played before (IO-011).
        engine.resetAllNodesBeforeNextBlock();
    }

    // IO-010: fixed-size blocks back to back, as fast as possible. The last block is rendered in
    // full and cut where the export ends, so every Engine::render call has the same length.
    const auto started = std::chrono::steady_clock::now();
    const SamplePos startSample = tempo.tickToSample(from);
    int64_t written = 0, quietRun = 0;
    // T-036: with followLoop, block starts follow the transport's loop as it was before the
    // render (`before`), resolved through spec.tempo like everything else.
    const bool looping = spec.followLoop && before.loopEnabled &&
                         tempo.tickToSample(before.loopEnd) > tempo.tickToSample(before.loopStart);
    const SamplePos loopStartSample = tempo.tickToSample(before.loopStart);
    const SamplePos loopEndSample = tempo.tickToSample(before.loopEnd);
    SamplePos loopedStart = startSample;
    while (failure && written < maxFrames) {
        renderCounted(blockSize);

        // The playhead is where this block started on the graph's own map. If it isn't where
        // spec.tempo says, the export would have the wrong length: the spec's map differs from
        // the graph's (or the graph changed mid-render), or the engine didn't render the block
        // (no graph published, or blockSize above the graph's maxBlock), so the transport stood
        // still. Fail rather than write a wrong file.
        SamplePos blockStart = startSample + static_cast<SamplePos>(stats_.blocks) * blockSize;
        if (spec.followLoop) {
            blockStart = loopedStart;
            loopedStart = nextLoopedStart(loopedStart, blockSize, looping, loopStartSample, loopEndSample);
        }
        const TransportPlayhead head = transport.playhead();
        ++stats_.blocks;
        if (!head.playing || head.sample != blockStart || head.tick != tempo.sampleToTick(blockStart)) {
            failure = makeError(ErrorCode::invalidArgument,
                                "offline render: the transport didn't follow the export range (no graph, "
                                "block size above the graph's maxBlock, or ExportSpec.tempo isn't the "
                                "graph's tempo map)");
            break;
        }

        uint32_t keep = static_cast<uint32_t>(std::min<int64_t>(blockSize, maxFrames - written));
        // IO-012: count quiet frames from the range end on; the tail ends on the frame that
        // completes quietNeeded of them in a row. Without a tail, keep never passes the range end.
        const int64_t tailStart = std::max<int64_t>(0, rangeFrames - written);  // in this block
        for (uint32_t f = static_cast<uint32_t>(std::min<int64_t>(tailStart, keep)); f < keep; ++f) {
            bool quiet = true;
            for (uint32_t c = 0; c < numChannels && quiet; ++c)
                quiet = std::fabs(static_cast<double>(channels[c][f])) < quietBelow;
            quietRun = quiet ? quietRun + 1 : 0;
            if (quietRun == quietNeeded) {
                keep = f + 1;
                stats_.tailEnd = TailEnd::quiet;
                break;
            }
        }

        const AudioBufferView block{channels.data(), numChannels, keep};
        for (uint32_t c = 0; c < numChannels; ++c)  // T-082: the export's sample peak
            for (uint32_t f = 0; f < keep; ++f)
                stats_.peak = std::max(stats_.peak, std::fabs(static_cast<double>(channels[c][f])));
        if (spool) {
            failure = spool->append(block);
            if (!failure) break;
        } else {
            if (writer) {
                failure = writer->write(block);
                if (!failure) break;
            }
            if (spec.sink) spec.sink(block);
        }
        written += keep;
        stats_.framesWritten = written;
        if (progress) progress(OfflineProgress{written, rangeFrames, maxFrames});
        if (stats_.tailEnd == TailEnd::quiet) break;
    }
    if (maxTail > 0 && stats_.tailEnd != TailEnd::quiet && written == maxFrames)
        stats_.tailEnd = TailEnd::maxLength;
    stats_.tailFrames = std::max<int64_t>(0, written - rangeFrames);

    // Leave the transport as the render found it: stopped where it was, loop and latency
    // restored, applied by another 0-frame block so the playhead is settled when render()
    // returns. A full queue would only leave the transport where the export ended, so it
    // doesn't fail the render.
    if (maxFrames > 0) {
        (void)transport.stop();
        (void)transport.locate(before.tick);
        (void)transport.setLoop(before.loopEnabled, before.loopStart, before.loopEnd);
        transport.setOutputLatency(latencyBefore);
        renderCounted(0);
    }

    // T-082 pass two: the spooled render, scaled so its peak is kNormalizePeakDb, into the writer
    // (which dithers and quantizes) and the sink, in blockSize chunks. Silence (or a peak that
    // isn't finite) keeps gain 1.
    if (spool && failure) {
        const double target = std::pow(10.0, kNormalizePeakDb / 20.0);
        if (std::isfinite(stats_.peak) && stats_.peak > 0) stats_.normalizeGain = target / stats_.peak;
        const float gain = static_cast<float>(stats_.normalizeGain);
        failure = spool->rewind();
        for (int64_t done = 0; failure && done < written;) {
            const uint32_t n = static_cast<uint32_t>(std::min<int64_t>(blockSize, written - done));
            failure = spool->read(channels.data(), n, gain);
            if (!failure) break;
            const AudioBufferView block{channels.data(), numChannels, n};
            if (writer) {
                failure = writer->write(block);
                if (!failure) break;
            }
            if (spec.sink) spec.sink(block);
            done += n;
        }
    }
    spool.reset();

    if (writer) {
        stats_.clippedSamples = writer->clippedSamples();
        if (failure) failure = writer->close();
        if (!failure) {
            writer.reset();
            std::error_code ec;
            std::filesystem::remove(spec.file, ec);  // don't leave a truncated export behind
        }
    }
    stats_.renderSeconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    return failure;
}

} // namespace daw
