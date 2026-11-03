/// T-056 (MODEL-005 `SetSessionSampleRate`, DW-126): what a session-rate change does to the
/// document. The tempo map follows the rate (DW-020), and every quantity counted in samples at the
/// session rate is scaled by new/old:
///   - `AudioClip.sourceOffsetSamples` (where in the asset the clip starts), and
///   - a sampler zone's `loopStart`/`loopEnd` (source frames of the asset in RAM, which the engine
///     holds at the session rate, IO-031; 06 "Sampler semantics").
/// Everything else is in ticks (clips, notes, fades, the loop, automation) or at the file's own
/// rate (`AssetRef.frames`), so it doesn't move. The engine re-converts the audio (IO-033).
///
/// Rounding: to the nearest sample, halves up, computed exactly in integers (the ratio of two
/// supported rates reduces to at most 320/147, so nothing overflows below the 2^48 bound). A zone
/// loop keeps at least one frame, and a scaled value never passes 2^48 (`AudioClip.maxSourceOffset`).
/// So a change and its way back can be a sample off; `RestoreSessionSampleRate` undoes exactly.
extension Project {
    /// IO-003: the session rates (44.1/48/88.2/96 kHz), the same set the engine accepts.
    public static let supportedSampleRates: Set<Double> = [44_100, 48_000, 88_200, 96_000]

    /// `samples` at `from` Hz in samples at `to` Hz, rounded to the nearest (halves up) and clamped
    /// to 0…2^48. Both rates must be in `supportedSampleRates`.
    public static func rescaleSamples(_ samples: Int64, from: Double, to: Double) -> Int64 {
        guard from != to, samples > 0 else { return samples }
        var num = Int64(to)
        var den = Int64(from)
        let g = gcd(num, den)
        num /= g
        den /= g
        let clamped = min(samples, AudioClip.maxSourceOffset)
        // (s·num + den/2) / den, as (2·s·num + den) / (2·den) so odd denominators round right.
        let product = clamped.multipliedReportingOverflow(by: 2 * num)
        guard !product.overflow, den <= Int64.max / 2 else {
            // Only rates outside the supported set get here.
            return min(Int64((Double(clamped) * to / from).rounded()), AudioClip.maxSourceOffset)
        }
        return min((product.partialValue + den) / (2 * den), AudioClip.maxSourceOffset)
    }

    /// DW-126: sets the session rate and scales every session-rate sample quantity to it.
    mutating func changeSessionSampleRate(to rate: Double) throws(DAWError) {
        let old = sessionSampleRate
        guard rate != old else { return }
        try setSessionSampleRate(rate)
        for t in tracks.indices {
            for c in tracks[t].clips.indices {
                guard case .audio(var clip) = tracks[t].clips[c] else { continue }
                clip.sourceOffsetSamples = Self.rescaleSamples(clip.sourceOffsetSamples, from: old, to: rate)
                tracks[t].clips[c] = .audio(clip)
            }
        }
        updateEachDeviceSlot { slot in
            for z in slot.zones.indices {
                guard let start = slot.zones[z].loopStart, let end = slot.zones[z].loopEnd else { continue }
                let newStart = min(Self.rescaleSamples(start, from: old, to: rate), AudioClip.maxSourceOffset - 1)
                slot.zones[z].loopStart = newStart
                slot.zones[z].loopEnd = max(Self.rescaleSamples(end, from: old, to: rate), newStart + 1)
            }
        }
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
