// T-011 checks for the device driver (IO-001..005). Run from
// Tests/DAWEngineTests/DeviceDriverTests.swift; see DeviceDriverChecks.h for why they're C++.

#include "DeviceDriverChecks.h"

#include "core/AudioBufferPool.h"
#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/RenderGraph.h"
#include "core/RtTrap.h"
#include "io/CoreAudioDevice.h"
#include "io/CoreAudioDriver.h"
#include "io/DeviceLatency.h"
#include "io/DeviceRenderer.h"
#include "io/DriverConfig.h"
#include "io/InputFifo.h"
#include "io/WorkgroupJoin.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <memory>
#include <numbers>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace daw::testing {

namespace {

bool envSet(const char* name) {
    const char* value = std::getenv(name);
    return value != nullptr && value[0] != '\0' && value[0] != '0';
}

// MARK: Test nodes (test builds only)

class Source : public Node {
public:
    void prepare(const PrepareInfo& info) override { sampleRate = info.sampleRate; }
    double sampleRate = 0;
};

// Channel c of frame n is n + c / 2: gaps, repeats and channel swaps all show.
class CounterSource final : public Source {
public:
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        if (ctx.numFrames == 0) return;
        minFrames = std::min(minFrames, ctx.numFrames);
        maxFrames = std::max(maxFrames, ctx.numFrames);
        ++processes;
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < ctx.numFrames; ++f)
                io.audioOut.channels[c][f] = static_cast<float>(next_ + f) + 0.5f * static_cast<float>(c);
        next_ += ctx.numFrames;
    }

    // Read by the test thread after rendering on it.
    uint32_t minFrames = kMaxBlock + 1, maxFrames = 0;
    uint64_t processes = 0;

private:
    uint64_t next_ = 0;
};

// A sine by complex rotation (no libm call in the RT body). `frames` is read by the test thread
// while the device's IO thread renders.
class SineSource final : public Source {
public:
    SineSource(double frequency, double amplitude) : frequency_(frequency), im_(amplitude) {}

    void prepare(const PrepareInfo& info) override {
        Source::prepare(info);
        stepRe_ = std::cos(2 * std::numbers::pi * frequency_ / info.sampleRate);
        stepIm_ = std::sin(2 * std::numbers::pi * frequency_ / info.sampleRate);
    }

    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        for (uint32_t f = 0; f < ctx.numFrames; ++f) {
            const float y = static_cast<float>(im_);
            for (uint32_t c = 0; c < io.audioOut.numChannels; ++c) io.audioOut.channels[c][f] = y;
            const double re = re_ * stepRe_ - im_ * stepIm_;
            im_ = re_ * stepIm_ + im_ * stepRe_;
            re_ = re;
        }
        frames.fetch_add(ctx.numFrames, std::memory_order_relaxed);
    }

    std::atomic<uint64_t> frames{0};

private:
    double frequency_;
    double stepRe_ = 1, stepIm_ = 0;
    double re_ = 0, im_;
};

// Publishes source → master (stereo) at `rate`. The map defaults to 120 bpm at that rate.
bool publishSource(Engine& engine, std::unique_ptr<Node> source, double rate, uint32_t maxBlock) {
    const PrepareInfo info{rate, maxBlock, 2, 2};
    RenderGraphDesc desc;
    desc.sampleRate = rate;
    desc.maxBlock = maxBlock;
    desc.buffers = std::move(AudioBufferPool::create(1, 2, maxBlock)).value();
    auto node = engine.nodes().put(1, std::move(source), info);
    if (!node) return false;
    RenderStepDesc step;
    step.node = std::move(node).value();
    step.output = 0;
    desc.steps.push_back(std::move(step));
    desc.master = 0;
    auto graph = RenderGraph::create(std::move(desc));
    if (!graph) return false;
    engine.publish(std::move(graph).value());
    return true;
}

// Non-interleaved device buffers filled with a sentinel, so untouched samples show.
struct DeviceBuffers {
    static constexpr float kSentinel = 9999.0f;
    DeviceBuffers(uint32_t channels, uint32_t frames)
        : data(channels, std::vector<float>(frames, kSentinel)), pointers(channels) {
        for (uint32_t c = 0; c < channels; ++c) pointers[c] = data[c].data();
    }
    std::vector<std::vector<float>> data;
    std::vector<float*> pointers;
};

DeviceCaps builtInLikeCaps() {
    DeviceCaps caps;
    caps.nominalRate = 48000;
    caps.rates = {{44100, 44100}, {48000, 48000}, {96000, 96000}};
    caps.minBufferFrames = 15;
    caps.maxBufferFrames = 4096;
    caps.channels = 2;
    return caps;
}

// MARK: Fake os_workgroup (IO-002)

