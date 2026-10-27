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
constexpr PrepareInfo kInfo{kRate, kMaxBlock, 2, 2};
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
    uint64_t processes = 0;

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

// MARK: Harness

// Publishes sources → (Mix →) master on `engine`, all stereo. Returns false if the graph is
// rejected.
bool publish(Engine& engine, std::vector<std::unique_ptr<Node>> sources) {
    const auto n = static_cast<uint32_t>(sources.size());
    RenderGraphDesc desc;
    desc.sampleRate = kRate;
    desc.maxBlock = kMaxBlock;
    const uint32_t numBuffers = n == 1 ? 1 : n + 2;
    desc.buffers = std::move(AudioBufferPool::create(numBuffers, 2, kMaxBlock)).value();
    NodeID id = 1;
    std::vector<uint32_t> inputs;
    for (uint32_t i = 0; i < n; ++i) {
        auto node = engine.nodes().put(id++, std::move(sources[i]), kInfo);
        if (!node) return false;
        RenderStepDesc step;
        step.node = std::move(node).value();
        step.output = i;
        desc.steps.push_back(std::move(step));
        inputs.push_back(i);
    }
    desc.master = 0;
    if (n > 1) {
        auto mix = engine.nodes().put(id++, std::make_unique<Mix>(), kInfo);
        if (!mix) return false;
        RenderStepDesc step;
        step.node = std::move(mix).value();
        step.input = {inputs, n};
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
bool publishOne(Engine& engine, std::unique_ptr<T> node) {
    std::vector<std::unique_ptr<Node>> sources;
    sources.push_back(std::move(node));
    return publish(engine, std::move(sources));
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
    DAW_CHECK(probe->processes == stats.blocks);
    DAW_CHECK(probe->minFrames == 700 && probe->maxFrames == 700);

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
    DAW_CHECK(publishOne(engine, std::make_unique<SineSource>(1000, 0.25)));
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
    DAW_CHECK(probe->processes == driver.lastRender().blocks && probe->processes > 0);
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
