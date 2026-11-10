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

// MARK: MidiDelayLine (T-045, MIX-021 for MIDI)

namespace {

constexpr uint8_t kStatusMask = 0xF0;
constexpr uint8_t kNoteOffStatus = 0x80;
constexpr uint8_t kNoteOnStatus = 0x90;
constexpr uint8_t kControlStatus = 0xB0;
constexpr uint8_t kSustainCC = 64;
constexpr uint8_t kAllSoundOffCC = 120;
constexpr uint8_t kResetControllersCC = 121;
constexpr uint8_t kAllNotesOffCC = 123;

} // namespace

MidiDelayLine::MidiDelayLine(uint32_t capacity, uint32_t maxOut)
    : maxOut_(std::max(maxOut, 1u)) {
    const uint32_t cap = nextPowerOfTwo(std::clamp(capacity, 1u, kMaxCapacity));
    mask_ = cap - 1;
    queue_.reset(new Pending[cap]());
    out_.reset(new MidiEvent[maxOut_]());
    held_.reset(new uint16_t[16 * 128]());
}

bool MidiDelayLine::admit(const MidiEvent& e) DAW_RT {
    const uint32_t free = capacity() - count_;
    const uint32_t reserve = numHeld_ + numPedals_;
    if (e.size >= 3) {
        const uint8_t status = e.data[0] & kStatusMask;
        const uint8_t channel = e.data[0] & 0x0F;
        const uint32_t key = uint32_t{channel} * 128 + (e.data[1] & 0x7Fu);
        if (status == kNoteOnStatus && e.data[2] > 0) {
            // Room for this on, its off, and every held note's and pedal's release.
            if (free < reserve + 2) return false;
            ++held_[key];
            ++numHeld_;
            return true;
        }
        if (status == kNoteOffStatus || status == kNoteOnStatus) {  // velocity 0: an off
            if (held_[key] > 0) {  // its slot was reserved when the on went in
                --held_[key];
                --numHeld_;
                return free > 0;
            }
            return free > reserve;
        }
        if (status == kControlStatus) {
            const uint8_t cc = e.data[1];
            if (cc == kSustainCC) {
                const bool down = e.data[2] >= 64;
                if (down && !pedal_[channel]) {
                    if (free < reserve + 2) return false;
                    pedal_[channel] = true;
                    ++numPedals_;
                    return true;
                }
                if (!down && pedal_[channel]) {
                    pedal_[channel] = false;
                    --numPedals_;
                    return free > 0;
                }
            } else if (cc == kAllNotesOffCC || cc == kAllSoundOffCC) {
                // The channel's notes end here (a re-created player sends CC 123 for the notes
                // its predecessor left on, whose offs never come): stop reserving for them.
                for (uint32_t k = 0; k < 128; ++k) {
                    numHeld_ -= held_[std::size_t{channel} * 128 + k];
                    held_[std::size_t{channel} * 128 + k] = 0;
                }
                return free > numHeld_ + numPedals_;
            } else if (cc == kResetControllersCC && pedal_[channel]) {
                pedal_[channel] = false;
                --numPedals_;
                return free > 0;
            }
        }
    }
    return free > reserve;
}

void MidiDelayLine::drain(uint32_t numFrames) DAW_RT {
    // Bounded by maxOut_ (CONV-RT-04). Due frames are in order, so out_ stays in frame order;
    // overdue events (late from an earlier block) go at the earliest frame still allowed.
    const int64_t end = now_ + numFrames;
    while (count_ > 0 && numOut_ < maxOut_) {
        const Pending& p = queue_[head_];
        if (p.due >= end) break;
        MidiEvent e = p.event;
        const int64_t frame = std::max<int64_t>(p.due - now_, lastOutFrame_);
        e.frameOffset = static_cast<uint32_t>(frame);
        lastOutFrame_ = e.frameOffset;
        out_[numOut_++] = e;
        head_ = (head_ + 1) & mask_;
        --count_;
    }
}