namespace fakewg {
std::atomic<int> joinResult{0};
std::atomic<int> joins{0}, leaves{0}, releases{0};
std::atomic<uint64_t> thread{1};
std::atomic<void*> joinToken{nullptr}, leaveToken{nullptr};
std::atomic<uint64_t> leaveThread{0};

int join(void*, void* token) DAW_RT {
    joins.fetch_add(1, std::memory_order_relaxed);
    joinToken.store(token, std::memory_order_relaxed);
    return joinResult.load(std::memory_order_relaxed);
}
void leave(void*, void* token) DAW_RT {
    leaves.fetch_add(1, std::memory_order_relaxed);
    leaveToken.store(token, std::memory_order_relaxed);
    leaveThread.store(thread.load(std::memory_order_relaxed), std::memory_order_relaxed);
}
uint64_t threadId() DAW_RT { return thread.load(std::memory_order_relaxed); }
void release(void*) { releases.fetch_add(1, std::memory_order_relaxed); }

WorkgroupOps ops() {
    joinResult = 0;
    joins = 0;
    leaves = 0;
    releases = 0;
    thread = 1;
    WorkgroupOps o;
    o.join = &join;
    o.leave = &leave;
    o.threadId = &threadId;
    o.release = &release;
    return o;
}
} // namespace fakewg

} // namespace

// MARK: - Device-independent checks

CheckResult driverConfigResolves() {
    CheckResult checks;
    const DeviceCaps caps = builtInLikeCaps();

    // IO-003 defaults: buffer 256, rate = the device's nominal rate.
    DriverConfig config;
    DAW_CHECK(config.bufferFrames == 256);
    DAW_CHECK(config.sampleRate == 0);
    auto r = resolveConfig(config.sampleRate, config.bufferFrames, config.outputChannels, caps);
    DAW_CHECK(r.ok() && r->sampleRate == 48000 && r->bufferFrames == 256 && r->channels == 2);

    // Explicit session rates the device supports.
    for (double rate : {44100.0, 96000.0}) {
        auto e = resolveConfig(rate, 256, 2, caps);
        DAW_CHECK(e.ok() && e->sampleRate == rate);
    }
    // A session rate the device lacks, and rates that aren't session rates.
    auto unsupported = resolveConfig(88200, 256, 2, caps);
    DAW_CHECK(!unsupported.ok() && unsupported.error().code == ErrorCode::unsupported);
    for (double rate : {22050.0, 192000.0, 47999.0}) {
        auto bad = resolveConfig(rate, 256, 2, caps);
        DAW_CHECK(!bad.ok() && bad.error().code == ErrorCode::invalidArgument);
    }

    // Nominal rate outside the session rates: the first fallback the device supports.
    DeviceCaps odd = caps;
    odd.nominalRate = 192000;
    odd.rates = {{44100, 192000}};  // a continuous range
    auto fallback = resolveConfig(0, 256, 2, odd);
    DAW_CHECK(fallback.ok() && fallback->sampleRate == 48000);
    odd.rates = {{44100, 44100}, {192000, 192000}};
    fallback = resolveConfig(0, 256, 2, odd);
    DAW_CHECK(fallback.ok() && fallback->sampleRate == 44100);
    odd.rates = {{192000, 192000}};
    fallback = resolveConfig(0, 256, 2, odd);
    DAW_CHECK(!fallback.ok() && fallback.error().code == ErrorCode::unsupported);
    // A device that lists no rates supports its nominal rate only.
    DeviceCaps unlisted = caps;
    unlisted.rates.clear();
    DAW_CHECK(resolveConfig(48000, 256, 2, unlisted).ok());
    DAW_CHECK(!resolveConfig(44100, 256, 2, unlisted).ok());

    // IO-003 buffer range 32…2048 (both ends accepted), then the device's own range.
    for (uint32_t frames : {32u, 64u, 2048u}) {
        auto ok = resolveConfig(0, frames, 2, caps);
        DAW_CHECK(ok.ok() && ok->bufferFrames == frames);
    }
    for (uint32_t frames : {0u, 31u, 2049u, 4096u}) {
        auto bad = resolveConfig(0, frames, 2, caps);
        DAW_CHECK(!bad.ok() && bad.error().code == ErrorCode::invalidArgument);
    }
    DeviceCaps bluetooth = caps;
    bluetooth.minBufferFrames = 512;
    bluetooth.maxBufferFrames = 1024;
    auto clamped = resolveConfig(0, 128, 2, bluetooth);
    DAW_CHECK(clamped.ok() && clamped->bufferFrames == 512);
    clamped = resolveConfig(0, 2048, 2, bluetooth);
    DAW_CHECK(clamped.ok() && clamped->bufferFrames == 1024);

    // Channels: at most what the device has (and kMaxDeviceChannels); none is an error.
    auto mono = resolveConfig(0, 256, 8, DeviceCaps{48000, {{48000, 48000}}, 32, 4096, 1});
    DAW_CHECK(mono.ok() && mono->channels == 1);
    auto wide = resolveConfig(0, 256, 64, DeviceCaps{48000, {{48000, 48000}}, 32, 4096, 64});
    DAW_CHECK(wide.ok() && wide->channels == kMaxDeviceChannels);
    auto none = resolveConfig(0, 256, 2, DeviceCaps{48000, {{48000, 48000}}, 32, 4096, 0});
    DAW_CHECK(!none.ok() && none.error().code == ErrorCode::unsupported);
    auto zero = resolveConfig(0, 256, 0, caps);
    DAW_CHECK(!zero.ok() && zero.error().code == ErrorCode::invalidArgument);
    return checks;
}

