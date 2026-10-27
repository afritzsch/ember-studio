// T-005 unit tests for ParamSlotTable and ParamSmoother. Run from
// Tests/DAWEngineTests/ParamTests.swift; see ParamChecks.h for why these parts are C++.

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <thread>
#include <type_traits>
#include <vector>

#include "ParamChecks.h"

#include "core/ParamSlotTable.h"
#include "core/ParamSmoother.h"
#include "core/RtTrap.h"

using namespace daw;

namespace {

// 02 Interfaces: ParamID is a 32-bit index (T-004 and the facade rely on this).
static_assert(std::is_same_v<ParamID, uint32_t>);
static_assert(std::is_trivially_copyable_v<ParamRamp>);
static_assert(std::is_trivially_copyable_v<ParamSmoother>);

// A snapshot-style NodeConfig for a gain node (ENG-023): it holds the ParamID, never the value.
struct GainConfig {
    ParamID gain;
};

// One block of a gain node: read the slot once, ramp, apply. DAW_RT so the compiler checks the
// whole RT path a node would take.
void renderGainBlock(const GainConfig& config, const ParamSlotTable& params,
                     ParamSmoother& smoother, float* samples, uint32_t numFrames) DAW_RT {
    smoother.next(params, config.gain, numFrames).multiply(samples);
}

// Every RT entry point, over every block size.
float exerciseRtPaths(ParamSlotTable& table, ParamID id, float* buffer) DAW_RT {
    ParamSmoother smoother(table.get(id));
    const GainConfig config{id};
    float sink = 0.0f;
    for (uint32_t n = 0; n <= 4096; ++n) {
        table.set(id, static_cast<float>(n % 7) * 0.25f);
        sink += static_cast<float>(table.generation(id)) + table.slot(id).value.load();
        const ParamRamp ramp = smoother.next(table, id, n);
        ramp.fill(buffer);
        if (n > 0) sink += ramp.at(n - 1) + ramp.step() + (ramp.isConstant() ? 1.0f : 0.0f);
        renderGainBlock(config, table, smoother, buffer, n);
        smoother.reset(smoother.current());
        sink += table.capacity() > 0 && n > 0 ? buffer[n - 1] : 0.0f;
    }
    return sink;
}

} // namespace