MidiEventSpan MidiDelayLine::process(MidiEventSpan in, uint32_t delay, uint32_t numFrames) DAW_RT {
    numOut_ = 0;
    lastOutFrame_ = 0;
    // Drain first so events due now free their slots, queue the input, then drain again: a
    // short delay can put this block's input in this block.
    drain(numFrames);
    uint64_t dropped = 0;
    for (const MidiEvent& e : in) {  // bounded by the upstream writer's capacity
        if (!admit(e)) {
            ++dropped;
            continue;
        }
        const uint32_t frame = numFrames > 0 ? std::min(e.frameOffset, numFrames - 1) : 0;
        const int64_t due = std::max(now_ + frame + delay, lastDue_);
        lastDue_ = due;
        queue_[(head_ + count_) & mask_] = Pending{due, e};
        ++count_;
    }
    drain(numFrames);
    if (dropped > 0) dropped_.fetch_add(dropped, std::memory_order_relaxed);
    now_ += numFrames;
    return MidiEventSpan(out_.get(), numOut_);
}

// MARK: RenderGraph

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

        // T-045: MIDI inputs come from earlier steps; a line serves one input per graph.
        for (const RenderMidiInputDesc& m : s.midiInputs) {
            if (m.fromStep >= i)
                return makeError(ErrorCode::invalidArgument,
                                 "MIDI input from a later step in step " + std::to_string(i));
            if (m.delay > 0 && !m.delayLine)
                return makeError(ErrorCode::invalidArgument,
                                 "delayed MIDI input without a delay line in step " + std::to_string(i));
            if (m.delayLine) {
                if (std::find(graph->midiLines_.begin(), graph->midiLines_.end(), m.delayLine) !=
                    graph->midiLines_.end())
                    return makeError(ErrorCode::invalidArgument,
                                     "MIDI delay line used by two inputs in step " + std::to_string(i));
                graph->midiLines_.push_back(m.delayLine);
            }
        }

        const auto firstFeed = static_cast<uint32_t>(graph->feeds_.size());
        for (const RenderFeedDesc& f : s.feeds)
            graph->feeds_.push_back(Feed{f.buffer, f.add, f.delay, f.delay > 0 ? f.delayLine.get() : nullptr});
        const auto firstMidiInput = static_cast<uint32_t>(graph->midiInputs_.size());
        for (const RenderMidiInputDesc& m : s.midiInputs)
            graph->midiInputs_.push_back(MidiInput{m.fromStep, m.delay, m.delayLine.get()});
        graph->steps_.push_back(Step{s.node.get(), s.input.buffer, s.sidechain.buffer, s.output,
                                     firstFeed, static_cast<uint32_t>(s.feeds.size()),
                                     s.resetOnLocate, s.timeline, nullptr, s.midiCapacity,
                                     firstMidiInput, static_cast<uint32_t>(s.midiInputs.size()),
                                     nullptr, 0});
        graph->owned_.push_back(std::move(s.node));
        // REC-021 (T-054): a monitored step needs an output to swap the input into.
        if (s.monitor) {
            if (s.output == kNoBuffer)
                return makeError(ErrorCode::invalidArgument, "monitored step without an output in step " + std::to_string(i));
            graph->monitors_.push_back(Monitor{static_cast<uint32_t>(i), s.monitor->modeSlot, s.monitor->inputPair,
                                               s.monitor->armed});
        }
    }
    graph->monitorState_.reset(new MonitorState[std::max<std::size_t>(graph->monitors_.size(), 1)]());

    // T-045: lay out every step's MIDI output and merge storage in one allocation. A merge holds
    // everything its inputs can deliver in one block: an upstream writer's capacity, or a delay
    // line's maxOut(), so merging never drops.
    std::size_t midiEvents = 0;
    uint32_t maxFanIn = 0;
    for (Step& step : graph->steps_) {
        midiEvents += step.midiCapacity;
        maxFanIn = std::max(maxFanIn, step.numMidiInputs);
        if (step.numMidiInputs < 2) continue;
        uint64_t merge = 0;
        for (uint32_t j = 0; j < step.numMidiInputs; ++j) {
            const MidiInput& m = graph->midiInputs_[step.firstMidiInput + j];
            merge += m.delayLine ? m.delayLine->maxOut() : graph->steps_[m.fromStep].midiCapacity;
        }
        if (merge > std::numeric_limits<uint32_t>::max())
            return makeError(ErrorCode::invalidArgument, "MIDI merge too large");
        step.mergeCapacity = static_cast<uint32_t>(merge);
        midiEvents += merge;
    }
    if (midiEvents > 0) graph->midiStorage_.reset(new MidiEvent[midiEvents]());
    std::size_t at = 0;
    for (Step& step : graph->steps_) {
        if (step.midiCapacity > 0) step.midiOut = graph->midiStorage_.get() + at;
        at += step.midiCapacity;
        if (step.mergeCapacity > 0) step.midiMerge = graph->midiStorage_.get() + at;
        at += step.mergeCapacity;
    }
    graph->midiSizes_.reset(new uint32_t[std::max<std::size_t>(graph->steps_.size(), 1)]());
    graph->mergeSpans_.reset(new MidiEventSpan[std::max(maxFanIn, 1u)]());
    graph->mergeCursors_.reset(new uint32_t[std::max(maxFanIn, 1u)]());

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