CheckResult inputDeviceChoice() {
    CheckResult checks;
    const AudioDeviceRef out = 10, in = 20;
    DAW_CHECK(chooseInputDevice(out, 7, out, 7) == out);   // same device
    DAW_CHECK(chooseInputDevice(out, 7, 0, 0) == out);     // none requested
    DAW_CHECK(chooseInputDevice(out, 7, in, 7) == in);     // shared clock
    DAW_CHECK(chooseInputDevice(out, 7, in, 8) == out);    // different clocks
    DAW_CHECK(chooseInputDevice(out, 0, in, 0) == out);    // unknown clocks aren't shared
    DAW_CHECK(chooseInputDevice(out, 7, in, 0) == out);
    return checks;
}

CheckResult deviceLatencyMathAndPublish() {
    CheckResult checks;
    // IO-005: device + safety offset + buffer + stream.
    DAW_CHECK(totalLatency({}) == 0);
    DAW_CHECK(totalLatency({24, 16, 8, 256}) == 304);
    DAW_CHECK(totalLatency({0, 0, 0, 512}) == 512);
    const uint32_t big = std::numeric_limits<uint32_t>::max();
    DAW_CHECK(totalLatency({big, big, big, big}) == big);  // saturates instead of wrapping

    Engine engine;
    DAW_CHECK(engine.telemetry().snapshot().deviceOutputLatency == 0);
    publishDeviceLatency(engine, DeviceLatency{100, 304});
    const TelemetrySnapshot s = engine.telemetry().snapshot();
    DAW_CHECK(s.deviceOutputLatency == 304);  // DW-049
    DAW_CHECK(s.outputLatency == 304 + s.graphLatency);
    DAW_CHECK(engine.transport().outputLatency() == 304);  // DW-059
    publishDeviceLatency(engine, DeviceLatency{});
    DAW_CHECK(engine.telemetry().snapshot().deviceOutputLatency == 0);
    DAW_CHECK(engine.transport().outputLatency() == 0);
    return checks;
}

CheckResult deviceRendererBlocks() {
    CheckResult checks;
    Engine engine;
    auto owned = std::make_unique<CounterSource>();
    CounterSource* counter = owned.get();
    DAW_CHECK(publishSource(engine, std::move(owned), 48000, 256));

    DeviceRenderer renderer(engine);
    renderer.configure(0);
    DAW_CHECK(renderer.maxBlock() == 1);
    renderer.configure(kMaxBlock + 1);
    DAW_CHECK(renderer.maxBlock() == kMaxBlock);
    renderer.configure(256);

    // 4 device channels (the master has 2) and 2 input channels.
    DeviceBuffers out(4, 1024), in(2, 1024);
    uint64_t violations = 0;
    {
        RtScope scope;
        renderer.renderCycle(out.pointers.data(), 4, in.pointers.data(), 2, 512);
        violations = scope.violations();
    }
    DAW_CHECK(violations == 0);
    DAW_CHECK(counter->processes == 2 && counter->minFrames == 256 && counter->maxFrames == 256);
    bool contiguous = true, extraSilent = true;
    for (uint32_t f = 0; f < 512; ++f) {
        contiguous = contiguous && out.data[0][f] == static_cast<float>(f) &&
                     out.data[1][f] == static_cast<float>(f) + 0.5f;
        extraSilent = extraSilent && out.data[2][f] == 0.0f && out.data[3][f] == 0.0f;
    }
    DAW_CHECK(contiguous);
    DAW_CHECK(extraSilent);
    DAW_CHECK(out.data[0][512] == DeviceBuffers::kSentinel);  // nothing past the cycle

    // An uneven cycle: 256 + 44, continuing the counter.
    DeviceBuffers out2(2, 300);
    {
        RtScope scope;
        renderer.renderCycle(out2.pointers.data(), 2, nullptr, 0, 300);
        renderer.renderCycle(out2.pointers.data(), 2, nullptr, 0, 0);  // empty cycle
        violations = scope.violations();
    }
    DAW_CHECK(violations == 0);
    DAW_CHECK(counter->processes == 4 && counter->minFrames == 44);
    DAW_CHECK(out2.data[0][0] == 512.0f && out2.data[0][299] == 811.0f);
    DAW_CHECK(renderer.cycles() == 3);
    DAW_CHECK(renderer.frames() == 812);
    DAW_CHECK(renderer.blocks() == 4);
    DAW_CHECK(renderer.largestCycle() == 512);

    // Channels beyond kMaxDeviceChannels are cleared, not rendered.
    DeviceBuffers wide(kMaxDeviceChannels + 2, 64);
    {
        RtScope scope;
        renderer.renderCycle(wide.pointers.data(), kMaxDeviceChannels + 2, nullptr, 0, 64);
        violations = scope.violations();
    }
    DAW_CHECK(violations == 0);
    DAW_CHECK(wide.data[0][0] == 812.0f);
    DAW_CHECK(wide.data[kMaxDeviceChannels - 1][63] == 0.0f);
    DAW_CHECK(wide.data[kMaxDeviceChannels][0] == 0.0f && wide.data[kMaxDeviceChannels + 1][63] == 0.0f);

    // Blocks above the graph's maxBlock render silence and are counted (ENG-015, DW-037): the
    // published graph must be prepared for the driver's buffer size.
    renderer.configure(512);
    DeviceBuffers big(2, 512);
    renderer.renderCycle(big.pointers.data(), 2, nullptr, 0, 512);
    DAW_CHECK(big.data[0][0] == 0.0f && big.data[0][511] == 0.0f);
    DAW_CHECK(engine.telemetry().snapshot().oversizeBlocks == 1);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    return checks;
}

