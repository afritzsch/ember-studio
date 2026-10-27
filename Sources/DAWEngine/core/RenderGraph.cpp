#include "core/RenderGraph.h"

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
    if (port.fed) {
        // Push: the buffer already holds the input; the node reads it while writing its output.
        if (!port.sources.empty())
            return makeError(ErrorCode::invalidArgument,
                             std::string(what) + " is fed but has sources in step " + std::to_string(step));
        if (auto r = checkBuffer(port.buffer, numBuffers, false, what, step); !r) return r;
        if (port.buffer == output)
            return makeError(ErrorCode::invalidArgument,
                             std::string(what) + " buffer is the output in step " + std::to_string(step));
        return {};
    }
    if (port.sources.empty()) return checkBuffer(port.buffer, numBuffers, true, what, step);
    if (auto r = checkBuffer(port.buffer, numBuffers, false, what, step); !r) return r;
    // The gather buffer is cleared before summing, and the node reads it while writing its
    // output, so it can alias neither.
    if (port.buffer == output)
        return makeError(ErrorCode::invalidArgument,
                         std::string(what) + " buffer is the output in step " + std::to_string(step));
    for (uint32_t source : port.sources) {
        if (auto r = checkBuffer(source, numBuffers, false, what, step); !r) return r;
        if (source == port.buffer)
            return makeError(ErrorCode::invalidArgument, std::string(what) +
                                 " source is its own gather buffer in step " + std::to_string(step));
    }
    return {};
}

} // namespace

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
        // A pull port's buffer is cleared before it sums its sources, so it can't share with the
        // other port, nor be one of the sidechain's sources (the main input is gathered first).
        if (!s.sidechain.sources.empty() && s.sidechain.buffer == s.input.buffer)
            return makeError(ErrorCode::invalidArgument,
                             "input and sidechain share a buffer in step " + std::to_string(i));
        if (!s.input.sources.empty())
            for (uint32_t source : s.sidechain.sources)
                if (source == s.input.buffer)
                    return makeError(ErrorCode::invalidArgument,
                                     "input buffer is a sidechain source in step " + std::to_string(i));
        if (!s.feeds.empty() && s.output == kNoBuffer)
            return makeError(ErrorCode::invalidArgument, "feeds without an output in step " + std::to_string(i));
        for (const RenderFeedDesc& f : s.feeds) {
            if (auto r = checkBuffer(f.buffer, numBuffers, false, "feed", i); !r) return r.error();
            // Feeds run after the node, so a feed may reuse the step's (already read) input buffer.
            if (f.buffer == s.output)
                return makeError(ErrorCode::invalidArgument,
                                 "feed into the step's own output in step " + std::to_string(i));
        }

        auto port = [&](const RenderPortDesc& p) {
            Port out{p.buffer, static_cast<uint32_t>(graph->sources_.size()),
                     static_cast<uint32_t>(p.sources.size()), p.fed};
            graph->sources_.insert(graph->sources_.end(), p.sources.begin(), p.sources.end());
            return out;
        };
        const auto firstFeed = static_cast<uint32_t>(graph->feeds_.size());
        graph->feeds_.insert(graph->feeds_.end(), s.feeds.begin(), s.feeds.end());
        graph->steps_.push_back(Step{s.node.get(), port(s.input), port(s.sidechain), s.output,
                                     firstFeed, static_cast<uint32_t>(s.feeds.size()),
                                     s.resetOnLocate});
        graph->owned_.push_back(std::move(s.node));
    }

    graph->sampleRate_ = desc.sampleRate;
    graph->maxBlock_ = desc.maxBlock;
    graph->master_ = desc.master;
    graph->version_ = desc.version;
    graph->buffers_ = std::move(desc.buffers);
    graph->tempo_ = std::move(*tempo);
    return graph;
}

RenderGraph::~RenderGraph() = default;

AudioBufferView RenderGraph::gather(const Port& port, uint32_t numFrames) const DAW_RT {
    if (port.buffer == kNoBuffer) return {};
    if (port.fed) return buffers_.view(port.buffer, numFrames);  // earlier steps filled it
    buffers_.clear(port.buffer, numFrames);
    const AudioBufferView sum = buffers_.view(port.buffer, numFrames);
    // MIX-004: edges into one port are summed. T-021 (MIX-021) delays shorter paths here.
    for (uint32_t i = 0; i < port.numSources; ++i) {
        const AudioBufferView src = buffers_.view(sources_[port.firstSource + i], numFrames);
        const uint32_t channels = src.numChannels < sum.numChannels ? src.numChannels
                                                                    : sum.numChannels;
        for (uint32_t c = 0; c < channels; ++c) {
            float* out = sum.channels[c];
            const float* in = src.channels[c];
            for (uint32_t f = 0; f < numFrames; ++f) out[f] += in[f];
        }
    }
    return sum;
}

void RenderGraph::feed(const Step& step, uint32_t numFrames) const DAW_RT {
    const AudioBufferView src = buffers_.view(step.output, numFrames);
    // MIX-004: the first feed into a buffer copies, the rest add. T-021 (MIX-021) delays here.
    for (uint32_t i = 0; i < step.numFeeds; ++i) {
        const RenderFeedDesc& f = feeds_[step.firstFeed + i];
        const AudioBufferView dst = buffers_.view(f.buffer, numFrames);
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

void RenderGraph::process(ProcessContext& ctx) const DAW_RT {
    const uint32_t numFrames = ctx.numFrames;
    DAW_RT_ASSERT(numFrames <= maxBlock_);
    for (const Step& step : steps_) {
        NodeIO io;
        io.audioIn = gather(step.input, numFrames);
        io.sidechain = gather(step.sidechain, numFrames);
        if (step.output != kNoBuffer) io.audioOut = buffers_.view(step.output, numFrames);
        step.node->process(ctx, io);
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
