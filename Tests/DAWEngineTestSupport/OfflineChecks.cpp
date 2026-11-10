// T-009 checks for OfflineDriver (IO-010..013). Run from Tests/DAWEngineTests/OfflineDriverTests.swift;
// see OfflineChecks.h for why they're C++.

#include "OfflineChecks.h"

#include "ExportTestSupport.h"
#include "RtTrapTestSupport.h"
#include "TestAudio.h"
#include "core/AudioBufferPool.h"
#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/RenderGraph.h"
#include "core/RtTrap.h"
#include "io/OfflineDriver.h"
#include "time/TempoMap.h"

#include <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <numbers>
#include <utility>
#include <vector>

namespace daw::testing {

namespace {

constexpr double kRate = 48000;
// At the default map (120 bpm, 48 kHz) one beat is 24000 frames, so 1920 ticks are 1 s.
constexpr Tick kOneSecond = 2 * kPPQ;

// MARK: Test nodes (TEST-004 style; test builds only)

class Source : public Node {
public:
    void prepare(const PrepareInfo&) override {}
};

// Channel c of frame n is n + c / 2: gaps, repeats and channel swaps all show.
class CounterSource final : public Source {
public:
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        if (ctx.numFrames == 0) {  // the driver's transport-settling blocks
            ++emptyBlocks;
            return;
        }
        minFrames = std::min(minFrames, ctx.numFrames);
        maxFrames = std::max(maxFrames, ctx.numFrames);
        ++processes;
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < ctx.numFrames; ++f)
                io.audioOut.channels[c][f] = static_cast<float>(next_ + f) + 0.5f * static_cast<float>(c);
        next_ += ctx.numFrames;
    }

    // Read by the test thread after rendering, which is the render thread here.
    uint32_t minFrames = kMaxBlock + 1, maxFrames = 0;
    uint64_t processes = 0, emptyBlocks = 0;

private:
    uint64_t next_ = 0;
};

// A sine by complex rotation (no libm call in the RT body), the same on every channel.
class SineSource final : public Source {
public:
    SineSource(double frequency, double amplitude)
        : stepRe_(std::cos(2 * std::numbers::pi * frequency / kRate)),
          stepIm_(std::sin(2 * std::numbers::pi * frequency / kRate)), im_(amplitude) {}

    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        for (uint32_t f = 0; f < ctx.numFrames; ++f) {
            const float y = static_cast<float>(im_);
            for (uint32_t c = 0; c < io.audioOut.numChannels; ++c) io.audioOut.channels[c][f] = y;
            const double re = re_ * stepRe_ - im_ * stepIm_;
            im_ = re_ * stepIm_ + im_ * stepRe_;
            re_ = re;
        }
    }

private:
    double stepRe_, stepIm_;
    double re_ = 0, im_;
};

// a(n) = a(n−1) · k in float, starting at 1: exponential decay by `dbPerSecond`.
class DecaySource final : public Source {
public:
    explicit DecaySource(double dbPerSecond) : k_(decayFactor(dbPerSecond)) {}

    static float decayFactor(double dbPerSecond) {
        return static_cast<float>(std::pow(10.0, -dbPerSecond / 20.0 / kRate));
    }

    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        for (uint32_t f = 0; f < ctx.numFrames; ++f) {
            for (uint32_t c = 0; c < io.audioOut.numChannels; ++c) io.audioOut.channels[c][f] = a_;
            a_ *= k_;
        }
    }

private:
    float k_;
    float a_ = 1.0f;
};

// 0.5 inside the [begin, end) frame intervals, 0 elsewhere.
class GateSource final : public Source {
public:
    struct Interval { int64_t begin, end; };
    explicit GateSource(std::vector<Interval> loud) : loud_(std::move(loud)) {}

    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        for (uint32_t f = 0; f < ctx.numFrames; ++f, ++pos_) {
            float y = 0;
            for (const Interval& i : loud_)
                if (pos_ >= i.begin && pos_ < i.end) y = 0.5f;
            for (uint32_t c = 0; c < io.audioOut.numChannels; ++c) io.audioOut.channels[c][f] = y;
        }
    }

private:
    std::vector<Interval> loud_;
    int64_t pos_ = 0;
};

// Seeded white noise in [−amp, amp), independent per channel (xorshift64).
class NoiseSource final : public Source {
public:
    NoiseSource(uint64_t seed, float amplitude) : state_(seed), amp_(amplitude) {}

    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < ctx.numFrames; ++f) {
                state_ ^= state_ << 13;
                state_ ^= state_ >> 7;
                state_ ^= state_ << 17;
                const float u = static_cast<float>(state_ >> 40) * 0x1.0p-24f;  // [0, 1)
                io.audioOut.channels[c][f] = amp_ * (2 * u - 1);
            }
    }

private:
    uint64_t state_;
    float amp_;
};

// out = in; silence where there is no input.
class Mix final : public Node {
public:
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < ctx.numFrames; ++f)
                io.audioOut.channels[c][f] = c < io.audioIn.numChannels ? io.audioIn.channels[c][f] : 0.0f;
    }
};

// IO-013: whether every block it processed ran inside the RT trap's scope.
class RtContextProbe final : public Source {
public:
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        ++processes;
        // Test-only: inRealtimeContext reads a thread-local and is RT-safe, but isn't declared
        // nonblocking.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
        allInRtContext = allInRtContext && RtTrap::inRealtimeContext();
#pragma clang diagnostic pop
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            std::memset(io.audioOut.channels[c], 0, ctx.numFrames * sizeof(float));
    }
    uint64_t processes = 0;
    bool allInRtContext = true;
};

// IO-013, TEST-004 AllocatingNode: malloc + free in every process() (deliberate violation;
// only RtTrapTests renders it).
class AllocatingSource final : public Source {
public:
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
        (void)runProbe(RtProbe::malloc);
#pragma clang diagnostic pop
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            std::memset(io.audioOut.channels[c], 0, ctx.numFrames * sizeof(float));
    }
};