CheckResult inputFifoBasics() {
    CheckResult checks;
    InputFifo fifo;
    DAW_CHECK(!fifo.configure(0, 128).ok());
    DAW_CHECK(!fifo.configure(kMaxDeviceChannels + 1, 128).ok());
    DAW_CHECK(!fifo.configure(2, 0).ok());
    DAW_CHECK(fifo.configure(2, 100).ok());
    DAW_CHECK(fifo.capacity() == 128 && fifo.channels() == 2);

    // Source: ch0 = n, ch1 = −n for frame n of the stream.
    uint32_t next = 0;
    auto writeRamp = [&](uint32_t frames, uint32_t channels = 2) {
        std::vector<float> a(frames), b(frames);
        for (uint32_t i = 0; i < frames; ++i) {
            a[i] = static_cast<float>(next + i);
            b[i] = -static_cast<float>(next + i);
        }
        const float* src[2] = {a.data(), b.data()};
        const uint32_t written = fifo.write(src, channels, frames);
        next += written;
        return written;
    };
    auto pullCheck = [&](uint32_t frames, uint32_t backlog, uint32_t firstExpected, uint32_t dest = 2) {
        DeviceBuffers out(dest, frames);
        const uint32_t got = fifo.pull(out.pointers.data(), dest, frames, backlog);
        bool ok = got == frames;
        for (uint32_t i = 0; i < frames && ok; ++i) {
            ok = out.data[0][i] == static_cast<float>(firstExpected + i);
            if (dest > 1) ok = ok && out.data[1][i] == -static_cast<float>(firstExpected + i);
            for (uint32_t c = 2; c < dest; ++c) ok = ok && out.data[c][i] == 0.0f;
        }
        return ok;
    };

    DAW_CHECK(writeRamp(100) == 100);
    DAW_CHECK(fifo.available() == 100);
    DAW_CHECK(pullCheck(64, 1000, 0));
    DAW_CHECK(fifo.available() == 36);
    // Full: only 92 of 100 fit; the rest is counted as overflow.
    DAW_CHECK(writeRamp(100) == 92);
    DAW_CHECK(fifo.overflowFrames() == 8);
    DAW_CHECK(fifo.available() == 128);
    DAW_CHECK(pullCheck(64, 1000, 64));  // across the wrap
    // Underrun: too little input clears the cycle, reads nothing and is counted.
    {
        DeviceBuffers out(2, 100);
        DAW_CHECK(fifo.pull(out.pointers.data(), 2, 100, 1000) == 0);
        DAW_CHECK(out.data[0][0] == 0.0f && out.data[1][99] == 0.0f);
        DAW_CHECK(fifo.underruns() == 1);
        DAW_CHECK(fifo.available() == 64);
    }
    // Backlog: 64 available, 16 wanted, 8 allowed beyond → the oldest 40 are dropped.
    DAW_CHECK(pullCheck(16, 8, 168));
    DAW_CHECK(fifo.droppedFrames() == 40);
    DAW_CHECK(fifo.available() == 8);
    DAW_CHECK(pullCheck(8, 0, 184));

    // Fewer source channels than the FIFO's are written as silence; extra dest channels too.
    fifo.reset();
    DAW_CHECK(fifo.available() == 0);
    next = 500;
    DAW_CHECK(writeRamp(10, 1) == 10);
    DeviceBuffers out(3, 10);
    DAW_CHECK(fifo.pull(out.pointers.data(), 3, 10, 0) == 10);
    DAW_CHECK(out.data[0][0] == 500.0f && out.data[0][9] == 509.0f);
    DAW_CHECK(out.data[1][0] == 0.0f && out.data[2][9] == 0.0f);
    return checks;
}

