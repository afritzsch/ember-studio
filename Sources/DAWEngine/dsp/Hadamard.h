#pragma once
// DSP-033: the reverb's feedback matrix. An N×N Hadamard matrix (Sylvester order, N a power of
// two) scaled by 1/√N is orthogonal, so the FDN's mixing stage neither adds nor removes energy:
// the loop's decay comes from the per-line gains alone. The fast Walsh–Hadamard transform does it
// in N·log2(N) additions instead of N² multiplies.
//
// Sylvester order: H1 = [1], H2N = [[HN, HN], [HN, −HN]]. Row r, column c of H8 is
// (−1)^popcount(r & c); row 0 is all ones.

#include <cstddef>

#include "core/Realtime.h"

namespace daw {

// v ← H_N · v (unnormalized: multiply by 1/√N for the orthogonal matrix). N is a power of two.
template <std::size_t N>
inline void hadamardInPlace(float (&v)[N]) DAW_RT {
    static_assert(N > 0 && (N & (N - 1)) == 0, "N must be a power of two");
    for (std::size_t h = 1; h < N; h *= 2)
        for (std::size_t i = 0; i < N; i += 2 * h)
            for (std::size_t j = i; j < i + h; ++j) {
                const float a = v[j];
                const float b = v[j + h];
                v[j] = a + b;
                v[j + h] = a - b;
            }
}

} // namespace daw