// TIME-008, IO-011: a stand-in for a clip player. Reads the transport and keeps state across
// blocks: a one-pole smoother over a sawtooth of the timeline position, so its output depends
// on both where it plays and what it played before. reset() clears the state. Also records how
// the transport looked while it played.
class TimelineSource final : public Source {
public:
    void reset() DAW_RT override {
        state_ = 0;
        expectNext_ = -1;
        ++resets;
    }

    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        if (ctx.numFrames == 0) return;
        const TransportBlock& t = ctx.transport;
        if (!t.playing || t.numSegments == 0) {
            ++stoppedBlocks;
            for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
                for (uint32_t f = 0; f < ctx.numFrames; ++f) io.audioOut.channels[c][f] = 0;
            return;
        }
        if (expectNext_ < 0) firstSample = t.seg[0].startSample;
        for (uint8_t s = 0; s < t.numSegments; ++s) {
            const TransportSegment& seg = t.seg[s];
            if (seg.afterWrap) ++wraps;
            if (expectNext_ >= 0 && seg.startSample != expectNext_) contiguous = false;
            expectNext_ = seg.startSample + seg.numFrames;
            for (uint32_t f = 0; f < seg.numFrames; ++f) {
                const SamplePos pos = seg.startSample + f;
                state_ += 0.001 * (static_cast<double>(pos % 4800) / 4800.0 - state_);
                const auto y = static_cast<float>(state_);
                for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
                    io.audioOut.channels[c][seg.frameOffset + f] = y;
            }
        }
    }

    // Read by the test thread after rendering, which is the render thread here.
    uint64_t resets = 0, stoppedBlocks = 0, wraps = 0;
    SamplePos firstSample = -1;  // first position played since the last reset
    bool contiguous = true;      // every segment since the last reset continued the previous one

private:
    double state_ = 0;
    SamplePos expectNext_ = -1;
};

// MARK: Harness

// How a test graph is built. The graph renders at the map's rate (TIME-003).
struct GraphOptions {
    TempoMap tempo;                 // default: 120 bpm, 4/4, 48 kHz
    uint32_t maxBlock = kMaxBlock;
    bool timelineSources = false;   // TIME-008: flag the sources resetOnLocate, like clip players
};

// Publishes sources → (Mix →) master on `engine`, all stereo. Returns false if the graph is
// rejected.
bool publish(Engine& engine, std::vector<std::unique_ptr<Node>> sources, const GraphOptions& options = {}) {
    const auto n = static_cast<uint32_t>(sources.size());
    const double rate = options.tempo.sampleRate();
    const PrepareInfo info{rate, options.maxBlock, 2, 2};
    RenderGraphDesc desc;
    desc.sampleRate = rate;
    desc.maxBlock = options.maxBlock;
    desc.tempo = options.tempo;
    const uint32_t numBuffers = n == 1 ? 1 : n + 2;
    desc.buffers = std::move(AudioBufferPool::create(numBuffers, 2, options.maxBlock)).value();
    NodeID id = 1;
    for (uint32_t i = 0; i < n; ++i) {
        auto node = engine.nodes().put(id++, std::move(sources[i]), info);
        if (!node) return false;
        RenderStepDesc step;
        step.node = std::move(node).value();
        step.output = i;
        step.resetOnLocate = options.timelineSources;
        // MIX-004 push: each source feeds the Mix input (buffer n), the first one copying.
        if (n > 1) step.feeds.push_back({n, i > 0});
        desc.steps.push_back(std::move(step));
    }
    desc.master = 0;
    if (n > 1) {
        auto mix = engine.nodes().put(id++, std::make_unique<Mix>(), info);
        if (!mix) return false;
        RenderStepDesc step;
        step.node = std::move(mix).value();
        step.input = {n};
        step.output = n + 1;
        desc.steps.push_back(std::move(step));
        desc.master = n + 1;
    }
    auto graph = RenderGraph::create(std::move(desc));
    if (!graph) return false;
    engine.publish(std::move(graph).value());
    return true;
}

template <class T>
bool publishOne(Engine& engine, std::unique_ptr<T> node, const GraphOptions& options = {}) {
    std::vector<std::unique_ptr<Node>> sources;
    sources.push_back(std::move(node));
    return publish(engine, std::move(sources), options);
}

// Applies queued transport commands with a 0-frame block, as the device's next block would.
void applyTransportCommands(Engine& engine) {
    float l[16] = {}, r[16] = {};
    float* channels[2] = {l, r};
    RenderTarget target{AudioBufferView{channels, 2, 16}, AudioBufferView{}};
    engine.render(target, 0);
}

// Renders `blocks` blocks of 512 frames from the test thread, standing in for device playback.
void renderBlocks(Engine& engine, int blocks) {
    std::vector<float> l(512), r(512);
    float* channels[2] = {l.data(), r.data()};
    RenderTarget target{AudioBufferView{channels, 2, 512}, AudioBufferView{}};
    for (int i = 0; i < blocks; ++i) engine.render(target, 512);
}

// What a freshly reset TimelineSource plays from `start` for `frames` frames, replayed with the
// same arithmetic.
std::vector<float> timelineReference(SamplePos start, int64_t frames) {
    std::vector<float> out(static_cast<size_t>(frames));
    double state = 0;
    for (int64_t i = 0; i < frames; ++i) {
        const SamplePos pos = start + i;
        state += 0.001 * (static_cast<double>(pos % 4800) / 4800.0 - state);
        out[static_cast<size_t>(i)] = static_cast<float>(state);
    }
    return out;
}

ExportSpec exportSpec(const std::filesystem::path& file, AudioFileType type, AudioSampleFormat sample) {
    ExportSpec spec;
    spec.file = file;
    spec.fileType = type;
    spec.sampleFormat = sample;
    return spec;
}