CheckResult inputFifoTwoThreads() {
    CheckResult checks;
    InputFifo fifo;
    DAW_CHECK(fifo.configure(2, 1024).ok());
    constexpr uint32_t kTotal = 200000;  // exact in float
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);

    std::atomic<uint64_t> producerViolations{0};
    std::thread producer([&] {
        std::vector<float> a(512), b(512);
        const float* src[2] = {a.data(), b.data()};
        const uint32_t chunks[] = {37, 128, 5, 256, 64, 1};
        uint32_t sent = 0, k = 0;
        RtScope scope;
        while (sent < kTotal && std::chrono::steady_clock::now() < deadline) {
            const uint32_t n = std::min(chunks[k++ % 6], kTotal - sent);
            for (uint32_t i = 0; i < n; ++i) {
                a[i] = static_cast<float>(sent + i);
                b[i] = -static_cast<float>(sent + i);
            }
            uint32_t done = 0;
            while (done < n && std::chrono::steady_clock::now() < deadline) {
                const float* part[2] = {src[0] + done, src[1] + done};
                done += fifo.write(part, 2, n - done);
            }
            sent += done;
        }
        producerViolations = scope.violations();
    });

    uint32_t received = 0;
    bool inOrder = true;
    uint64_t consumerViolations = 0;
    {
        std::vector<float> a(64), b(64);
        float* dest[2] = {a.data(), b.data()};
        RtScope scope;
        while (received < kTotal && std::chrono::steady_clock::now() < deadline) {
            const uint32_t n = std::min(64u, kTotal - received);
            if (fifo.pull(dest, 2, n, 1u << 30) == 0) continue;  // the producer hasn't caught up
            for (uint32_t i = 0; i < n; ++i)
                inOrder = inOrder && a[i] == static_cast<float>(received + i) &&
                          b[i] == -static_cast<float>(received + i);
            received += n;
        }
        consumerViolations = scope.violations();
    }
    producer.join();
    DAW_CHECK(received == kTotal);
    DAW_CHECK(inOrder);
    // The producer retries what didn't fit (counted as overflow, which a device can't retry), so
    // nothing is lost; the consumer allows any backlog, so nothing is dropped.
    DAW_CHECK(fifo.droppedFrames() == 0);
    DAW_CHECK(producerViolations == 0);
    DAW_CHECK(consumerViolations == 0);
    return checks;
}

CheckResult workgroupBookkeeping() {
    CheckResult checks;
    void* const wg1 = reinterpret_cast<void*>(0x1000);
    void* const wg2 = reinterpret_cast<void*>(0x2000);
    void* const wg3 = reinterpret_cast<void*>(0x3000);
    void* const wg4 = reinterpret_cast<void*>(0x4000);
    uint64_t violations = 0;
    // Each IO cycle runs inside an RtScope, as on the device's IO thread.
    auto cycle = [&](WorkgroupJoin& w) {
        RtScope scope;
        const bool render = w.onCycle();
        violations += scope.violations();
        return render;
    };

    // The real ops are all there.
    const WorkgroupOps system = systemWorkgroupOps();
    DAW_CHECK(system.join != nullptr && system.leave != nullptr && system.threadId != nullptr &&
              system.release != nullptr);
    DAW_CHECK(system.threadId() != 0);

    {
        WorkgroupJoin w(fakewg::ops());
        // No workgroup: cycles render, nothing is joined.
        DAW_CHECK(w.state() == WorkgroupState::none);
        DAW_CHECK(cycle(w));
        DAW_CHECK(fakewg::joins == 0);

        // The first cycle joins; later cycles on the same thread don't.
        w.attach(wg1);
        DAW_CHECK(w.state() == WorkgroupState::pending);
        DAW_CHECK(cycle(w));
        DAW_CHECK(w.state() == WorkgroupState::joined);
        DAW_CHECK(fakewg::joins == 1 && w.joinAttempts() == 1 && w.lastJoinResult() == 0);
        for (int i = 0; i < 5; ++i) DAW_CHECK(cycle(w));
        DAW_CHECK(fakewg::joins == 1);

        // The HAL moved IO to a new thread: join again from there.
        fakewg::thread = 2;
        DAW_CHECK(cycle(w));
        DAW_CHECK(fakewg::joins == 2 && w.abandonedJoins() == 1);
        DAW_CHECK(w.state() == WorkgroupState::joined);

        // stop(): the next cycle leaves, from the joining thread, with the join's token, and
        // from then on cycles don't render.
        w.requestLeave();
        DAW_CHECK(!w.leaveDone());
        DAW_CHECK(!cycle(w));
        DAW_CHECK(w.leaveDone());
        DAW_CHECK(fakewg::leaves == 1);
        DAW_CHECK(fakewg::leaveThread == 2);
        DAW_CHECK(fakewg::leaveToken.load() == fakewg::joinToken.load());
        DAW_CHECK(w.state() == WorkgroupState::left);
        DAW_CHECK(!cycle(w));
        DAW_CHECK(fakewg::leaves == 1);

        // A restart attaches again (releasing the old reference). EALREADY: the IO thread was
        // already a member, so there is nothing to leave.
        w.attach(wg2);
        DAW_CHECK(fakewg::releases == 1);
        DAW_CHECK(!w.leaveDone() && w.state() == WorkgroupState::pending);
        fakewg::joinResult = EALREADY;
        DAW_CHECK(cycle(w));
        DAW_CHECK(w.state() == WorkgroupState::alreadyMember && w.lastJoinResult() == EALREADY);
        w.requestLeave();
        DAW_CHECK(!cycle(w));
        DAW_CHECK(fakewg::leaves == 1 && w.leaveDone() && w.state() == WorkgroupState::left);

        // A failed join is recorded; cycles still render and don't retry on the same thread.
        w.attach(wg3);
        fakewg::joinResult = EINVAL;
        const int joinsBefore = fakewg::joins;
        DAW_CHECK(cycle(w) && cycle(w));
        DAW_CHECK(w.state() == WorkgroupState::failed && w.lastJoinResult() == EINVAL);
        DAW_CHECK(fakewg::joins == joinsBefore + 1);

        // A leave requested after the IO thread changed can't leave the old thread's join.
        w.attach(wg4);
        fakewg::joinResult = 0;
        fakewg::thread = 5;
        DAW_CHECK(cycle(w));
        fakewg::thread = 6;
        const uint32_t abandonedBefore = w.abandonedJoins();
        w.requestLeave();
        DAW_CHECK(!cycle(w));
        DAW_CHECK(fakewg::leaves == 1 && w.abandonedJoins() == abandonedBefore + 1);
        DAW_CHECK(w.state() == WorkgroupState::left);

        // Detaching releases; a leave request with no workgroup completes at once.
        w.attach(nullptr);
        DAW_CHECK(fakewg::releases == 4);
        w.requestLeave();
        DAW_CHECK(!cycle(w) && w.leaveDone() && w.state() == WorkgroupState::none);

        w.attach(wg1);
    }
    DAW_CHECK(fakewg::releases == 5);  // the destructor released the last one
    DAW_CHECK(violations == 0);
    return checks;
}

