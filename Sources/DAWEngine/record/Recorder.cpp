// REC-001..005 (T-052): see Recorder.h.

#include "record/Recorder.h"

#include <pthread.h>
#include <pthread/qos.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <span>
#include <string>
#include <system_error>

#include "io/AudioFileWriter.h"
#include "record/RecordFifo.h"
#include "time/Transport.h"
#include "time/TransportBlock.h"

namespace daw {

namespace {

constexpr auto kDiskPoll = std::chrono::milliseconds(10);  // daw.diskwrite: how often it drains
constexpr uint32_t kDiskBatch = 1024;                     // frames per file write

std::filesystem::path defaultDirectory() {
    std::error_code ec;
    std::filesystem::path tmp = std::filesystem::temp_directory_path(ec);
    if (ec) tmp = "/tmp";
    // CONV §9: per process, so parallel worktrees' tests never share it.
    return tmp / ("EmberStudio-Recordings-" + std::to_string(::getpid()));
}

} // namespace

// One armed track's take.
struct Recorder::Take {
    NodeID track = 0;
    uint32_t inputPair = 0;
    std::unique_ptr<RecordFifo> fifo = std::make_unique<RecordFifo>();
    // Audio thread (read by the others once the session is deactivated).
    std::atomic<int64_t> offered{0};     // frames captured or dropped so far
    std::atomic<int64_t> startSample{0};
    std::atomic<bool> started{false};
    std::atomic<uint64_t> dropped{0};
    // daw.diskwrite.
    std::unique_ptr<AudioFileWriter> writer;
    std::string path;
    int64_t written = 0;
    std::optional<Error> error;
};

struct Recorder::Session {
    double sampleRate = 0;
    std::filesystem::path directory;
    std::vector<std::unique_ptr<Take>> takes;
    std::map<NodeID, uint32_t> armed;  // what it was made for
    std::atomic<bool> started{false};
    // daw.diskwrite scratch.
    std::vector<RecordFrame> frames = std::vector<RecordFrame>(kDiskBatch);
    std::vector<float> left = std::vector<float>(kDiskBatch);
    std::vector<float> right = std::vector<float>(kDiskBatch);
};

Recorder::Recorder() : directory_(defaultDirectory()) {
    thread_ = std::thread([this] { diskLoop(); });
}

Recorder::~Recorder() {
    (void)finalize();
    {
        std::lock_guard lock(mutex_);
        stopping_ = true;
    }
    wake_.notify_all();
    thread_.join();
}

// MARK: Control

void Recorder::setDirectory(const std::filesystem::path& directory) {
    std::lock_guard lock(mutex_);
    directory_ = directory.empty() ? defaultDirectory() : directory;
}

std::filesystem::path Recorder::directory() const {
    std::lock_guard lock(mutex_);
    return directory_;
}

void Recorder::setArmed(NodeID track, uint32_t inputPair, bool armed) {
    if (armed && (armed_.size() < kMaxTracks || armed_.count(track) != 0))
        armed_[track] = std::min(inputPair, kMaxInputPairs - 1);
    else if (!armed)
        armed_.erase(track);
}

bool Recorder::anyArmed() const { return !armed_.empty(); }
std::size_t Recorder::armedCount() const { return armed_.size(); }

void Recorder::setPunch(const PunchRange& punch) {
    punch_ = punch;
    const uint64_t seq = punchSeq_.load(std::memory_order_relaxed);
    punchSeq_.store(seq + 1, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    punchEnabled_.store(punch.enabled, std::memory_order_relaxed);
    punchIn_.store(punch.in, std::memory_order_relaxed);
    punchOut_.store(punch.out, std::memory_order_relaxed);
    punchSeq_.store(seq + 2, std::memory_order_release);
}

PunchRange Recorder::punch() const { return punch_; }

bool Recorder::capturing() const {
    std::lock_guard lock(mutex_);
    return session_ && session_->started.load(std::memory_order_acquire);
}

std::vector<FinalizedTake> Recorder::prepare(double sampleRate) {
    {
        std::lock_guard lock(mutex_);
        if (session_) {
            if (session_->started.load(std::memory_order_acquire)) return {};  // finalize first
            if (session_->armed == armed_ && session_->sampleRate == sampleRate &&
                session_->directory == directory_)
                return {};
        }
        if (session_ == nullptr && armed_.empty()) return {};
    }
    // Idle, so normally nothing to write; but the audio thread may have started it just now.
    std::vector<FinalizedTake> late = finish(deactivate());
    if (armed_.empty()) return late;

    auto session = std::make_shared<Session>();
    session->sampleRate = sampleRate;
    session->armed = armed_;
    for (const auto& [track, pair] : armed_) {
        auto take = std::make_unique<Take>();
        take->track = track;
        take->inputPair = pair;
        session->takes.push_back(std::move(take));
    }
    std::lock_guard lock(mutex_);
    session->directory = directory_;
    session_ = session;
    active_.store(session.get(), std::memory_order_seq_cst);
    return late;
}

std::shared_ptr<Recorder::Session> Recorder::deactivate() {
    std::shared_ptr<Session> session;
    {
        std::lock_guard lock(mutex_);
        session = std::move(session_);
        session_.reset();
    }
    active_.store(nullptr, std::memory_order_seq_cst);
    // Dekker with captureBlock: once rtBusy_ reads false after the pointer is cleared, the audio
    // thread can't hold the old session. Bounded by one block.
    while (rtBusy_.load(std::memory_order_seq_cst)) std::this_thread::sleep_for(std::chrono::microseconds(50));
    return session;
}

std::vector<FinalizedTake> Recorder::finalize() { return finish(deactivate()); }

std::vector<FinalizedTake> Recorder::finish(std::shared_ptr<Session> session) {
    if (!session || !session->started.load(std::memory_order_acquire)) return {};
    std::unique_lock lock(mutex_);
    finalizeRequest_ = std::move(session);
    finalizeDone_ = false;
    wake_.notify_all();
    finished_.wait(lock, [this] { return finalizeDone_; });
    std::vector<FinalizedTake> out = std::move(finalized_);
    finalized_.clear();
    return out;
}

std::size_t Recorder::queuedFrames() const {
    std::lock_guard lock(mutex_);
    std::size_t n = 0;
    if (session_)
        for (const auto& take : session_->takes) n += take->fifo->framesQueued();
    return n;
}

void Recorder::pauseWriter(bool paused) {
    std::lock_guard lock(mutex_);
    paused_ = paused;
}

// MARK: daw.diskwrite (REC-002)

void Recorder::diskLoop() {
    pthread_setname_np("daw.diskwrite");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    for (;;) {
        std::shared_ptr<Session> session, request;
        {
            std::unique_lock lock(mutex_);
            wake_.wait_for(lock, kDiskPoll, [this] { return stopping_ || finalizeRequest_ != nullptr; });
            if (stopping_ && finalizeRequest_ == nullptr) return;
            request = finalizeRequest_;
            if (!paused_) session = session_;
        }
        if (session && session->started.load(std::memory_order_acquire)) drain(*session);
        if (!request) continue;

        // REC-004: the audio thread is done with it, so this drain gets everything.
        drain(*request);
        std::vector<FinalizedTake> results;
        for (auto& take : request->takes) {
            if (!take->started.load(std::memory_order_acquire)) continue;
            Take& t = *take;
            // A drop at the very end leaves the file short of the take: pad it with silence.
            const int64_t offered = t.offered.load(std::memory_order_acquire);
            if (t.written < offered && t.writer && !t.error) {
                std::fill(request->left.begin(), request->left.end(), 0.0f);
                while (t.written < offered && !t.error) {
                    const auto n = static_cast<uint32_t>(std::min<int64_t>(offered - t.written, kDiskBatch));
                    const float* channels[2] = {request->left.data(), request->left.data()};
                    if (auto ok = t.writer->write(channels, n); !ok) t.error = ok.error();
                    else t.written += n;
                }
            }
            if (t.writer)
                if (auto closed = t.writer->close(); !closed && !t.error) t.error = closed.error();
            FinalizedTake r;
            r.track = t.track;
            r.inputPair = t.inputPair;
            r.file = t.error ? std::string() : t.path;
            r.startSample = t.startSample.load(std::memory_order_acquire);
            r.frames = t.error ? 0 : t.written;
            r.sampleRate = request->sampleRate;
            r.droppedFrames = t.dropped.load(std::memory_order_acquire);
            r.error = t.error;
            if (t.error && !t.path.empty()) {
                std::error_code ec;
                std::filesystem::remove(t.path, ec);  // a broken file helps nobody
            }
            results.push_back(std::move(r));
        }
        request.reset();
        std::lock_guard lock(mutex_);
        finalized_ = std::move(results);
        finalizeRequest_.reset();
        finalizeDone_ = true;
        finished_.notify_all();
    }
}

void Recorder::drain(Session& session) {
    for (auto& take : session.takes) drainTake(session, *take);
}

void Recorder::openFile(Session& session, Take& take) {
    std::error_code ec;
    std::filesystem::create_directories(session.directory, ec);
    if (ec) {
        take.error = Error{ErrorCode::io, "can't create " + session.directory.string() + ": " + ec.message()};
        return;
    }
    // A name nobody has yet (daw.diskwrite is the only writer in this process, and the default
    // directory is per process).
    std::filesystem::path file;
    for (uint32_t n = 1;; ++n) {
        file = session.directory / ("Track " + std::to_string(take.track) + " Take " + std::to_string(n) + ".caf");
        if (!std::filesystem::exists(file, ec)) break;
    }
    auto writer = AudioFileWriter::create(file, AudioFileFormat::recording(session.sampleRate, 2));
    if (!writer) {
        take.error = writer.error();
        return;
    }
    take.writer = std::move(writer).value();
    take.path = file.string();
}

void Recorder::drainTake(Session& session, Take& take) {
    RecordChunk chunk;
    while (take.fifo->popChunk(chunk)) {
        if (!take.writer && !take.error) openFile(session, take);
        uint32_t left = chunk.frames;
        // A failed file still drains, so the FIFO never backs up.
        const bool write = take.writer && !take.error;
        // REC-002: dropped blocks before this one become silence.
        if (write && chunk.fileFrame > take.written) {
            std::fill(session.left.begin(), session.left.end(), 0.0f);
            while (take.written < chunk.fileFrame && !take.error) {
                const auto n = static_cast<uint32_t>(std::min<int64_t>(chunk.fileFrame - take.written, kDiskBatch));
                const float* channels[2] = {session.left.data(), session.left.data()};
                if (auto ok = take.writer->write(channels, n); !ok) take.error = ok.error();
                else take.written += n;
            }
        }
        while (left > 0) {
            const uint32_t want = std::min(left, kDiskBatch);
            const std::size_t got = take.fifo->popFrames(std::span<RecordFrame>(session.frames.data(), want));
            if (got == 0) break;  // can't happen: the frames precede their header
            left -= static_cast<uint32_t>(got);
            if (!write || take.error) continue;
            for (std::size_t i = 0; i < got; ++i) {
                session.left[i] = session.frames[i].left;
                session.right[i] = session.frames[i].right;
            }
            const float* channels[2] = {session.left.data(), session.right.data()};
            if (auto ok = take.writer->write(channels, static_cast<uint32_t>(got)); !ok) take.error = ok.error();
            else take.written += static_cast<int64_t>(got);
        }
    }
}

// MARK: RT (REC-001, REC-003, REC-005)

void Recorder::captureBlock(const Transport& transport, const AudioBufferView& input, uint32_t numFrames) DAW_RT {
    // The transport didn't advance (no graph published): this block was laid out already.
    const SamplePos pos = transport.samplePos();
    const bool advanced = !hasLastPos_ || pos != lastPos_;
    lastPos_ = pos;
    hasLastPos_ = true;

    const TransportBlock& block = transport.block();
    if (numFrames == 0 || !advanced || !block.playing || !block.recording || block.numSegments == 0 ||
        block.tempo == nullptr)
        return;

    rtBusy_.store(true, std::memory_order_seq_cst);
    Session* session = active_.load(std::memory_order_seq_cst);
    if (session == nullptr) {
        rtBusy_.store(false, std::memory_order_release);
        return;
    }

    // REC-005: the punch range, if it was read whole (else the last one that was).
    const uint64_t seq = punchSeq_.load(std::memory_order_acquire);
    if ((seq & 1) == 0) {
        PunchRange p{punchEnabled_.load(std::memory_order_relaxed), punchIn_.load(std::memory_order_relaxed),
                     punchOut_.load(std::memory_order_relaxed)};
        std::atomic_thread_fence(std::memory_order_acquire);
        if (punchSeq_.load(std::memory_order_relaxed) == seq) rtPunch_ = p;
    }
    const bool punched = rtPunch_.enabled && !transport.loopEnabled() && rtPunch_.out > rtPunch_.in;
    const SamplePos punchIn = punched ? block.tempo->tickToSample(rtPunch_.in) : 0;
    const SamplePos punchOut = punched ? block.tempo->tickToSample(rtPunch_.out) : 0;
    const auto latency = static_cast<SamplePos>(latency_.load(std::memory_order_relaxed));

    // CONV-RT-04: two segments at most, takes ≤ kMaxTracks.
    for (uint8_t s = 0; s < block.numSegments && s < 2; ++s) {
        const TransportSegment& seg = block.seg[s];
        if (seg.frameOffset >= numFrames) continue;
        const uint32_t segFrames = std::min(seg.numFrames, numFrames - seg.frameOffset);
        // REC-003: the timeline position of the segment's first captured frame.
        const SamplePos first = seg.startSample - latency;
        SamplePos a = 0, b = segFrames;
        if (punched) {
            a = std::clamp<SamplePos>(punchIn - first, 0, segFrames);
            b = std::clamp<SamplePos>(punchOut - first, 0, segFrames);
        }
        if (a >= b) continue;
        const uint32_t from = seg.frameOffset + static_cast<uint32_t>(a);
        const auto n = static_cast<uint32_t>(b - a);
        for (auto& takePtr : session->takes) {
            Take& take = *takePtr;
            const uint32_t l = take.inputPair * 2, r = l + 1;
            const float* left = l < input.numChannels && input.numFrames >= from + n ? input.channels[l] + from : nullptr;
            const float* right = r < input.numChannels && input.numFrames >= from + n ? input.channels[r] + from : nullptr;
            const int64_t at = take.offered.load(std::memory_order_relaxed);
            if (!take.fifo->write(left, right, n, at)) {
                take.dropped.fetch_add(n, std::memory_order_relaxed);
                dropped_.fetch_add(n, std::memory_order_relaxed);
            }
            if (!take.started.load(std::memory_order_relaxed)) {
                take.startSample.store(first + a, std::memory_order_relaxed);
                take.started.store(true, std::memory_order_release);
            }
            take.offered.store(at + n, std::memory_order_release);
        }
        session->started.store(true, std::memory_order_release);
    }
    rtBusy_.store(false, std::memory_order_release);
}

} // namespace daw