// Collects what the driver hands its sink.
struct Capture {
    Channels channels;
    uint64_t calls = 0;

    OfflineBlockSink sink() {
        return [this](const AudioBufferView& block) {
            ++calls;
            channels.resize(block.numChannels);
            for (uint32_t c = 0; c < block.numChannels; ++c)
                channels[c].insert(channels[c].end(), block.channels[c], block.channels[c] + block.numFrames);
        };
    }
    int64_t frames() const { return channels.empty() ? 0 : static_cast<int64_t>(channels[0].size()); }
};

bool sameBits(const Channels& a, const Channels& b) {
    if (a.size() != b.size()) return false;
    for (size_t c = 0; c < a.size(); ++c)
        if (a[c].size() != b[c].size() ||
            std::memcmp(a[c].data(), b[c].data(), a[c].size() * sizeof(float)) != 0)
            return false;
    return true;
}

// IO-012: the frame at which the default-shaped tail of a DecaySource ends. Replays the node's
// float recurrence and returns (first quiet frame) + quietFrames.
int64_t decayTailEnd(double dbPerSecond, double thresholdDb, int64_t quietFrames) {
    const float k = DecaySource::decayFactor(dbPerSecond);
    const double below = std::pow(10.0, thresholdDb / 20.0);
    float a = 1.0f;
    int64_t n = 0;
    while (!(std::fabs(static_cast<double>(a)) < below)) {
        a *= k;
        ++n;
    }
    return n + quietFrames;
}

} // namespace

// MARK: IO-010

CheckResult offlineRendersRange() {
    CheckResult checks;
    TempDir dir;
    Engine engine;
    auto counter = std::make_unique<CounterSource>();
    CounterSource* probe = counter.get();
    DAW_CHECK(publishOne(engine, std::move(counter)));

    ExportSpec spec = exportSpec(dir.path() / "range.wav", AudioFileType::wav, AudioSampleFormat::float32);
    spec.blockSize = 700;
    spec.tail.enabled = false;
    Capture capture;
    spec.sink = capture.sink();
    std::vector<OfflineProgress> progress;

    // Beats 2…10 at 120 bpm: 4 s.
    OfflineDriver driver;
    const Result<void> rendered = driver.render(engine, kPPQ, 9 * kPPQ, spec,
                                                [&](const OfflineProgress& p) { progress.push_back(p); });
    DAW_CHECK(rendered.ok());
    const OfflineRenderStats& stats = driver.lastRender();
    constexpr int64_t kFrames = 192000;
    DAW_CHECK(stats.rangeFrames == kFrames);
    DAW_CHECK(stats.framesWritten == kFrames);
    DAW_CHECK(stats.tailFrames == 0);
    DAW_CHECK(stats.tailEnd == TailEnd::none);
    DAW_CHECK(stats.blocks == (kFrames + 699) / 700);
    DAW_CHECK(stats.rtViolations == 0);
    DAW_CHECK(stats.clippedSamples == 0);
    DAW_CHECK(stats.renderSeconds > 0);

    // Every Engine::render call had the fixed size.
    // Every audio block had the fixed size; the two 0-frame blocks only settle the transport.
    DAW_CHECK(probe->processes == stats.blocks);
    DAW_CHECK(probe->minFrames == 700 && probe->maxFrames == 700);
    DAW_CHECK(probe->emptyBlocks == 2);

    // Progress after every block, ending at the total.
    DAW_CHECK(progress.size() == stats.blocks);
    bool monotonic = true;
    for (size_t i = 1; i < progress.size(); ++i)
        monotonic = monotonic && progress[i].framesRendered > progress[i - 1].framesRendered;
    DAW_CHECK(monotonic);
    DAW_CHECK(!progress.empty() && progress.back().framesRendered == kFrames &&
              progress.back().rangeFrames == kFrames && progress.back().maxFrames == kFrames);

    // The sink saw exactly what the graph produced, cut at the range end.
    DAW_CHECK(capture.calls == stats.blocks);
    DAW_CHECK(capture.frames() == kFrames);
    bool exact = capture.channels.size() == 2;
    for (uint32_t c = 0; exact && c < 2; ++c)
        for (int64_t i = 0; exact && i < kFrames; ++i)
            exact = capture.channels[c][static_cast<size_t>(i)] == static_cast<float>(i) + 0.5f * static_cast<float>(c);
    DAW_CHECK(exact);

    // And so does the file.
    Result<FileInfo> info = readFileInfo(spec.file);
    DAW_CHECK(info.ok() && info->fileType == kAudioFileWAVEType && info->frames == kFrames &&
              info->sampleRate == kRate && info->channels == 2 && info->bitsPerChannel == 32);
    Result<Channels> back = readBack(spec.file, kRate);
    DAW_CHECK(back.ok() && sameBits(*back, capture.channels));
    return checks;
}

CheckResult offlineTempoMapRange() {
    CheckResult checks;
    Result<TempoMap> map = TempoMap::make({{0, 120.0}, {2 * kPPQ, 90.0}, {4 * kPPQ, 150.0}}, {{0, 4, 4}}, 44100);
    DAW_CHECK(map.ok());
    if (!map) return checks;

    TempDir dir;
    Engine engine;
    DAW_CHECK(publishOne(engine, std::make_unique<SineSource>(1000, 0.25), {.tempo = *map}));
    ExportSpec spec = exportSpec(dir.path() / "tempo.aif", AudioFileType::aiff, AudioSampleFormat::int24);
    spec.tempo = *map;
    spec.tail.enabled = false;
    const Tick from = kPPQ, to = 5 * kPPQ + 123;
    const int64_t expected = map->tickToSample(to) - map->tickToSample(from);

    OfflineDriver driver;
    DAW_CHECK(driver.render(engine, from, to, spec, nullptr).ok());
    DAW_CHECK(driver.lastRender().rangeFrames == expected);
    DAW_CHECK(driver.lastRender().framesWritten == expected);
    DAW_CHECK(driver.lastRender().rtViolations == 0);
    Result<FileInfo> info = readFileInfo(spec.file);
    DAW_CHECK(info.ok() && info->fileType == kAudioFileAIFFType && info->sampleRate == 44100 &&
              info->frames == expected && info->bitsPerChannel == 24);
    return checks;
}