// MARK: - Device checks

bool hasDefaultOutputDevice() {
    if (envSet("DAW_SKIP_DEVICE_TESTS")) return false;
    auto device = CoreAudioDevice::defaultDevice(DeviceDirection::output);
    return device.ok() && device->isAlive() && device->channels(DeviceDirection::output) > 0;
}

namespace {

const char* stateName(WorkgroupState state) {
    switch (state) {
    case WorkgroupState::none: return "none";
    case WorkgroupState::pending: return "pending";
    case WorkgroupState::joined: return "joined";
    case WorkgroupState::alreadyMember: return "alreadyMember";
    case WorkgroupState::failed: return "failed";
    case WorkgroupState::left: return "left";
    }
    return "?";
}

// Waits until `done()` or `seconds` pass. Returns done().
template <class Done>
bool waitFor(double seconds, Done done) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    while (!done() && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    return done();
}

void failWith(CheckResult& checks, const Error& error, int line) {
    const std::string what = "driver error: " + error.message;
    checks.fail(what.c_str(), __FILE__, line);
}

} // namespace

DeviceRunReport coreAudioPlaysSine() {
    DeviceRunReport report;
    if (!hasDefaultOutputDevice()) {
        report.skipped = true;
        return report;
    }
    CheckResult& checks = report.checks;
    const bool audible = envSet("DAW_AUDIBLE_DEVICE_TEST");

    Engine engine;
    CoreAudioDriver driver(engine);
    DAW_CHECK(!driver.running());

    // IO-003: an out-of-range request fails without starting anything.
    DriverConfig bad;
    bad.bufferFrames = 16;
    auto rejected = driver.start(bad);
    DAW_CHECK(!rejected.ok() && rejected.error().code == ErrorCode::invalidArgument);
    DAW_CHECK(!driver.running());

    auto started = driver.start(DriverConfig{});
    if (!started) {
        failWith(checks, started.error(), __LINE__);
        return report;
    }
    DAW_CHECK(driver.running());
    const RunningConfig config = driver.current();
    const CoreAudioDevice device(config.outputDevice);
    report.device = device.name();
    report.sampleRate = config.sampleRate;
    report.bufferFrames = config.bufferFrames;

    // IO-003: the device runs at the resolved rate and buffer size.
    DAW_CHECK(isSessionRate(config.sampleRate));
    DAW_CHECK(device.nominalRate().valueOr(0.0) == config.sampleRate);
    DAW_CHECK(device.bufferFrames().valueOr(0u) == config.bufferFrames);
    DAW_CHECK(config.outputChannels >= 1 && config.outputChannels <= 2);
    DAW_CHECK(config.inputDevice == 0 && config.inputChannels == 0);  // input not enabled
    auto again = driver.start(DriverConfig{});
    DAW_CHECK(!again.ok() && again.error().code == ErrorCode::invalidArgument);

    // IO-001: a sine through the engine. Graphs must cover the buffer size; kMaxBlock does.
    auto owned = std::make_unique<SineSource>(440.0, audible ? 0.1 : 1e-4);
    SineSource* sine = owned.get();
    DAW_CHECK(publishSource(engine, std::move(owned), config.sampleRate, kMaxBlock));
    const double seconds = audible ? 1.0 : 0.3;
    const auto wanted = static_cast<uint64_t>(seconds * config.sampleRate);
    DAW_CHECK(waitFor(seconds + 3.0, [&] { return sine->frames.load() >= wanted; }));

    const DeviceRenderer& renderer = driver.renderer();
    report.cycles = renderer.cycles();
    report.blocks = renderer.blocks();
    report.framesProcessed = sine->frames.load();
    DAW_CHECK(report.cycles > 0);
    DAW_CHECK(report.blocks >= report.cycles);
    DAW_CHECK(renderer.maxBlock() == config.bufferFrames);

    // IO-002: the IO thread is in the device's workgroup.
    const WorkgroupJoin& workgroup = driver.workgroup();
    report.joinResult = workgroup.lastJoinResult();
    report.workgroupState = stateName(workgroup.state());
    DAW_CHECK(workgroup.state() == WorkgroupState::joined ||
              workgroup.state() == WorkgroupState::alreadyMember);
    DAW_CHECK(workgroup.joinAttempts() >= 1);

    // IO-005: latency from the properties, published to telemetry and the transport.
    const DeviceLatency latency = driver.latency();
    report.inputLatency = latency.input;
    report.outputLatency = latency.output;
    auto components = device.latency(DeviceDirection::output);
    DAW_CHECK(components.ok());
    if (components.ok()) DAW_CHECK(latency.output == totalLatency(*components));
    DAW_CHECK(latency.output >= config.bufferFrames);
    DAW_CHECK(latency.input == 0);
    const TelemetrySnapshot telemetry = engine.telemetry().snapshot();
    DAW_CHECK(telemetry.deviceOutputLatency == latency.output);
    DAW_CHECK(engine.transport().outputLatency() == latency.output);
    report.rtViolations = telemetry.rtViolations;
    report.xruns = telemetry.xruns;
    DAW_CHECK(telemetry.rtViolations == 0);
    DAW_CHECK(driver.overloads() == telemetry.xruns);  // the only xrun producer here

    // stop(): the IO thread leaves the workgroup and rendering ends.
    driver.stop();
    report.stateAfterStop = stateName(workgroup.state());
    DAW_CHECK(workgroup.state() == WorkgroupState::left);
    DAW_CHECK(workgroup.leaveDone());
    DAW_CHECK(!driver.running());
    DAW_CHECK(driver.latency().output == 0);
    const uint64_t framesAtStop = sine->frames.load();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    DAW_CHECK(sine->frames.load() == framesAtStop);
    driver.stop();  // idempotent

    // And it starts again.
    auto restarted = driver.start(DriverConfig{});
    if (!restarted) {
        failWith(checks, restarted.error(), __LINE__);
        return report;
    }
    DAW_CHECK(waitFor(3.0, [&] { return sine->frames.load() > framesAtStop + 1024; }));
    DAW_CHECK(driver.workgroup().state() == WorkgroupState::joined ||
              driver.workgroup().state() == WorkgroupState::alreadyMember);
    driver.stop();
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    return report;
}