MidiEventSpan RenderGraph::gatherMidi(const Step& step, uint32_t numFrames) const DAW_RT {
    if (step.numMidiInputs == 0) return {};
    // Each input's events for this block: the upstream writer's (it ran earlier in this block),
    // through the edge's delay line when it has one (MIX-021). Every line runs once per block.
    for (uint32_t j = 0; j < step.numMidiInputs; ++j) {
        const MidiInput& m = midiInputs_[step.firstMidiInput + j];
        const Step& from = steps_[m.fromStep];
        MidiEventSpan events(from.midiOut, from.midiOut ? midiSizes_[m.fromStep] : 0);
        if (m.delayLine != nullptr) events = m.delayLine->process(events, m.delay, numFrames);
        mergeSpans_[j] = events;
    }
    if (step.numMidiInputs == 1) return mergeSpans_[0];  // the writer's own span, no copy

    // k-way merge in frame order; on equal frames the earlier input goes first (stable). Each
    // pass emits one event, so it is bounded by mergeCapacity (CONV-RT-04).
    for (uint32_t j = 0; j < step.numMidiInputs; ++j) mergeCursors_[j] = 0;
    uint32_t size = 0;
    while (size < step.mergeCapacity) {
        uint32_t best = step.numMidiInputs;
        for (uint32_t j = 0; j < step.numMidiInputs; ++j) {
            if (mergeCursors_[j] >= mergeSpans_[j].size()) continue;
            if (best == step.numMidiInputs ||
                mergeSpans_[j][mergeCursors_[j]].frameOffset < mergeSpans_[best][mergeCursors_[best]].frameOffset)
                best = j;
        }
        if (best == step.numMidiInputs) break;
        step.midiMerge[size++] = mergeSpans_[best][mergeCursors_[best]++];
    }
    return MidiEventSpan(step.midiMerge, size);
}

MidiEventSpan RenderGraph::midiOutput(uint32_t step) const DAW_RT {
    const Step& s = steps_[step];
    return MidiEventSpan(s.midiOut, s.midiOut ? midiSizes_[step] : 0);
}