CheckResult offlineErrors() {
    CheckResult checks;
    TempDir dir;
    Engine engine;
    DAW_CHECK(publishOne(engine, std::make_unique<SineSource>(1000, 0.25)));
    OfflineDriver driver;
    Capture capture;

    auto rejects = [&](Tick from, Tick to, const ExportSpec& spec, ErrorCode code) {
        const Result<void> r = driver.render(engine, from, to, spec, nullptr);
        return !r.ok() && r.error().code == code && driver.lastRender().blocks == 0 &&
               !std::filesystem::exists(spec.file);
    };
    const ExportSpec good = [&] {
        ExportSpec s = exportSpec(dir.path() / "e.wav", AudioFileType::wav, AudioSampleFormat::int16);
        s.sink = capture.sink();
        return s;
    }();

    DAW_CHECK(rejects(kPPQ, 0, good, ErrorCode::invalidArgument));
    ExportSpec bad = good;
    bad.blockSize = 0;
    DAW_CHECK(rejects(0, kPPQ, bad, ErrorCode::invalidArgument));
    bad.blockSize = kMaxBlock + 1;
    DAW_CHECK(rejects(0, kPPQ, bad, ErrorCode::invalidArgument));
    bad = good;
    bad.numChannels = 0;
    DAW_CHECK(rejects(0, kPPQ, bad, ErrorCode::invalidArgument));
    bad.numChannels = kMaxFileChannels + 1;
    DAW_CHECK(rejects(0, kPPQ, bad, ErrorCode::invalidArgument));
    bad = good;
    bad.tail.quietSeconds = std::nan("");
    DAW_CHECK(rejects(0, kPPQ, bad, ErrorCode::invalidArgument));
    bad.tail.quietSeconds = 1;
    bad.tail.maxSeconds = -1;
    DAW_CHECK(rejects(0, kPPQ, bad, ErrorCode::invalidArgument));
    bad.tail.maxSeconds = 1;
    bad.tail.thresholdDb = std::nan("");
    DAW_CHECK(rejects(0, kPPQ, bad, ErrorCode::invalidArgument));
    bad = good;
    bad.file = dir.path() / "missing" / "e.wav";
    DAW_CHECK(rejects(0, kPPQ, bad, ErrorCode::io));
    DAW_CHECK(capture.calls == 0);

    // A disabled tail's settings aren't looked at.
    ExportSpec ignored = good;
    ignored.tail.enabled = false;
    ignored.tail.maxSeconds = std::nan("");
    DAW_CHECK(driver.render(engine, 0, kPPQ, ignored, nullptr).ok());
    DAW_CHECK(driver.lastRender().framesWritten == 24000);

    // An empty range without a tail renders nothing and leaves an empty, valid file.
    ExportSpec empty = good;
    empty.tail.enabled = false;
    DAW_CHECK(driver.render(engine, kPPQ, kPPQ, empty, nullptr).ok());
    DAW_CHECK(driver.lastRender().blocks == 0 && driver.lastRender().framesWritten == 0);
    Result<FileInfo> info = readFileInfo(empty.file);
    DAW_CHECK(info.ok() && info->frames == 0);
    return checks;
}

// MARK: IO-010 with the transport (TIME-004, TIME-008)

CheckResult offlineFollowsTransport() {
    CheckResult checks;
    Engine engine;
    auto node = std::make_unique<TimelineSource>();
    TimelineSource* probe = node.get();
    DAW_CHECK(publishOne(engine, std::move(node), {.timelineSources = true}));

    // The session state the export must leave alone: stopped at beat 5, a loop over beat 4
    // (inside the export range), 64 frames of output latency.
    Transport& transport = engine.transport();
    DAW_CHECK(transport.setLoop(true, 3 * kPPQ, 4 * kPPQ) && transport.locate(4 * kPPQ));
    transport.setOutputLatency(64);
    applyTransportCommands(engine);

    // Beats 3…7: 48000 ..< 144000, across the loop end at 96000.
    ExportSpec spec;
    spec.tail.enabled = false;
    Capture capture;
    spec.sink = capture.sink();
    OfflineDriver driver;
    DAW_CHECK(driver.render(engine, 2 * kPPQ, 6 * kPPQ, spec, nullptr).ok());
    DAW_CHECK(driver.lastRender().framesWritten == 96000);
    DAW_CHECK(driver.lastRender().rtViolations == 0);

    // It played from `from`, straight through (loop off), after one reset, every block playing.
    DAW_CHECK(probe->resets == 1);
    DAW_CHECK(probe->firstSample == 48000);
    DAW_CHECK(probe->contiguous);
    DAW_CHECK(probe->wraps == 0);
    DAW_CHECK(probe->stoppedBlocks == 0);
    // Exactly what a freshly reset node plays from 48000.
    const std::vector<float> expected = timelineReference(48000, 96000);
    DAW_CHECK(capture.channels.size() == 2 && capture.channels[0] == expected && capture.channels[1] == expected);

    // Afterwards the transport is as it was, already applied when render() returns.
    const TransportPlayhead after = transport.playhead();
    DAW_CHECK(!after.playing);
    DAW_CHECK(after.tick == 4 * kPPQ);
    DAW_CHECK(after.loopEnabled && after.loopStart == 3 * kPPQ && after.loopEnd == 4 * kPPQ);
    DAW_CHECK(transport.outputLatency() == 64);
    return checks;
}

