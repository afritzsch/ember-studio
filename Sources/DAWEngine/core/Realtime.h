#pragma once
// Real-time annotations (00-conventions §2).

// CONV-RT-06: every function reachable from Engine::render() is marked DAW_RT, so it can be
// found by grep and checked by the compiler. With clang's function-effect analysis
// (-Wfunction-effects, on for DAWEngine), a DAW_RT body that allocates, locks, throws or calls
// a function not known to be nonblocking fails the build.
//
// It also implies noexcept: RT code never throws (CONV §4), and clang warns when a nonblocking
// function isn't noexcept. Write it where noexcept would go:
//   void process(ProcessContext&, NodeIO&) DAW_RT override;
//   uint32_t size() const DAW_RT;
//   [](float x) DAW_RT { return x * 0.5f; }
//
// Overrides should repeat DAW_RT: clang doesn't require it, but without it the override body
// isn't checked.
#if defined(__has_cpp_attribute) && __has_cpp_attribute(clang::nonblocking)
#define DAW_RT noexcept [[clang::nonblocking]]
#define DAW_RT_NONBLOCKING 1
#else
#define DAW_RT noexcept
#define DAW_RT_NONBLOCKING 0
#endif

// Precondition check usable inside DAW_RT code. assert() can't be used there: its failure path
// calls into libc, which the effect analysis rejects. Debug traps; Release compiles it out.
// Keyed on DAW_RT_TRAP (BUILD-005) because SwiftPM doesn't define NDEBUG in Release.
#if DAW_RT_TRAP
#define DAW_RT_ASSERT(cond) ((cond) ? (void)0 : __builtin_trap())
#else
#define DAW_RT_ASSERT(cond) ((void)0)
#endif

namespace daw {

// Apple Silicon caches use 128-byte lines. libc++ doesn't provide
// std::hardware_destructive_interference_size, so it's spelled out here.
inline constexpr unsigned kCacheLineSize = 128;

} // namespace daw