void RenderGraph::applyMonitor(uint32_t m, const ProcessContext& ctx, const MonitorInput& in,
                               const AudioBufferView& out, uint32_t numFrames) const DAW_RT {
    const Monitor& monitor = monitors_[m];
    MonitorState& state = monitorState_[m];
    if (!in.enabled) {
        // No device input (an offline render): nothing is monitored, the clips play, and the next
        // block with input starts without a fade.
        state = MonitorState{};
        return;
    }
    // REC-020: the mode from its slot, the transport's own state (not the MIX-023 look-ahead's).
    const MonitoringMode mode = monitoringModeFromSlot(ctx.params.get(monitor.modeSlot));
    const bool active = monitoringActive(mode, monitor.armed, ctx.transport.playing, ctx.transport.recording);
    if (in.input == nullptr) {
        // MIX-023 pre-roll: no input to give and no state to advance; an active step is silent so
        // no clip audio reaches the chain's delay lines.
        if (active)
            for (uint32_t c = 0; c < out.numChannels; ++c)
                std::memset(out.channels[c], 0, std::size_t{numFrames} * sizeof(float));
        return;
    }
    state.active = active;
    const float target = active ? 1.0f : 0.0f;
    if (state.mix < 0.0f) state.mix = target;
    if (state.mix == 0.0f && target == 0.0f) return;  // the clip player's output as it is

    // REC-021: input channels 2·pair, 2·pair + 1 (silence for channels the device doesn't have).
    const AudioBufferView& input = *in.input;
    const float* src[2] = {nullptr, nullptr};
    for (uint32_t c = 0; c < 2; ++c) {
        const uint32_t ch = monitor.inputPair * 2 + c;
        if (ch < input.numChannels && input.numFrames >= numFrames) src[c] = input.channels[ch];
    }
    const uint32_t channels = out.numChannels < 2 ? out.numChannels : 2;  // graph buffers are stereo
    if (state.mix == 1.0f && target == 1.0f) {
        for (uint32_t c = 0; c < channels; ++c) {
            if (src[c] != nullptr)
                std::memcpy(out.channels[c], src[c], std::size_t{numFrames} * sizeof(float));
            else
                std::memset(out.channels[c], 0, std::size_t{numFrames} * sizeof(float));
        }
        return;
    }
    // A switch: a linear crossfade over kMonitorFadeFrames (declick), then the new source.
    constexpr float kStep = 1.0f / static_cast<float>(kMonitorFadeFrames);
    float mix = state.mix;
    for (uint32_t f = 0; f < numFrames; ++f) {
        mix = target > mix ? std::min(target, mix + kStep) : std::max(target, mix - kStep);
        for (uint32_t c = 0; c < channels; ++c) {
            const float x = src[c] != nullptr ? src[c][f] : 0.0f;
            out.channels[c][f] = (1.0f - mix) * out.channels[c][f] + mix * x;
        }
    }
    state.mix = mix;
}

void RenderGraph::process(ProcessContext& ctx, ProcessContext& timeline, const MonitorInput& monitor) const DAW_RT {
    const uint32_t numFrames = ctx.numFrames;
    DAW_RT_ASSERT(numFrames <= maxBlock_ && timeline.numFrames == numFrames);
    uint32_t nextMonitor = 0;  // monitors_ are in step order
    for (uint32_t i = 0; i < steps_.size(); ++i) {
        const Step& step = steps_[i];
        NodeIO io;
        io.audioIn = input(step.input, numFrames);
        io.sidechain = input(step.sidechain, numFrames);  // MIX-008, ENG-003: empty when unrouted
        if (step.output != kNoBuffer) io.audioOut = buffers_.view(step.output, numFrames);
        io.midiIn = gatherMidi(step, numFrames);  // T-045
        if (step.midiOut != nullptr) io.midiOut = MidiEventWriter(step.midiOut, step.midiCapacity);
        step.node->process(step.timeline ? timeline : ctx, io);
        if (step.midiOut != nullptr) midiSizes_[i] = io.midiOut.size();
        if (nextMonitor < monitors_.size() && monitors_[nextMonitor].step == i)
            applyMonitor(nextMonitor++, ctx, monitor, io.audioOut, numFrames);  // REC-021 (T-054)
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