CheckResult offlineFollowsLoop() {
    CheckResult checks;
    Engine engine;
    auto node = std::make_unique<TimelineSource>();
    TimelineSource* probe = node.get();
    DAW_CHECK(publishOne(engine, std::move(node), {.timelineSources = true}));

    // A loop over beat 4 (72000 ..< 96000), stopped at beat 5, as in offlineFollowsTransport.
    Transport& transport = engine.transport();
    DAW_CHECK(transport.setLoop(true, 3 * kPPQ, 4 * kPPQ) && transport.locate(4 * kPPQ));
    applyTransportCommands(engine);

    // 96000 frames from beat 3: 48000 ..< 96000, then the loop twice. The first wrap is at
    // frame 48000, inside block 93 (47616 ..< 48128).
    ExportSpec spec;
    spec.tail.enabled = false;
    spec.followLoop = true;
    Capture capture;
    spec.sink = capture.sink();
    OfflineDriver driver;
    DAW_CHECK(driver.render(engine, 2 * kPPQ, 6 * kPPQ, spec, nullptr).ok());
    DAW_CHECK(driver.lastRender().framesWritten == 96000);
    DAW_CHECK(driver.lastRender().rtViolations == 0);
    DAW_CHECK(probe->resets == 1);
    DAW_CHECK(probe->firstSample == 48000);
    // Wraps at export frames 48000 and 72000, and a third at 96000 inside the last block, which
    // is rendered in full and cut (IO-010).
    DAW_CHECK(probe->wraps == 3);
    DAW_CHECK(!probe->contiguous);

    // What a freshly reset node plays along those positions.
    std::vector<float> expected(96000);
    double state = 0;
    for (int64_t i = 0; i < 96000; ++i) {
        const SamplePos pos = i < 48000 ? 48000 + i : 72000 + (i - 48000) % 24000;
        state += 0.001 * (static_cast<double>(pos % 4800) / 4800.0 - state);
        expected[static_cast<size_t>(i)] = static_cast<float>(state);
    }
    DAW_CHECK(capture.channels.size() == 2 && capture.channels[0] == expected && capture.channels[1] == expected);

    // Restored as before: stopped at beat 5, the loop unchanged.
    const TransportPlayhead after = transport.playhead();
    DAW_CHECK(!after.playing && after.tick == 4 * kPPQ);
    DAW_CHECK(after.loopEnabled && after.loopStart == 3 * kPPQ && after.loopEnd == 4 * kPPQ);

    // DW-125: a loop of 100 frames (ticks 0..4) in 512-frame blocks wraps five or six times in
    // each block, and every frame plays the loop (no gap). The playhead check follows that.
    DAW_CHECK(transport.setLoop(true, 0, 4));
    applyTransportCommands(engine);
    ExportSpec shortLoop;
    shortLoop.tail.enabled = false;
    shortLoop.followLoop = true;
    Capture looped;
    shortLoop.sink = looped.sink();
    const uint64_t resetsBefore = probe->resets;
    DAW_CHECK(driver.render(engine, 0, 2 * kPPQ, shortLoop, nullptr).ok());
    DAW_CHECK(driver.lastRender().framesWritten == 48000);
    DAW_CHECK(driver.lastRender().rtViolations == 0);
    DAW_CHECK(probe->resets == resetsBefore + 1);
    {
        std::vector<float> expectedLoop(48000);
        double state = 0;
        for (int64_t i = 0; i < 48000; ++i) {
            const SamplePos pos = i % 100;
            state += 0.001 * (static_cast<double>(pos % 4800) / 4800.0 - state);
            expectedLoop[static_cast<size_t>(i)] = static_cast<float>(state);
        }
        DAW_CHECK(looped.channels.size() == 2 && looped.channels[0] == expectedLoop);
    }

    // With the loop off, followLoop changes nothing: same bits as the default render.
    DAW_CHECK(transport.setLoop(false, 0, 4));
    applyTransportCommands(engine);
    Capture plain, following;
    ExportSpec a;
    a.tail.enabled = false;
    a.sink = plain.sink();
    ExportSpec b = a;
    b.followLoop = true;
    b.sink = following.sink();
    DAW_CHECK(driver.render(engine, 2 * kPPQ, 6 * kPPQ, a, nullptr).ok());
    DAW_CHECK(driver.render(engine, 2 * kPPQ, 6 * kPPQ, b, nullptr).ok());
    DAW_CHECK(plain.frames() == 96000 && sameBits(plain.channels, following.channels));
    return checks;
}

CheckResult offlineRepeatableOnOneEngine() {
    CheckResult checks;
    TempDir dir;
    for (const bool timeline : {true, false}) {
        Engine engine;
        auto node = std::make_unique<TimelineSource>();
        TimelineSource* probe = node.get();
        DAW_CHECK(publishOne(engine, std::move(node), {.timelineSources = timeline}));

        auto exportOnce = [&](const std::string& name, Channels& sink) {
            ExportSpec spec = exportSpec(dir.path() / name, AudioFileType::wav, AudioSampleFormat::float32);
            spec.tail.enabled = false;
            Capture capture;
            spec.sink = capture.sink();
            OfflineDriver driver;
            const bool ok = driver.render(engine, kPPQ, 5 * kPPQ, spec, nullptr).ok() &&
                            driver.lastRender().rtViolations == 0;
            sink = std::move(capture.channels);
            return ok ? fileBytes(spec.file) : std::vector<char>{};
        };

        Channels first, second;
        const std::vector<char> a = exportOnce(timeline ? "t1.wav" : "n1.wav", first);
        // Playback between the renders leaves the node somewhere else entirely.
        DAW_CHECK(engine.transport().locate(20 * kPPQ) && engine.transport().play());
        renderBlocks(engine, 30);
        DAW_CHECK(engine.transport().stop());
        const std::vector<char> b = exportOnce(timeline ? "t2.wav" : "n2.wav", second);
        DAW_CHECK(!a.empty() && !b.empty());
        DAW_CHECK(!first.empty() && !second.empty());

        // IO-011, DW-063 (T-089): every render resets every node first, timeline node or not
        // (once each), so both renders are bit-identical whatever played in between. The
        // playback between them didn't reset the non-timeline node (TIME-008: a live locate
        // resets timeline nodes only), so its state really was elsewhere.
        DAW_CHECK(probe->resets == 2);
        DAW_CHECK(a == b);
        DAW_CHECK(sameBits(first, second));
    }
    return checks;
}