DeviceRunReport coreAudioDuplexInput() {
    DeviceRunReport report;
    if (!envSet("DAW_DEVICE_INPUT_TESTS") || envSet("DAW_SKIP_DEVICE_TESTS")) {
        report.skipped = true;
        return report;
    }
    // A device with both directions; BlackHole loops its output back to its input.
    std::optional<CoreAudioDevice> duplex;
    for (const CoreAudioDevice& d : CoreAudioDevice::allDevices()) {
        if (d.channels(DeviceDirection::input) == 0 || d.channels(DeviceDirection::output) == 0)
            continue;
        if (!duplex || d.name().find("BlackHole") != std::string::npos) duplex = d;
    }
    if (!duplex) {
        report.skipped = true;
        return report;
    }
    CheckResult& checks = report.checks;
    report.device = duplex->name();

    Engine engine;
    CoreAudioDriver driver(engine);
    DriverConfig config;
    config.outputDevice = duplex->id();
    config.inputDevice = duplex->id();
    config.inputEnabled = true;
    auto started = driver.start(config);
    if (!started) {
        failWith(checks, started.error(), __LINE__);
        return report;
    }
    const RunningConfig running = driver.current();
    report.sampleRate = running.sampleRate;
    report.bufferFrames = running.bufferFrames;
    DAW_CHECK(running.inputDevice == duplex->id());
    DAW_CHECK(!running.separateInput);
    DAW_CHECK(running.inputChannels >= 1);

    auto owned = std::make_unique<SineSource>(440.0, 0.1);
    SineSource* sine = owned.get();
    DAW_CHECK(publishSource(engine, std::move(owned), running.sampleRate, kMaxBlock));
    DAW_CHECK(waitFor(3.0, [&] { return sine->frames.load() >= running.sampleRate * 0.3; }));

    report.cycles = driver.renderer().cycles();
    report.blocks = driver.renderer().blocks();
    report.framesProcessed = sine->frames.load();
    report.joinResult = driver.workgroup().lastJoinResult();
    report.workgroupState = stateName(driver.workgroup().state());
    DAW_CHECK(driver.inputErrors() == 0);  // AudioUnitRender pulled input every cycle

    // IO-005: input latency from the input-scope properties.
    const DeviceLatency latency = driver.latency();
    report.inputLatency = latency.input;
    report.outputLatency = latency.output;
    auto components = duplex->latency(DeviceDirection::input);
    DAW_CHECK(components.ok());
    if (components.ok()) DAW_CHECK(latency.input == totalLatency(*components));
    DAW_CHECK(latency.input >= running.bufferFrames);

    report.rtViolations = engine.telemetry().snapshot().rtViolations;
    DAW_CHECK(report.rtViolations == 0);
    driver.stop();
    report.stateAfterStop = stateName(driver.workgroup().state());
    return report;
}

