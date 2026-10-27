#pragma once
// Minimal harness for engine unit tests that have to stay in C++: templates Swift can't
// instantiate, move-only or non-movable types, threads, and DAW_RT bodies that only the C++
// compiler checks (-Wfunction-effects). Everything else should call the engine from Swift
// directly. See specs/14-testing.md, "C++ unit tests".
//
// Each check function returns a CheckResult; the Swift test calls it through the
// DAWEngineTestSupport module and asserts it with expectPasses() (Tests/DAWEngineTests).

#include <string>

namespace daw::testing {

struct CheckResult {
    int failures = 0;
    std::string firstFailure; // "file:line: check failed: <condition>"

    void fail(const char* what, const char* file, int line) {
        if (failures++ == 0)
            firstFailure = std::string(file) + ":" + std::to_string(line) + ": " + what;
    }
};

} // namespace daw::testing

// Inside a check function that has a local `CheckResult checks`.
#define DAW_CHECK(cond) \
    ((cond) ? (void)0 : checks.fail("check failed: " #cond, __FILE__, __LINE__))