CheckResult offlineTransportMismatch() {
    CheckResult checks;
    TempDir dir;
    // Fails, removes the file and still restores the transport (stopped at 0).
    auto fails = [&](Engine& engine, const ExportSpec& spec, uint64_t blocks) {
        OfflineDriver driver;
        const Result<void> r = driver.render(engine, 0, 2 * kOneSecond, spec, nullptr);
        return !r.ok() && r.error().code == ErrorCode::invalidArgument &&
               driver.lastRender().blocks == blocks && !std::filesystem::exists(spec.file) &&
               !engine.transport().playhead().playing;
    };
    const ExportSpec base = exportSpec(dir.path() / "m.wav", AudioFileType::wav, AudioSampleFormat::int16);

    // The spec's map is at another rate than the graph. From 0, block 0 starts at tick 0 in
    // both; block 1 (512 frames) is tick 20 at 48 kHz but 22 at 44.1 kHz.
    {
        Engine engine;
        DAW_CHECK(publishOne(engine, std::make_unique<SineSource>(440, 0.1)));
        ExportSpec spec = base;
        spec.tempo = std::move(TempoMap::make({{0, 120.0}}, {{0, 4, 4}}, 44100)).value();
        DAW_CHECK(fails(engine, spec, 2));
    }
    // Same rate, another tempo: block 1 is tick 20 at 120 bpm but 17 at 100 bpm.
    {
        Engine engine;
        DAW_CHECK(publishOne(engine, std::make_unique<SineSource>(440, 0.1)));
        ExportSpec spec = base;
        spec.tempo = std::move(TempoMap::make({{0, 100.0}}, {{0, 4, 4}}, kRate)).value();
        DAW_CHECK(fails(engine, spec, 2));
    }
    // Blocks larger than the graph's maxBlock: the engine renders silence, the transport stays.
    {
        Engine engine;
        DAW_CHECK(publishOne(engine, std::make_unique<SineSource>(440, 0.1), {.maxBlock = 256}));
        DAW_CHECK(fails(engine, base, 1));
    }
    // Nothing published.
    {
        Engine engine;
        DAW_CHECK(fails(engine, base, 1));
    }
    return checks;
}

// MARK: IO-011

CheckResult offlineDeterministic() {
    CheckResult checks;
    TempDir dir;

    struct Run {
        std::vector<char> dithered16, float32;
        Channels sink;
        OfflineRenderStats stats;
    };
    // A fresh engine and fresh nodes per run, as in two separate sessions.
    auto runOnce = [&](const std::string& tag) {
        Run run;
        for (AudioSampleFormat sample : {AudioSampleFormat::int16, AudioSampleFormat::float32}) {
            Engine engine;
            std::vector<std::unique_ptr<Node>> sources;
            sources.push_back(std::make_unique<SineSource>(440, 0.3));
            sources.push_back(std::make_unique<NoiseSource>(99, 0.1f));
            sources.push_back(std::make_unique<DecaySource>(20));
            if (!publish(engine, std::move(sources))) return run;

            const bool is16 = sample == AudioSampleFormat::int16;
            ExportSpec spec = exportSpec(dir.path() / (tag + (is16 ? "-i16.wav" : "-f32.wav")),
                                         AudioFileType::wav, sample);
            spec.dither = true;
            spec.tail.maxSeconds = 0.5;
            Capture capture;
            spec.sink = capture.sink();
            OfflineDriver driver;
            if (!driver.render(engine, 0, 2 * kOneSecond, spec, nullptr)) return run;
            (is16 ? run.dithered16 : run.float32) = fileBytes(spec.file);
            if (!is16) {
                run.sink = std::move(capture.channels);
                run.stats = driver.lastRender();
            }
        }
        return run;
    };

    const Run a = runOnce("a");
    const Run b = runOnce("b");
    DAW_CHECK(!a.dithered16.empty() && !a.float32.empty());
    DAW_CHECK(a.stats.framesWritten == 2 * 48000 + 24000);  // the sine never goes quiet
    DAW_CHECK(a.stats.rtViolations == 0 && b.stats.rtViolations == 0);
    DAW_CHECK(a.dithered16 == b.dithered16);
    DAW_CHECK(a.float32 == b.float32);
    DAW_CHECK(!a.sink.empty() && sameBits(a.sink, b.sink));
    return checks;
}

// MARK: IO-012

CheckResult offlineTailQuiet() {
    CheckResult checks;
    struct Case { double thresholdDb, quietSeconds; };
    for (const Case k : {Case{-90.0, 1.0}, Case{-70.0, 0.25}}) {
        Engine engine;
        DAW_CHECK(publishOne(engine, std::make_unique<DecaySource>(60)));  // −70 dB after 1.17 s, −90 dB after 1.5 s
        ExportSpec spec;
        spec.tail.thresholdDb = k.thresholdDb;
        spec.tail.quietSeconds = k.quietSeconds;
        Capture capture;
        spec.sink = capture.sink();

        OfflineDriver driver;
        DAW_CHECK(driver.render(engine, 0, kOneSecond, spec, nullptr).ok());
        const OfflineRenderStats& stats = driver.lastRender();
        const int64_t quietFrames = std::llround(k.quietSeconds * kRate);
        const int64_t end = decayTailEnd(60, k.thresholdDb, quietFrames);
        DAW_CHECK(end > 48000 + quietFrames);  // still loud at the range end
        DAW_CHECK(stats.tailEnd == TailEnd::quiet);
        DAW_CHECK(stats.framesWritten == end);
        DAW_CHECK(stats.tailFrames == end - 48000);
        DAW_CHECK(stats.rtViolations == 0);
        DAW_CHECK(capture.frames() == end);
        if (capture.frames() != end) continue;
        // The last loud frame is exactly quietFrames before the end.
        const double below = std::pow(10.0, k.thresholdDb / 20.0);
        const auto lastLoud = static_cast<size_t>(end - quietFrames - 1);
        DAW_CHECK(std::fabs(capture.channels[0][lastLoud]) >= below);
        DAW_CHECK(std::fabs(capture.channels[0][lastLoud + 1]) < below);
    }
    return checks;
}