DeviceRunReport coreAudioDefaultInput() {
    DeviceRunReport report;
    auto out = CoreAudioDevice::defaultDevice(DeviceDirection::output);
    auto in = CoreAudioDevice::defaultDevice(DeviceDirection::input);
    if (!envSet("DAW_DEVICE_INPUT_TESTS") || !hasDefaultOutputDevice() || !in.ok() ||
        in->channels(DeviceDirection::input) == 0) {
        report.skipped = true;
        return report;
    }
    CheckResult& checks = report.checks;
    report.device = out->name() + " / " + in->name();
    const bool expectSeparate = in->id() != out->id() && out->clockDomain() != 0 &&
                                out->clockDomain() == in->clockDomain();

    Engine engine;
    CoreAudioDriver driver(engine);
    DriverConfig config;
    config.inputEnabled = true;  // both devices default
    auto started = driver.start(config);
    if (!started) {
        failWith(checks, started.error(), __LINE__);
        return report;
    }
    const RunningConfig running = driver.current();
    report.sampleRate = running.sampleRate;
    report.bufferFrames = running.bufferFrames;
    report.separateInput = running.separateInput;
    DAW_CHECK(running.separateInput == expectSeparate);
    if (expectSeparate) {
        DAW_CHECK(running.inputDevice == in->id());
        DAW_CHECK(in->nominalRate().valueOr(0.0) == running.sampleRate);  // IO-003 on both
    } else {
        // IO-004: input = output device, or none if it has no input.
        DAW_CHECK(running.inputDevice == out->id() || running.inputDevice == 0);
    }

    auto owned = std::make_unique<SineSource>(440.0, 1e-4);
    SineSource* sine = owned.get();
    DAW_CHECK(publishSource(engine, std::move(owned), running.sampleRate, kMaxBlock));
    DAW_CHECK(waitFor(3.0, [&] { return sine->frames.load() >= running.sampleRate * 0.5; }));

    report.cycles = driver.renderer().cycles();
    report.blocks = driver.renderer().blocks();
    report.framesProcessed = sine->frames.load();
    report.joinResult = driver.workgroup().lastJoinResult();
    report.workgroupState = stateName(driver.workgroup().state());
    report.fifoUnderruns = driver.inputFifo().underruns();
    report.fifoDropped = driver.inputFifo().droppedFrames();
    DAW_CHECK(driver.inputErrors() == 0);
    if (expectSeparate) {
        DAW_CHECK(driver.inputFifo().overflowFrames() == 0);
        // One clock: after the first cycles line up, nothing is dropped or missing.
        DAW_CHECK(report.fifoUnderruns <= 4);
        DAW_CHECK(report.fifoDropped <= 4 * running.bufferFrames);
    }

    const DeviceLatency latency = driver.latency();
    report.inputLatency = latency.input;
    report.outputLatency = latency.output;
    if (running.inputDevice != 0) {
        auto components = CoreAudioDevice(running.inputDevice).latency(DeviceDirection::input);
        DAW_CHECK(components.ok());
        if (components.ok()) DAW_CHECK(latency.input == totalLatency(*components));
    }
    report.rtViolations = engine.telemetry().snapshot().rtViolations;
    DAW_CHECK(report.rtViolations == 0);
    driver.stop();
    report.stateAfterStop = stateName(driver.workgroup().state());
    return report;
}

} // namespace daw::testing