namespace daw::testing {

CheckResult paramTableDefaultCapacity() {
    CheckResult checks;
    // ENG-020: 65,536 slots by default, all preallocated: allocating every one of them succeeds
    // and IDs are the indices 0 … N-1 in order.
    auto table = std::make_unique<ParamSlotTable>();
    DAW_CHECK(table->capacity() == 65'536);
    DAW_CHECK(ParamSlotTable::kDefaultCapacity == 65'536);
    DAW_CHECK(table->allocatedCount() == 0);

    const ParamSlot* base = &table->slot(0);
    bool inOrder = true;
    for (uint32_t i = 0; i < table->capacity(); ++i) {
        auto id = table->allocate();
        inOrder = inOrder && id.ok() && *id == i;
    }
    DAW_CHECK(inOrder);
    DAW_CHECK(table->allocatedCount() == 65'536);
    auto full = table->allocate();
    DAW_CHECK(!full.ok() && full.error().code == ErrorCode::outOfMemory);
    // Slots never move: the storage is the one allocated at construction.
    DAW_CHECK(&table->slot(0) == base);
    DAW_CHECK(&table->slot(65'535) == base + 65'535);
    return checks;
}

CheckResult paramTableAllocateFree() {
    CheckResult checks;
    ParamSlotTable table(16);
    DAW_CHECK(table.capacity() == 16);

    auto a = table.allocate(1, 0.5f);
    auto b = table.allocate(1, -2.0f);
    DAW_CHECK(a.ok() && *a == 0);
    DAW_CHECK(b.ok() && *b == 1);
    if (!a.ok() || !b.ok()) return checks;
    // A new slot starts at its initial value.
    DAW_CHECK(table.get(*a) == 0.5f);
    DAW_CHECK(table.get(*b) == -2.0f);
    DAW_CHECK(table.isAllocated(*a) && table.isAllocated(*b));
    DAW_CHECK(!table.isAllocated(2));
    DAW_CHECK(!table.isAllocated(16)); // out of range is simply not allocated

    // Freeing returns the slot; the next allocation reuses the lowest free index, and other
    // slots keep their IDs and values.
    table.set(*b, 7.0f);
    DAW_CHECK(table.free(*a).ok());
    DAW_CHECK(!table.isAllocated(*a));
    DAW_CHECK(table.allocatedCount() == 1);
    auto c = table.allocate(1, 3.0f);
    DAW_CHECK(c.ok() && *c == 0);
    DAW_CHECK(table.get(0) == 3.0f); // re-initialized, not the freed slot's old value
    DAW_CHECK(table.get(*b) == 7.0f);
    DAW_CHECK(table.allocatedCount() == 2);
    return checks;
}

CheckResult paramTableContiguousRanges() {
    CheckResult checks;
    ParamSlotTable table(32);

    // A node's params are one contiguous range (05 NodeDesc firstParam/numParams).
    auto eq = table.allocate(8, 1.0f);   // 0…7
    auto comp = table.allocate(6, 0.0f); // 8…13
    auto gain = table.allocate(2, 0.5f); // 14…15
    DAW_CHECK(eq.ok() && *eq == 0);
    DAW_CHECK(comp.ok() && *comp == 8);
    DAW_CHECK(gain.ok() && *gain == 14);
    for (uint32_t i = 0; i < 8; ++i) DAW_CHECK(table.get(i) == 1.0f);
    for (uint32_t i = 14; i < 16; ++i) DAW_CHECK(table.get(i) == 0.5f);

    // Free the middle range: a request that fits reuses the hole, a bigger one goes past it.
    DAW_CHECK(table.free(8, 6).ok());
    auto big = table.allocate(7); // hole is 6 wide: must not straddle slot 14
    DAW_CHECK(big.ok() && *big == 16);
    auto fits = table.allocate(6);
    DAW_CHECK(fits.ok() && *fits == 8);

    // Freeing part of an allocation is allowed.
    DAW_CHECK(table.free(2, 3).ok());
    DAW_CHECK(table.isAllocated(1) && !table.isAllocated(2) && !table.isAllocated(4) &&
              table.isAllocated(5));
    auto partial = table.allocate(3);
    DAW_CHECK(partial.ok() && *partial == 2);

    // Fragmentation: enough free slots in total, but no run long enough.
    // Used now: 0…15 and 16…22. Free 23…31 is 9 slots; free 0 and 10 to make 11 free in all.
    DAW_CHECK(table.free(0).ok());
    DAW_CHECK(table.free(10).ok());
    DAW_CHECK(table.allocatedCount() == 21);
    auto tooLong = table.allocate(10);
    DAW_CHECK(!tooLong.ok() && tooLong.error().code == ErrorCode::outOfMemory);
    auto run = table.allocate(9);
    DAW_CHECK(run.ok() && *run == 23);
    DAW_CHECK(table.allocatedCount() == 30);

    // The whole table as one range.
    ParamSlotTable whole(64);
    auto all = whole.allocate(64);
    DAW_CHECK(all.ok() && *all == 0);
    DAW_CHECK(!whole.allocate().ok());
    DAW_CHECK(whole.free(0, 64).ok());
    DAW_CHECK(whole.allocatedCount() == 0);
    return checks;
}

CheckResult paramTableErrors() {
    CheckResult checks;
    ParamSlotTable table(8);
    auto none = table.allocate(0);
    DAW_CHECK(!none.ok() && none.error().code == ErrorCode::invalidArgument);
    auto tooMany = table.allocate(9);
    DAW_CHECK(!tooMany.ok() && tooMany.error().code == ErrorCode::outOfMemory);

    auto id = table.allocate(2);
    DAW_CHECK(id.ok() && *id == 0);

    // Bad ranges fail and change nothing.
    auto check = [&](Result<void> r) {
        DAW_CHECK(!r.ok() && r.error().code == ErrorCode::invalidArgument);
    };
    check(table.free(0, 0));                // empty
    check(table.free(8));                   // out of bounds
    check(table.free(7, 2));                // runs past the end
    check(table.free(0xFFFF'FFFFu, 2));     // index overflow
    check(table.free(5));                   // never allocated
    check(table.free(1, 2));                // partly allocated: nothing is freed
    DAW_CHECK(table.isAllocated(0) && table.isAllocated(1));
    DAW_CHECK(table.allocatedCount() == 2);
    DAW_CHECK(table.free(0, 2).ok());
    check(table.free(0));                   // double free
    DAW_CHECK(table.allocatedCount() == 0);

    // A zero-capacity table is valid; it just has nothing to hand out.
    ParamSlotTable empty(0);
    DAW_CHECK(empty.capacity() == 0);
    DAW_CHECK(!empty.allocate().ok());
    check(empty.free(0));
    return checks;
}

CheckResult paramTableConcurrentAllocate() {
    CheckResult checks;
    // allocate()/free() may come from several non-RT threads (main thread via the facade,
    // daw.compile). Ranges handed out concurrently never overlap, and the count adds up.
    constexpr int kThreads = 4;
    constexpr int kRounds = 2'000;
    auto table = std::make_unique<ParamSlotTable>(4'096);
    std::vector<std::atomic<int>> owner(table->capacity());
    for (auto& o : owner) o.store(-1);
    std::atomic<int> overlaps{0};
    std::atomic<int> failures{0};

    std::vector<std::thread> threads;
    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t] {
            std::vector<std::pair<ParamID, uint32_t>> held;
            for (int round = 0; round < kRounds; ++round) {
                const uint32_t count = 1 + static_cast<uint32_t>((round * 7 + t) % 9);
                auto first = table->allocate(count);
                if (!first.ok()) {
                    failures.fetch_add(1);
                    continue;
                }
                for (uint32_t i = *first; i < *first + count; ++i) {
                    int expected = -1;
                    if (!owner[i].compare_exchange_strong(expected, t)) overlaps.fetch_add(1);
                }
                held.emplace_back(*first, count);
                if (held.size() > 20) {
                    const auto [id, n] = held.front();
                    held.erase(held.begin());
                    for (uint32_t i = id; i < id + n; ++i) owner[i].store(-1);
                    if (!table->free(id, n).ok()) failures.fetch_add(1);
                }
            }
            for (const auto& [id, n] : held) {
                for (uint32_t i = id; i < id + n; ++i) owner[i].store(-1);
                if (!table->free(id, n).ok()) failures.fetch_add(1);
            }
        });
    }
    for (auto& thread : threads) thread.join();

    DAW_CHECK(overlaps.load() == 0);
    DAW_CHECK(failures.load() == 0); // 4 threads × ≤ 21 ranges × ≤ 9 slots always fit
    DAW_CHECK(table->allocatedCount() == 0);
    return checks;
}

CheckResult paramSlotReadWrite() {
    CheckResult checks;
    ParamSlotTable table(4);
    auto id = table.allocate(1, 0.25f);
    DAW_CHECK(id.ok());
    if (!id.ok()) return checks;

    // ENG-021: a write is visible to the next read; the generation counts writes, including
    // ones that don't change the value.
    const uint32_t gen0 = table.generation(*id);
    table.set(*id, 0.75f);
    DAW_CHECK(table.get(*id) == 0.75f);
    DAW_CHECK(table.slot(*id).value.load() == 0.75f);
    DAW_CHECK(table.generation(*id) == gen0 + 1);
    table.set(*id, 0.75f);
    DAW_CHECK(table.generation(*id) == gen0 + 2);

    // Reallocating a freed slot is a write too, so a reader holding the old generation notices.
    const uint32_t gen1 = table.generation(*id);
    DAW_CHECK(table.free(*id).ok());
    auto again = table.allocate(1, 0.75f);
    DAW_CHECK(again.ok() && *again == *id);
    DAW_CHECK(table.generation(*id) != gen1);

    // Slots are independent.
    auto other = table.allocate();
    DAW_CHECK(other.ok());
    if (other.ok()) {
        table.set(*other, -1.0f);
        DAW_CHECK(table.get(*id) == 0.75f);
        DAW_CHECK(table.get(*other) == -1.0f);
    }
    return checks;
}

CheckResult paramSlotCrossThread() {
    CheckResult checks;
    // ENG-021: a writer thread (the UI) sweeps a fader while a reader thread (the audio thread)
    // renders blocks, reading the slot once per block. The reader always sees a value the writer
    // wrote, sees the sweep only move forward, and makes no RT violations. Also a TSan target.
    auto table = std::make_unique<ParamSlotTable>(8);
    auto id = table->allocate(1, 0.0f);
    DAW_CHECK(id.ok());
    if (!id.ok()) return checks;

    constexpr int kWrites = 200'000;
    std::atomic<bool> done{false};
    std::thread writer([&] {
        for (int i = 1; i <= kWrites; ++i) table->set(*id, static_cast<float>(i));
        done.store(true, std::memory_order_release);
    });

    int badValues = 0, wentBack = 0, blocks = 0;
    uint64_t readerViolations = 0;
    {
        std::array<float, 64> buffer{};
        ParamSmoother smoother(table->get(*id));
        float last = 0.0f;
        RtScope scope; // the reader thread's own count (DW-019)
        // Bounded: the writer finishes after kWrites, and one more block runs after that.
        for (bool finished = false; !finished && blocks < 100'000'000; ++blocks) {
            finished = done.load(std::memory_order_acquire);
            const ParamRamp ramp = smoother.next(*table, *id, 64);
            ramp.fill(buffer.data());
            const float v = ramp.target;
            if (v != std::floor(v) || v < 0.0f || v > kWrites) ++badValues;
            if (v < last) ++wentBack;
            last = v;
        }
        readerViolations = scope.violations();
        // After the writer is done (acquire), the last write is what the slot holds.
        DAW_CHECK(last == static_cast<float>(kWrites));
    }
    writer.join();

    DAW_CHECK(badValues == 0);
    DAW_CHECK(wentBack == 0);
    DAW_CHECK(blocks > 0);
    DAW_CHECK(readerViolations == 0);
    return checks;
}

CheckResult paramSmootherFollowsSlot() {
    CheckResult checks;
    // ENG-022 through the slot: a node with a smoother initialized at prepare() sees a constant
    // block while nothing changes, a one-block ramp after a write, then constant at the new value.
    ParamSlotTable table(4);
    auto id = table.allocate(1, 0.0f);
    DAW_CHECK(id.ok());
    if (!id.ok()) return checks;

    ParamSmoother smoother;
    smoother.reset(table.get(*id)); // prepare()
    std::array<float, 128> out{};

    smoother.next(table, *id, 128).fill(out.data());
    for (float v : out) DAW_CHECK(v == 0.0f);

    table.set(*id, 1.0f);
    const ParamRamp ramp = smoother.next(table, *id, 128);
    DAW_CHECK(ramp.start == 0.0f && ramp.target == 1.0f && ramp.numFrames == 128);
    ramp.fill(out.data());
    // 128 is a power of two, so every step is exact.
    for (uint32_t i = 0; i < 128; ++i) DAW_CHECK(out[i] == static_cast<float>(i + 1) / 128.0f);

    smoother.next(table, *id, 128).fill(out.data());
    for (float v : out) DAW_CHECK(v == 1.0f);

    // Several writes within one block: only the value present at block start counts (once per
    // block, ENG-021), and the ramp goes straight to it.
    table.set(*id, 0.2f);
    table.set(*id, 0.4f);
    const ParamRamp last = smoother.next(table, *id, 128);
    DAW_CHECK(last.start == 1.0f && last.target == 0.4f);
    return checks;
}

CheckResult paramWritesLeaveConfigUntouched() {
    CheckResult checks;
    // ENG-023: a fader sweep changes only the slot. The node config (what a snapshot holds) is
    // built once and stays bit-identical, yet the rendered gain follows every block's value. So a
    // value change has nothing to rebuild or publish. (The "0 publishes" count against a real
    // Engine/GraphBuilder is T-012/T-014's; see the T-005 report.)
    ParamSlotTable table(16);
    auto id = table.allocate(1, 0.0f);
    DAW_CHECK(id.ok());
    if (!id.ok()) return checks;

    const GainConfig config{*id};
    GainConfig before;
    std::memcpy(&before, &config, sizeof config);

    ParamSmoother smoother(table.get(config.gain));
    std::array<float, 64> block{};
    int mismatches = 0;
    for (int step = 1; step <= 1'000; ++step) {
        const float fader = static_cast<float>(step) / 1'000.0f;
        table.set(*id, fader); // the UI's only action
        block.fill(1.0f);
        renderGainBlock(config, table, smoother, block.data(), 64);
        if (block[63] != fader) ++mismatches;
    }
    DAW_CHECK(mismatches == 0);
    DAW_CHECK(std::memcmp(&before, &config, sizeof config) == 0);
    return checks;
}

uint64_t paramRtViolations() {
    auto table = std::make_unique<ParamSlotTable>(8);
    auto id = table->allocate(1, 0.5f);
    if (!id.ok()) return ~uint64_t{0};
    auto buffer = std::make_unique<float[]>(4096);

    // DW-019: this scope's own count, immune to violations other suites provoke in parallel.
    RtScope scope;
    volatile float sink = exerciseRtPaths(*table, *id, buffer.get());
    (void)sink;
    return scope.violations();
}

} // namespace daw::testing