CheckResult offlineTailQuietRunResets() {
    CheckResult checks;
    // Loud until 30000, quiet until 60000 (12000 quiet frames after the range end at 48000),
    // loud again until 70000: the tail ends 1 s after that.
    {
        Engine engine;
        DAW_CHECK(publishOne(engine, std::make_unique<GateSource>(
                                         std::vector<GateSource::Interval>{{0, 30000}, {60000, 70000}})));
        OfflineDriver driver;
        DAW_CHECK(driver.render(engine, 0, kOneSecond, ExportSpec{}, nullptr).ok());
        DAW_CHECK(driver.lastRender().tailEnd == TailEnd::quiet);
        DAW_CHECK(driver.lastRender().framesWritten == 70000 + 48000);
    }
    // Silent throughout: quiet frames inside the range don't count.
    {
        Engine engine;
        DAW_CHECK(publishOne(engine, std::make_unique<GateSource>(std::vector<GateSource::Interval>{})));
        OfflineDriver driver;
        DAW_CHECK(driver.render(engine, 0, kOneSecond, ExportSpec{}, nullptr).ok());
        DAW_CHECK(driver.lastRender().tailEnd == TailEnd::quiet);
        DAW_CHECK(driver.lastRender().framesWritten == 48000 + 48000);
        DAW_CHECK(driver.lastRender().rtViolations == 0);
    }
    return checks;
}

CheckResult offlineTailMaxLength() {
    CheckResult checks;
    struct Case { bool enabled; double maxSeconds, quietSeconds; int64_t frames; TailEnd end; };
    for (const Case k : {Case{true, 10.0, 1.0, 48000 + 480000, TailEnd::maxLength},
                         Case{true, 2.5, 1.0, 48000 + 120000, TailEnd::maxLength},
                         Case{true, 2.5, 0.0, 48000, TailEnd::none},
                         Case{false, 10.0, 1.0, 48000, TailEnd::none}}) {
        Engine engine;
        DAW_CHECK(publishOne(engine, std::make_unique<SineSource>(220, 0.01)));  // −40 dBFS, endless
        ExportSpec spec;
        spec.tail.enabled = k.enabled;
        spec.tail.maxSeconds = k.maxSeconds;
        spec.tail.quietSeconds = k.quietSeconds;
        Capture capture;
        spec.sink = capture.sink();
        OfflineDriver driver;
        DAW_CHECK(driver.render(engine, 0, kOneSecond, spec, nullptr).ok());
        DAW_CHECK(driver.lastRender().tailEnd == k.end);
        DAW_CHECK(driver.lastRender().framesWritten == k.frames);
        DAW_CHECK(capture.frames() == k.frames);
        DAW_CHECK(driver.lastRender().rtViolations == 0);
    }
    return checks;
}

// MARK: IO-013

// MARK: T-082 normalize

