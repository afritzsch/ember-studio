// T-002 unit tests for Result, DAW_RT, SpscQueue and AudioBufferPool. Run from
// Tests/DAWEngineTests/CoreUtilsTests.swift; see CoreUtilsChecks.h for why they're C++.

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>

#include "CoreUtilsChecks.h"

#include "core/AudioBufferPool.h"
#include "core/Realtime.h"
#include "core/Result.h"
#include "core/SpscQueue.h"

using namespace daw;

namespace {

// MARK: Result (CONV §4)

Result<int> parsePositive(int x) {
    if (x <= 0) return makeError(ErrorCode::invalidArgument, "not positive");
    return x;
}

Result<void> succeedIf(bool ok) {
    if (!ok) return makeError(ErrorCode::notFound, "missing");
    return {};
}

struct Base {
    virtual ~Base() = default;
    virtual int id() const { return 0; }
};
struct Derived : Base {
    int id() const override { return 7; }
};

Result<std::unique_ptr<Base>> makeBase() {
    return std::make_unique<Derived>();
}

// MARK: SpscQueue (ENG-060)

template <class T, std::size_t N>
concept SpscInstantiable = requires { typename SpscQueue<T, N>; };

// ENG-060: capacity must be a power of two and T trivially copyable; anything else is
// rejected at compile time.
static_assert(SpscInstantiable<int, 1>);
static_assert(SpscInstantiable<int, 1024>);
static_assert(!SpscInstantiable<int, 0>);
static_assert(!SpscInstantiable<int, 3>);
static_assert(!SpscInstantiable<int, 1000>);
static_assert(!SpscInstantiable<std::string, 16>);
static_assert(!SpscInstantiable<std::unique_ptr<int>, 16>);
static_assert(SpscQueue<int, 16>::capacity() == 16);
static_assert(SpscQueue<int>::capacity() == 1024);  // default N, as in SpscQueue<TransportCmd>

// A payload wider than one register, so a torn read under concurrency would be visible.
struct Message {
    uint64_t seq;
    uint64_t check;  // ~seq
    float payload[6];
};

// CONV-RT-06: an RT function that drives every RT-side member. Because it's DAW_RT and the
// engine builds with -Wfunction-effects -Werror, this only compiles if each of these
// instantiations is itself nonblocking.
template <class Q>
std::size_t rtRoundTrip(Q& queue, const AudioBufferPool& pool) DAW_RT {
    Message m{1, ~uint64_t{1}, {}};
    std::array<Message, 4> batch{};
    std::size_t moved = queue.push(m) ? 1 : 0;
    moved += queue.push(std::span<const Message>(batch));
    moved += queue.pop(m) ? 1 : 0;
    moved += queue.pop(std::span<Message>(batch));
    moved += queue.sizeApprox() + (queue.emptyApprox() ? 1 : 0);
    if (pool.numBuffers() > 0) {
        const AudioBufferView v = pool.view(0, pool.maxFrames());
        if (!v.empty()) v.channel(0)[0] = 1.0f;
        pool.clear(0, pool.maxFrames());
        moved += pool.numChannels(0);
    }
    return moved;
}

bool isAligned(const void* p) {
    return reinterpret_cast<uintptr_t>(p) % AudioBufferPool::kAlignment == 0;
}

} // namespace

