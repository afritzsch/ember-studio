#include "core/RenderGraph.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <string>
#include <utility>

#include "core/NodeIO.h"
#include "core/ProcessContext.h"

namespace daw {

namespace {

Result<void> checkBuffer(uint32_t buffer, uint32_t numBuffers, bool optional, const char* what,
                         std::size_t step) {
    if (buffer == kNoBuffer && optional) return {};
    if (buffer < numBuffers) return {};
    return makeError(ErrorCode::invalidArgument,
                     std::string(what) + " buffer out of range in step " + std::to_string(step));
}

Result<void> checkPort(const RenderPortDesc& port, uint32_t numBuffers, uint32_t output,
                       const char* what, std::size_t step) {
    if (auto r = checkBuffer(port.buffer, numBuffers, true, what, step); !r) return r;
    // The node reads its input while it writes its output.
    if (port.buffer != kNoBuffer && port.buffer == output)
        return makeError(ErrorCode::invalidArgument,
                         std::string(what) + " buffer is the output in step " + std::to_string(step));
    return {};
}

uint32_t nextPowerOfTwo(uint64_t n) {
    uint64_t p = 1;
    while (p < n) p <<= 1;
    return static_cast<uint32_t>(p);
}

std::atomic<uint64_t> nextSerial{1};

} // namespace

DelayLine::DelayLine(uint32_t numChannels, uint32_t maxDelay, uint32_t maxBlock)
    : numChannels_(numChannels), maxBlock_(maxBlock) {
    const uint32_t capacity = nextPowerOfTwo(uint64_t{maxDelay} + maxBlock);
    mask_ = capacity - 1;
    samples_.reset(new float[std::size_t{numChannels} * capacity]());
}

void DelayLine::process(const AudioBufferView& in, const AudioBufferView& out, uint32_t delay,
                        bool add, uint32_t numFrames) DAW_RT {
    DAW_RT_ASSERT(delay <= maxDelay() && numFrames <= maxBlock_);
    const uint32_t capacity = mask_ + 1;
    // Write first, then read: capacity >= delay + numFrames, so the frames read are never the
    // ones just overwritten unless they are the input itself (delay < numFrames).
    const uint32_t read = write_ - delay;
    for (uint32_t c = 0; c < out.numChannels; ++c) {
        float* dst = out.channels[c];
        if (c >= numChannels_) {
            if (!add) std::memset(dst, 0, std::size_t{numFrames} * sizeof(float));
            continue;
        }
        float* ring = samples_.get() + std::size_t{c} * capacity;
        const float* src = c < in.numChannels ? in.channels[c] : nullptr;
        for (uint32_t f = 0; f < numFrames; ++f) ring[(write_ + f) & mask_] = src ? src[f] : 0.0f;
        if (add) {
            for (uint32_t f = 0; f < numFrames; ++f) dst[f] += ring[(read + f) & mask_];
        } else {
            for (uint32_t f = 0; f < numFrames; ++f) dst[f] = ring[(read + f) & mask_];
        }
    }
    // Channels `out` lacks still keep their history going.
    for (uint32_t c = out.numChannels; c < numChannels_; ++c) {
        float* ring = samples_.get() + std::size_t{c} * capacity;
        const float* src = c < in.numChannels ? in.channels[c] : nullptr;
        for (uint32_t f = 0; f < numFrames; ++f) ring[(write_ + f) & mask_] = src ? src[f] : 0.0f;
    }
    write_ += numFrames;
}

Result<std::unique_ptr<RenderGraph>> RenderGraph::create(RenderGraphDesc desc) {
    if (!(desc.sampleRate > 0))
        return makeError(ErrorCode::invalidArgument, "sampleRate must be > 0");
    if (desc.maxBlock == 0 || desc.maxBlock > kMaxBlock)
        return makeError(ErrorCode::invalidArgument, "maxBlock must be in 1...kMaxBlock");
    const uint32_t numBuffers = desc.buffers.numBuffers();
    if (numBuffers > 0 && desc.buffers.maxFrames() < desc.maxBlock)
        return makeError(ErrorCode::invalidArgument, "buffers are shorter than maxBlock");
    if (auto r = checkBuffer(desc.master, numBuffers, true, "master", 0); !r) return r.error();
    if (desc.tempo && desc.tempo->sampleRate() != desc.sampleRate)
        return makeError(ErrorCode::invalidArgument, "tempo map is not at the graph's sample rate");
    std::optional<TempoMap> tempo = std::move(desc.tempo);
    if (!tempo) {
        auto made = TempoMap::make({{0, 120.0}}, {{0, 4, 4}}, desc.sampleRate);
        if (!made) return made.error();
        tempo = std::move(made).value();
    }

    std::unique_ptr<RenderGraph> graph(new RenderGraph);
    graph->steps_.reserve(desc.steps.size());
    graph->owned_.reserve(desc.steps.size());
    for (std::size_t i = 0; i < desc.steps.size(); ++i) {
        RenderStepDesc& s = desc.steps[i];
        if (!s.node)
            return makeError(ErrorCode::invalidArgument, "null node in step " + std::to_string(i));
        if (auto r = checkBuffer(s.output, numBuffers, true, "output", i); !r) return r.error();
        if (auto r = checkPort(s.input, numBuffers, s.output, "input", i); !r) return r.error();
        if (auto r = checkPort(s.sidechain, numBuffers, s.output, "sidechain", i); !r)
            return r.error();
        if (!s.feeds.empty() && s.output == kNoBuffer)
            return makeError(ErrorCode::invalidArgument, "feeds without an output in step " + std::to_string(i));
        for (const RenderFeedDesc& f : s.feeds) {
            if (auto r = checkBuffer(f.buffer, numBuffers, false, "feed", i); !r) return r.error();
            // Feeds run after the node, so a feed may reuse the step's (already read) input buffer.
            if (f.buffer == s.output)
                return makeError(ErrorCode::invalidArgument,
                                 "feed into the step's own output in step " + std::to_string(i));
            // MIX-021/022: a delayed feed needs a line long enough, for this graph's blocks, that
            // no other feed of this graph writes.
            if (f.delay > 0) {
                if (!f.delayLine)
                    return makeError(ErrorCode::invalidArgument,
                                     "delayed feed without a delay line in step " + std::to_string(i));
                if (f.delay > f.delayLine->maxDelay() || f.delayLine->maxBlock() < desc.maxBlock)
                    return makeError(ErrorCode::invalidArgument,
                                     "delay line too short in step " + std::to_string(i));
                if (std::find(graph->lines_.begin(), graph->lines_.end(), f.delayLine) != graph->lines_.end())
                    return makeError(ErrorCode::invalidArgument,
                                     "delay line used by two feeds in step " + std::to_string(i));
                graph->lines_.push_back(f.delayLine);
            }
        }

        const auto firstFeed = static_cast<uint32_t>(graph->feeds_.size());
        for (const RenderFeedDesc& f : s.feeds)
            graph->feeds_.push_back(Feed{f.buffer, f.add, f.delay, f.delay > 0 ? f.delayLine.get() : nullptr});
        graph->steps_.push_back(Step{s.node.get(), s.input.buffer, s.sidechain.buffer, s.output,
                                     firstFeed, static_cast<uint32_t>(s.feeds.size()),
                                     s.resetOnLocate, s.timeline});
        graph->owned_.push_back(std::move(s.node));
    }

    graph->sampleRate_ = desc.sampleRate;
    graph->maxBlock_ = desc.maxBlock;
    graph->master_ = desc.master;
    graph->version_ = desc.version;
    graph->serial_ = nextSerial.fetch_add(1, std::memory_order_relaxed);
    graph->latency_ = desc.latency;
    graph->nodeLatencies_ = std::move(desc.nodeLatencies);
    graph->buffers_ = std::move(desc.buffers);
    graph->tempo_ = std::move(*tempo);
    return graph;
}

RenderGraph::~RenderGraph() = default;

AudioBufferView RenderGraph::input(uint32_t buffer, uint32_t numFrames) const DAW_RT {
    if (buffer == kNoBuffer) return {};
    return buffers_.view(buffer, numFrames);  // earlier steps' feeds filled it (MIX-004)
}

void RenderGraph::feed(const Step& step, uint32_t numFrames) const DAW_RT {
    const AudioBufferView src = buffers_.view(step.output, numFrames);
    // MIX-004: the first feed into a buffer copies, the rest add. MIX-021: shorter paths into a
    // merge go through their edge's delay line.
    for (uint32_t i = 0; i < step.numFeeds; ++i) {
        const Feed& f = feeds_[step.firstFeed + i];
        const AudioBufferView dst = buffers_.view(f.buffer, numFrames);
        if (f.delayLine != nullptr) {
            f.delayLine->process(src, dst, f.delay, f.add, numFrames);
            continue;
        }
        for (uint32_t c = 0; c < dst.numChannels; ++c) {
            float* out = dst.channels[c];
            if (c >= src.numChannels) {
                if (!f.add) std::memset(out, 0, std::size_t{numFrames} * sizeof(float));
                continue;
            }
            const float* in = src.channels[c];
            if (f.add) {
                for (uint32_t n = 0; n < numFrames; ++n) out[n] += in[n];
            } else {
                std::memcpy(out, in, std::size_t{numFrames} * sizeof(float));
            }
        }
    }
}

void RenderGraph::process(ProcessContext& ctx, ProcessContext& timeline) const DAW_RT {
    const uint32_t numFrames = ctx.numFrames;
    DAW_RT_ASSERT(numFrames <= maxBlock_ && timeline.numFrames == numFrames);
    for (const Step& step : steps_) {
        NodeIO io;
        io.audioIn = input(step.input, numFrames);
        io.sidechain = input(step.sidechain, numFrames);  // MIX-008, ENG-003: empty when unrouted
        if (step.output != kNoBuffer) io.audioOut = buffers_.view(step.output, numFrames);
        step.node->process(step.timeline ? timeline : ctx, io);
        if (step.numFeeds > 0) feed(step, numFrames);
    }
}

void RenderGraph::resetTimelineNodes() const DAW_RT {
    for (const Step& step : steps_)
        if (step.resetOnLocate) step.node->reset();
}

AudioBufferView RenderGraph::master(uint32_t numFrames) const DAW_RT {
    if (master_ == kNoBuffer) return {};
    return buffers_.view(master_, numFrames);
}

} // namespace daw