CheckResult offlineNormalize() {
    CheckResult checks;
    TempDir dir;
    const double target = std::pow(10.0, kNormalizePeakDb / 20.0);
    auto peakOf = [](const Channels& channels) {
        double peak = 0;
        for (const auto& ch : channels)
            for (float x : ch) peak = std::max(peak, std::fabs(static_cast<double>(x)));
        return peak;
    };
    struct Run {
        bool ok = false;
        Channels sink;
        OfflineRenderStats stats;
    };
    // A fresh engine per run: sine + seeded noise, 1 s, a short tail.
    auto render = [&](const std::filesystem::path& file, AudioSampleFormat sample, bool normalize, bool dither,
                      double amplitude) {
        Run run;
        Engine engine;
        std::vector<std::unique_ptr<Node>> sources;
        sources.push_back(std::make_unique<SineSource>(440, 0.3 * amplitude));
        sources.push_back(std::make_unique<NoiseSource>(7, static_cast<float>(0.05 * amplitude)));
        if (!publish(engine, std::move(sources))) return run;
        ExportSpec spec = exportSpec(file, AudioFileType::wav, sample);
        spec.normalize = normalize;
        spec.dither = dither;
        spec.blockSize = 700;  // the last block is cut: pass two must follow the kept frames
        spec.tail.maxSeconds = 0.25;
        Capture capture;
        spec.sink = capture.sink();
        OfflineDriver driver;
        run.ok = driver.render(engine, 0, kOneSecond, spec, nullptr).ok();
        run.sink = std::move(capture.channels);
        run.stats = driver.lastRender();
        return run;
    };

    // Off (the default): the file is what the graph made; the peak is reported, gain 1.
    const Run plain = render(dir.path() / "plain.wav", AudioSampleFormat::float32, false, false, 1);
    DAW_CHECK(plain.ok && plain.stats.rtViolations == 0);
    DAW_CHECK(plain.stats.normalizeGain == 1);
    DAW_CHECK(plain.stats.peak > 0 && plain.stats.peak == peakOf(plain.sink));
    DAW_CHECK(plain.stats.framesWritten == 48000 + 12000);

    // On, float32: every sample is the plain render times one gain, the peak lands on −0.1 dBFS,
    // and the file holds what the sink saw.
    const Run norm = render(dir.path() / "norm.wav", AudioSampleFormat::float32, true, false, 1);
    DAW_CHECK(norm.ok && norm.stats.rtViolations == 0);
    DAW_CHECK(norm.stats.peak == plain.stats.peak);
    DAW_CHECK(std::fabs(norm.stats.normalizeGain - target / plain.stats.peak) < 1e-12);
    DAW_CHECK(norm.stats.framesWritten == plain.stats.framesWritten);
    DAW_CHECK(norm.sink.size() == 2 && norm.sink[0].size() == plain.sink[0].size());
    const float gain = static_cast<float>(norm.stats.normalizeGain);
    bool scaled = norm.sink.size() == plain.sink.size();
    for (size_t c = 0; scaled && c < norm.sink.size(); ++c)
        for (size_t i = 0; scaled && i < norm.sink[c].size(); ++i) scaled = norm.sink[c][i] == plain.sink[c][i] * gain;
    DAW_CHECK(scaled);
    DAW_CHECK(std::fabs(peakOf(norm.sink) - target) < 1e-6);
    auto back = readBack(dir.path() / "norm.wav", kRate);
    DAW_CHECK(back.ok());
    if (back.ok()) {
        DAW_CHECK(sameBits(back.value(), norm.sink));
    }

    // A quiet render is raised as well (gain > 1), still to −0.1 dBFS.
    const Run quiet = render(dir.path() / "quiet.wav", AudioSampleFormat::float32, true, false, 0.1);
    DAW_CHECK(quiet.ok && quiet.stats.normalizeGain > 9);
    DAW_CHECK(std::fabs(peakOf(quiet.sink) - target) < 1e-6);

    // On, int16 with dither: normalized before quantizing, so nothing clips and the file's peak is
    // within dither (±1 LSB) and rounding of the target; two runs give the same bytes (IO-011).
    const Run a16 = render(dir.path() / "a16.wav", AudioSampleFormat::int16, true, true, 1);
    const Run b16 = render(dir.path() / "b16.wav", AudioSampleFormat::int16, true, true, 1);
    DAW_CHECK(a16.ok && b16.ok && a16.stats.clippedSamples == 0);
    DAW_CHECK(fileBytes(dir.path() / "a16.wav") == fileBytes(dir.path() / "b16.wav"));
    auto info = readFileInfo(dir.path() / "a16.wav");
    DAW_CHECK(info.ok() && info.value().bitsPerChannel == 16 && info.value().frames == plain.stats.framesWritten);
    auto back16 = readBack(dir.path() / "a16.wav", kRate);
    DAW_CHECK(back16.ok());
    if (back16.ok()) {
        DAW_CHECK(std::fabs(peakOf(back16.value()) - target) <= 2.5 / 32768.0);
    }

    // Silence stays silence: gain 1, no division by zero.
    const Run silent = render(dir.path() / "silent.wav", AudioSampleFormat::float32, true, false, 0);
    DAW_CHECK(silent.ok && silent.stats.peak == 0 && silent.stats.normalizeGain == 1);
    DAW_CHECK(peakOf(silent.sink) == 0);
    return checks;
}

CheckResult offlineRunsInRtScope() {
    CheckResult checks;
    Engine engine;
    auto node = std::make_unique<RtContextProbe>();
    RtContextProbe* probe = node.get();
    DAW_CHECK(publishOne(engine, std::move(node)));
    ExportSpec spec;
    spec.tail.enabled = false;
    OfflineDriver driver;
    DAW_CHECK(driver.render(engine, 0, kOneSecond, spec, nullptr).ok());
    // + the two 0-frame blocks that settle the transport
    DAW_CHECK(probe->processes == driver.lastRender().blocks + 2 && probe->processes > 2);
#if DAW_RT_TRAP
    DAW_CHECK(probe->allInRtContext);
#else
    DAW_CHECK(!probe->allInRtContext);  // BUILD-005: no trap in Release
#endif
    DAW_CHECK(!RtTrap::inRealtimeContext());  // only during Engine::render
    DAW_CHECK(driver.lastRender().rtViolations == 0);
    return checks;
}

OfflinePerformance offlinePerformance60s() {
    OfflinePerformance result;
    TempDir dir;
    Engine engine;
    std::vector<std::unique_ptr<Node>> sources;
    for (int i = 0; i < 8; ++i) sources.push_back(std::make_unique<SineSource>(110.0 * (i + 1), 0.05));
    if (!publish(engine, std::move(sources))) {
        result.error = "graph rejected";
        return result;
    }
    ExportSpec spec = exportSpec(dir.path() / "perf.wav", AudioFileType::wav, AudioSampleFormat::int24);
    spec.dither = true;
    spec.tail.enabled = false;  // exactly the 60 s range
    OfflineDriver driver;
    const Result<void> rendered = driver.render(engine, 0, 60 * kOneSecond, spec, nullptr);
    if (!rendered) {
        result.error = rendered.error().message;
        return result;
    }
    const OfflineRenderStats& stats = driver.lastRender();
    result.ok = stats.framesWritten == 60 * 48000;
    if (!result.ok) result.error = "wrong length";
    result.audioSeconds = static_cast<double>(stats.framesWritten) / kRate;
    result.renderSeconds = stats.renderSeconds;
    result.rtViolations = stats.rtViolations;
    return result;
}

OfflineTrapCounts offlineCountsAllocatingNode() {
    OfflineTrapCounts result;
    Engine engine;
    if (!publishOne(engine, std::make_unique<AllocatingSource>())) return result;
    ExportSpec spec;
    spec.tail.enabled = false;
    OfflineDriver driver;
    if (!driver.render(engine, 0, kOneSecond / 2, spec, nullptr)) return result;
    result.blocks = driver.lastRender().blocks;
    result.violations = driver.lastRender().rtViolations;

    if (!publishOne(engine, std::make_unique<SineSource>(440, 0.1))) return result;
    if (!driver.render(engine, 0, kOneSecond / 2, spec, nullptr)) return result;
    result.cleanViolations = driver.lastRender().rtViolations;
    result.ok = true;
    return result;
}

} // namespace daw::testing
