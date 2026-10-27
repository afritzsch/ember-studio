#pragma once
// Minimal harness for C++ unit tests that live inside DAWEngine. Swift only sees EngineFacade.h
// (01-build-layout Interfaces), so engine internals can't be called from Tests/DAWEngineTests
// directly. Instead each test is an `extern "C"` function that Swift Testing binds by symbol
// name (@_silgen_name) and calls:
//
//   int daw_selftest_<name>(char* message, size_t capacity);
//
// It returns the number of failed checks and writes the first failure into `message`.

#include <cstddef>
#include <cstdio>

namespace daw::selftest {

struct Context {
    char* message;
    std::size_t capacity;
    int failures = 0;

    void fail(const char* what, const char* file, int line) {
        if (failures++ == 0 && message && capacity > 0)
            std::snprintf(message, capacity, "%s:%d: %s", file, line, what);
    }
};

} // namespace daw::selftest

#define DAW_CHECK(cond) ((cond) ? (void)0 : ctx.fail("check failed: " #cond, __FILE__, __LINE__))

// Defines daw_selftest_<name>; the body that follows sees `ctx` (a selftest::Context&).
#define DAW_SELFTEST(name)                                                                  \
    static void daw_selftest_body_##name(daw::selftest::Context& ctx);                      \
    extern "C" int daw_selftest_##name(char* message, std::size_t capacity);                \
    extern "C" int daw_selftest_##name(char* message, std::size_t capacity) {               \
        daw::selftest::Context ctx{message, capacity};                                      \
        daw_selftest_body_##name(ctx);                                                      \
        return ctx.failures;                                                                \
    }                                                                                       \
    static void daw_selftest_body_##name(daw::selftest::Context& ctx)