namespace daw::testing {

CheckResult resultValueAndError() {
    CheckResult checks;
    auto good = parsePositive(5);
    DAW_CHECK(good.ok());
    DAW_CHECK(static_cast<bool>(good));
    DAW_CHECK(good.value() == 5);
    DAW_CHECK(*good == 5);
    DAW_CHECK(good.valueOr(-1) == 5);

    auto bad = parsePositive(-3);
    DAW_CHECK(!bad.ok());
    DAW_CHECK(bad.error().code == ErrorCode::invalidArgument);
    DAW_CHECK(bad.error().message == "not positive");
    DAW_CHECK(bad.valueOr(-1) == -1);
    return checks;
}

CheckResult resultVoid() {
    CheckResult checks;
    Result<void> ok = succeedIf(true);
    DAW_CHECK(ok.ok());
    Result<void> bad = succeedIf(false);
    DAW_CHECK(!bad);
    DAW_CHECK(bad.error().code == ErrorCode::notFound);
    DAW_CHECK(bad.error().message == "missing");
    return checks;
}

CheckResult resultMoveOnlyAndConverting() {
    CheckResult checks;
    auto r = makeBase();
    DAW_CHECK(r.ok());
    DAW_CHECK(r.value() != nullptr);
    DAW_CHECK(r.value()->id() == 7);
    std::unique_ptr<Base> owned = std::move(r).value();
    DAW_CHECK(owned && owned->id() == 7);

    Result<std::string> s = std::string("abc");
    DAW_CHECK(s->size() == 3);
    Result<std::string> e = makeError(ErrorCode::io);
    DAW_CHECK(std::move(e).valueOr("fallback") == "fallback");
    return checks;
}

// CONV-RT-06: DAW_RT expands to [[clang::nonblocking]] with this toolchain, so RT bodies are
// compiler-checked rather than just tagged. The negative half (an allocating DAW_RT function
// fails to build) is in CoreUtilsTests.swift, since it has to invoke the compiler.
CheckResult rtAnnotationNonblocking() {
    CheckResult checks;
    DAW_CHECK(DAW_RT_NONBLOCKING == 1);
    // DAW_RT also implies noexcept, which is visible to the type system.
    auto rtLambda = [](int x) DAW_RT { return x + 1; };
    DAW_CHECK(noexcept(rtLambda(1)));
    DAW_CHECK(rtLambda(1) == 2);

    auto queue = std::make_unique<SpscQueue<Message, 8>>();
    auto pool = AudioBufferPool::create(1, 2, 64);
    DAW_CHECK(pool.ok());
    if (!pool.ok()) return checks;
    const AudioBufferPool& p = *pool;
    DAW_CHECK(noexcept(rtRoundTrip(*queue, p)));
    DAW_CHECK(rtRoundTrip(*queue, p) > 0);
    return checks;
}

CheckResult spscFifoFullEmpty() {
    CheckResult checks;
    SpscQueue<int, 8> q;
    int out = -1;
    DAW_CHECK(q.emptyApprox());
    DAW_CHECK(!q.pop(out));
    DAW_CHECK(out == -1);  // untouched on failure

    // All N slots are usable.
    for (int i = 0; i < 8; ++i) DAW_CHECK(q.push(i));
    DAW_CHECK(q.sizeApprox() == 8);
    DAW_CHECK(!q.push(99));  // full: rejected, nothing overwritten

    for (int i = 0; i < 8; ++i) {
        DAW_CHECK(q.pop(out));
        DAW_CHECK(out == i);
    }
    DAW_CHECK(!q.pop(out));
    DAW_CHECK(q.emptyApprox());
    return checks;
}

CheckResult spscWraparound() {
    CheckResult checks;
    // Indices run far past N, so masking and the full/empty arithmetic are exercised.
    SpscQueue<uint32_t, 4> q;
    uint32_t next = 0, expect = 0, out = 0;
    for (int round = 0; round < 10'000; ++round) {
        const int pushes = 1 + round % 4;
        for (int i = 0; i < pushes; ++i) DAW_CHECK(q.push(next++));
        while (q.pop(out)) DAW_CHECK(out == expect++);
    }
    DAW_CHECK(expect == next);
    DAW_CHECK(q.emptyApprox());
    return checks;
}

CheckResult spscBulk() {
    CheckResult checks;
    SpscQueue<int, 8> q;
    std::array<int, 6> in{0, 1, 2, 3, 4, 5};
    std::array<int, 6> out{};

    DAW_CHECK(q.push(std::span<const int>(in)) == 6);
    // Only two slots left: a bulk push is partial, never an overwrite.
    DAW_CHECK(q.push(std::span<const int>(in)) == 2);
    DAW_CHECK(q.sizeApprox() == 8);
    DAW_CHECK(q.push(std::span<const int>(in)) == 0);

    DAW_CHECK(q.pop(std::span<int>(out)) == 6);
    for (int i = 0; i < 6; ++i) DAW_CHECK(out[i] == i);
    // Two remain; a larger request returns just those, and they wrap past the end of storage.
    DAW_CHECK(q.push(std::span<const int>(in).first(3)) == 3);
    DAW_CHECK(q.pop(std::span<int>(out)) == 5);
    const int expected[5] = {0, 1, 0, 1, 2};
    for (int i = 0; i < 5; ++i) DAW_CHECK(out[i] == expected[i]);
    DAW_CHECK(q.pop(std::span<int>(out)) == 0);

    // Empty spans are no-ops.
    DAW_CHECK(q.push(std::span<const int>()) == 0);
    DAW_CHECK(q.pop(std::span<int>()) == 0);
    return checks;
}

CheckResult spscTwoThreads() {
    CheckResult checks;
    // One producer, one consumer, mixing single and bulk operations. Every message arrives once,
    // in order, untorn. Also the TSan target for ENG-060 (TEST-007).
    constexpr uint64_t kCount = 500'000;
    auto q = std::make_unique<SpscQueue<Message, 64>>();
    std::atomic<int> producerFailures{0};

    std::thread producer([&] {
        uint64_t seq = 0;
        std::array<Message, 5> batch{};
        while (seq < kCount) {
            if (seq % 3 == 0) {
                const Message m{seq, ~seq, {float(seq)}};
                if (q->push(m)) ++seq;
            } else {
                std::size_t n = 0;
                for (; n < batch.size() && seq + n < kCount; ++n)
                    batch[n] = Message{seq + n, ~(seq + n), {float(seq + n)}};
                const std::size_t pushed = q->push(std::span<const Message>(batch.data(), n));
                if (pushed > n) producerFailures.fetch_add(1);
                seq += pushed;
            }
            if (q->sizeApprox() > q->capacity()) producerFailures.fetch_add(1);
            std::this_thread::yield();
        }
    });

    uint64_t expect = 0;
    int consumerFailures = 0;
    std::array<Message, 7> batch{};
    while (expect < kCount) {
        std::size_t n = 0;
        if (expect % 2 == 0) {
            n = q->pop(batch[0]) ? 1 : 0;
        } else {
            n = q->pop(std::span<Message>(batch));
        }
        for (std::size_t i = 0; i < n; ++i, ++expect) {
            const Message& m = batch[i];
            if (m.seq != expect || m.check != ~expect || m.payload[0] != float(expect))
                ++consumerFailures;
        }
        if (n == 0) std::this_thread::yield();
    }
    producer.join();

    DAW_CHECK(consumerFailures == 0);
    DAW_CHECK(producerFailures.load() == 0);
    Message extra{};
    DAW_CHECK(!q->pop(extra));
    return checks;
}

CheckResult poolLayout() {
    CheckResult checks;
    auto created = AudioBufferPool::create(4, 2, 500);
    DAW_CHECK(created.ok());
    if (!created.ok()) return checks;
    const AudioBufferPool& pool = *created;

    DAW_CHECK(pool.numBuffers() == 4);
    DAW_CHECK(pool.maxFrames() == 500);
    for (uint32_t b = 0; b < 4; ++b) {
        const AudioBufferView v = pool.view(b, 500);
        DAW_CHECK(v.numChannels == 2);
        DAW_CHECK(pool.numChannels(b) == 2);
        DAW_CHECK(v.numFrames == 500);
        for (uint32_t c = 0; c < 2; ++c) {
            DAW_CHECK(isAligned(v.channel(c)));
            // Preallocated storage starts silent.
            for (uint32_t i = 0; i < 500; ++i) DAW_CHECK(v.channel(c)[i] == 0.0f);
        }
    }

    // Every channel is distinct storage: fill each with its own value, then read all back.
    for (uint32_t b = 0; b < 4; ++b)
        for (uint32_t c = 0; c < 2; ++c)
            for (uint32_t i = 0; i < 500; ++i) pool.view(b, 500).channel(c)[i] = float(b * 10 + c);
    for (uint32_t b = 0; b < 4; ++b)
        for (uint32_t c = 0; c < 2; ++c)
            for (uint32_t i = 0; i < 500; ++i)
                DAW_CHECK(pool.view(b, 500).channel(c)[i] == float(b * 10 + c));

    // A shorter view sees the same storage, and clear() zeroes only the requested frames.
    const AudioBufferView shortView = pool.view(1, 100);
    DAW_CHECK(shortView.numFrames == 100);
    DAW_CHECK(shortView.channel(0) == pool.view(1, 500).channel(0));
    pool.clear(1, 100);
    for (uint32_t c = 0; c < 2; ++c) {
        DAW_CHECK(pool.view(1, 500).channel(c)[99] == 0.0f);
        DAW_CHECK(pool.view(1, 500).channel(c)[100] == 10.0f + float(c));
    }
    DAW_CHECK(pool.view(0, 500).channel(0)[0] == 0.0f);
    DAW_CHECK(pool.view(2, 500).channel(0)[0] == 20.0f);

    // Zero-frame views are valid (ENG-004 allows numFrames == 0).
    DAW_CHECK(pool.view(3, 0).empty());
    pool.clear(3, 0);
    return checks;
}

CheckResult poolMixedChannelCounts() {
    CheckResult checks;
    const uint32_t counts[] = {1, 2, 0, 6};
    auto created = AudioBufferPool::create(std::span<const uint32_t>(counts), 4096);
    DAW_CHECK(created.ok());
    if (!created.ok()) return checks;
    const AudioBufferPool& pool = *created;

    DAW_CHECK(pool.numBuffers() == 4);
    for (uint32_t b = 0; b < 4; ++b) {
        DAW_CHECK(pool.numChannels(b) == counts[b]);
        DAW_CHECK(pool.view(b, 4096).numChannels == counts[b]);
    }
    DAW_CHECK(pool.view(2, 4096).empty());

    // Channels don't overlap: consecutive channel starts are at least maxFrames apart.
    const float* prevEnd = nullptr;
    for (uint32_t b = 0; b < 4; ++b) {
        const AudioBufferView v = pool.view(b, 4096);
        for (uint32_t c = 0; c < v.numChannels; ++c) {
            DAW_CHECK(isAligned(v.channel(c)));
            DAW_CHECK(prevEnd == nullptr || v.channel(c) >= prevEnd);
            prevEnd = v.channel(c) + 4096;
        }
    }
    return checks;
}

CheckResult poolErrorsAndEmpty() {
    CheckResult checks;
    auto zeroFrames = AudioBufferPool::create(2, 2, 0);
    DAW_CHECK(!zeroFrames.ok());
    DAW_CHECK(!zeroFrames.ok() && zeroFrames.error().code == ErrorCode::invalidArgument);

    // A size that would overflow or exhaust memory is refused before anything is allocated.
    auto huge = AudioBufferPool::create(1u << 20, 1u << 10, 4096);
    DAW_CHECK(!huge.ok());
    DAW_CHECK(!huge.ok() && huge.error().code == ErrorCode::invalidArgument);

    auto none = AudioBufferPool::create(0, 2, 512);
    DAW_CHECK(none.ok());
    DAW_CHECK(none.ok() && none->numBuffers() == 0);

    AudioBufferPool empty;
    DAW_CHECK(empty.numBuffers() == 0);
    return checks;
}

CheckResult poolMove() {
    CheckResult checks;
    auto created = AudioBufferPool::create(2, 2, 256);
    DAW_CHECK(created.ok());
    if (!created.ok()) return checks;
    AudioBufferPool a = std::move(created).value();
    float* sample = a.view(1, 256).channel(1);
    sample[7] = 3.5f;

    // Moving hands over the storage: views taken before the move stay valid.
    AudioBufferPool b = std::move(a);
    DAW_CHECK(a.numBuffers() == 0);
    DAW_CHECK(b.numBuffers() == 2);
    DAW_CHECK(b.view(1, 256).channel(1) == sample);
    DAW_CHECK(b.view(1, 256).channel(1)[7] == 3.5f);

    AudioBufferPool c;
    c = std::move(b);
    DAW_CHECK(b.numBuffers() == 0);
    DAW_CHECK(c.numBuffers() == 2 && c.maxFrames() == 256);
    DAW_CHECK(c.view(1, 256).channel(1) == sample);
    return checks;
}

} // namespace daw::testing
