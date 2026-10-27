#!/usr/bin/env python3
"""Generates tempo_vectors.json (TIME-011), the shared vectors for the C++ and Swift TempoMap.

Expected values come from exact rational arithmetic (fractions.Fraction), not from either
implementation, so the vectors also check that the double-based code is exact (TIME-001).
"tickToSampleBitExact" is the exception: very large positions where fusing a + b*c into an FMA
changes the result. They pin the double arithmetic itself, which both sides must share.

Points whose exact sample position lies within HALF_MARGIN of (but not exactly on) a .5 tie are
skipped: there the correctly rounded answer depends on the last bit, and TIME-001 allows ±1 sample.

    python3 -I Tests/Fixtures/gen_tempo_vectors.py > Tests/Fixtures/tempo_vectors.json
"""
import json
import random
import re
from fractions import Fraction

PPQ = 960
HALF_MARGIN = Fraction(1, 10_000)


def round_half_away(x: Fraction) -> int:
    n = abs(x)
    r = int(n + Fraction(1, 2))  # floor(|x| + 0.5)
    return r if x >= 0 else -r


def near_half(x: Fraction) -> bool:
    # Exact ties are kept: in these maps they come from exactly representable doubles (e.g.
    # 62.5 samples per tick), so they pin the rounding mode (half away from zero).
    frac = x - (x.numerator // x.denominator)
    return 0 < abs(frac - Fraction(1, 2)) < HALF_MARGIN


class ExactMap:
    def __init__(self, sample_rate, tempos, sigs):
        self.sr = Fraction(sample_rate)
        self.tempos = [(t, Fraction(bpm)) for t, bpm in tempos]  # Fraction(float) is exact
        self.sigs = sigs
        self.starts = [Fraction(0)]
        for (t0, b0), (t1, _) in zip(self.tempos, self.tempos[1:]):
            self.starts.append(self.starts[-1] + (t1 - t0) * self.spt(b0))
        self.first_bars = [1]
        for (t0, n0, d0), (t1, _, _) in zip(sigs, sigs[1:]):
            bar_ticks = n0 * PPQ * 4 // d0
            self.first_bars.append(self.first_bars[-1] + -(-(t1 - t0) // bar_ticks))

    def spt(self, bpm):
        return self.sr * 60 / (bpm * PPQ)

    def exact_sample(self, tick) -> Fraction:
        i = max([k for k, (t, _) in enumerate(self.tempos) if t <= tick], default=0)
        t, bpm = self.tempos[i]
        return self.starts[i] + (tick - t) * self.spt(bpm)

    def tick_to_sample(self, tick) -> int:
        return round_half_away(self.exact_sample(tick))

    def sample_to_tick(self, sample) -> int:
        # The last tick whose rounded position is <= sample. tick_to_sample is monotone, so
        # bracket and bisect.
        lo, hi = -1, 1
        while self.tick_to_sample(lo) > sample:
            lo *= 2
        while self.tick_to_sample(hi) <= sample:
            hi *= 2
        while hi - lo > 1:  # invariant: f(lo) <= sample < f(hi)
            mid = (lo + hi) // 2
            if self.tick_to_sample(mid) <= sample:
                lo = mid
            else:
                hi = mid
        return lo

    def bpm_at(self, tick):
        i = max([k for k, (t, _) in enumerate(self.tempos) if t <= tick], default=0)
        return float(self.tempos[i][1])

    def tick_to_bbt(self, tick):
        j = max([k for k, (t, _, _) in enumerate(self.sigs) if t <= tick], default=0)
        t, num, den = self.sigs[j]
        beat_ticks = PPQ * 4 // den
        bar_index, in_bar = divmod(tick - t, num * beat_ticks)  # Python floors
        return [self.first_bars[j] + bar_index, in_bar // beat_ticks + 1, in_bar % beat_ticks]


def double_tick_to_sample(sample_rate, tempos, tick, fused):
    """TempoMap.cpp's tickToSample in IEEE doubles (Python floats never fuse). With fused=True,
    each a + b*c is rounded once, as an FMA would do it."""
    def mul_add(a, b, c):
        return float(Fraction(a) + Fraction(b) * Fraction(c)) if fused else a + b * c

    def spt(bpm):
        return (float(sample_rate) * 60.0) / (bpm * float(PPQ))

    starts = [0.0]
    for (t0, b0), (t1, _) in zip(tempos, tempos[1:]):
        starts.append(mul_add(starts[-1], float(t1) - float(t0), spt(b0)))
    i = max([k for k, (t, _) in enumerate(tempos) if t <= tick], default=0)
    x = mul_add(starts[i], float(tick) - float(tempos[i][0]), spt(tempos[i][1]))
    return round_half_away(Fraction(x))


def bit_exact_ticks(sample_rate, tempos, rng, count=16):
    """TIME-011: ticks where an FMA would change the rounded sample. Expected values are the
    unfused double results, which both implementations must reproduce bit for bit."""
    found = []
    for _ in range(200_000):
        t = rng.randrange(10**12, 10**14)
        plain = double_tick_to_sample(sample_rate, tempos, t, fused=False)
        if plain != double_tick_to_sample(sample_rate, tempos, t, fused=True):
            found.append([t, plain])
            if len(found) == count:
                break
    assert len(found) == count, "not enough FMA-sensitive ticks"
    return sorted(found)


def make_map(name, sample_rate, tempos, sigs, ticks, samples, rng=None, extra=0, span=0,
             bit_exact=False):
    m = ExactMap(sample_rate, tempos, sigs)
    ticks = list(ticks)
    samples = list(samples)
    if rng:
        ticks += [rng.randrange(-span // 100, span) for _ in range(extra)]
        last = m.tick_to_sample(span)
        samples += [rng.randrange(-last // 100, last) for _ in range(extra)]
    # Every event boundary and its neighbours.
    for t, *_ in tempos + sigs:
        ticks += [t - 1, t, t + 1]
    ticks = sorted(set(ticks))

    t2s = []
    for t in ticks:
        x = m.exact_sample(t)
        if near_half(x):
            assert rng, f"{name}: hand-picked tick {t} is a rounding tie"
            continue
        t2s.append([t, round_half_away(x)])
    # Each boundary sample and its neighbours, from the tick list.
    samples += [s + d for _, s in t2s for d in (-1, 0, 1)]
    s2t = []
    for s in sorted(set(samples)):
        t = m.sample_to_tick(s)
        if near_half(m.exact_sample(t)) or near_half(m.exact_sample(t + 1)):
            continue
        s2t.append([s, t])
    return {
        "name": name,
        "sampleRate": float(sample_rate),
        "tempos": [[t, float(b)] for t, b in tempos],
        "timeSignatures": [list(s) for s in sigs],
        "tickToSample": t2s,
        "tickToSampleBitExact": bit_exact_ticks(sample_rate, tempos, rng) if bit_exact else [],
        "sampleToTick": s2t,
        "bpmAt": [[t, m.bpm_at(t)] for t in ticks],
        "bbt": [[t, *m.tick_to_bbt(t)] for t in ticks],
    }


def main():
    rng = random.Random(7)  # fixed seed: the file is reproducible
    maps = []

    maps.append(make_map(
        "120 bpm 4/4 @ 48k", 48000, [(0, 120.0)], [(0, 4, 4)],
        ticks=[-3840, -960, -1, 0, 1, 2, 480, 960, 3840, 960 * 4 * 1000],
        samples=[-25, -24, -1, 0, 1, 12, 13, 24, 25, 26, 24000]))

    # TIME-002 acceptance table: 4/4 → 7/8 (bar 3) → 3/4 (bar 5).
    bar = 3840
    seven8 = 2 * bar
    three4 = seven8 + 2 * 7 * 480
    maps.append(make_map(
        "4/4 -> 7/8 -> 3/4 @ 48k, 100 bpm", 48000, [(0, 100.0)],
        [(0, 4, 4), (seven8, 7, 8), (three4, 3, 4)],
        ticks=[-bar - 1, -bar, -960, -1, 0, 959, 960, 1919, bar - 1, bar,
               seven8 - 1, seven8, seven8 + 479, seven8 + 480, seven8 + 6 * 480,
               seven8 + 7 * 480 - 1, seven8 + 7 * 480, three4 - 1, three4, three4 + 960,
               three4 + 3 * 960 - 1, three4 + 3 * 960, three4 + 100 * 3 * 960 + 1234],
        samples=[]))

    # A signature change mid-bar truncates that bar (bar 2 has 2 beats), and odd meters.
    maps.append(make_map(
        "mid-bar change 4/4 -> 3/4 at bar 2 beat 3, 6/8, 5/16 @ 96k", 96000,
        [(0, 96.0), (5760, 150.25)],
        [(0, 4, 4), (5760, 3, 4), (5760 + 2880 * 2, 6, 8), (5760 + 2880 * 2 + 2880 * 3, 5, 16)],
        ticks=[5759, 5760, 8639, 8640, 11519, 11520, 11999, 12000, 14399, 14400, 20159, 20160,
               20160 + 1200 * 7 + 239],
        samples=[]))

    maps.append(make_map(
        "tempo changes @ 44.1k", 44100,
        [(0, 120.0), (1920, 90.0), (7680, 140.5), (20000, 61.3), (20001, 999.0), (21000, 1.0)],
        [(0, 4, 4)],
        ticks=[0, 1919, 1920, 3000, 7680, 19999, 20000, 20001, 20002, 21000, 30000],
        samples=[], rng=rng, extra=200, span=40000, bit_exact=True))

    # Fewer samples than ticks: sampleToTick has to pick the last of several ticks per sample.
    maps.append(make_map(
        "1 kHz at 1000 bpm (16 ticks per sample) and 1 bpm", 1000,
        [(0, 1000.0), (96000, 1.0), (96010, 1000.0)], [(0, 4, 4)],
        ticks=[0, 1, 15, 16, 17, 95999, 96000, 96005, 96010, 96011],
        samples=[0, 1, 2, 99, 100, 101, -1, -2],
        rng=rng, extra=100, span=200000))

    # Drift: 200 random tempo events over ~10^8 ticks (about 29 hours at 120 bpm).
    t, tempos = 0, []
    for _ in range(200):
        tempos.append((t, round(rng.uniform(20.0, 300.0), 3)))
        t += rng.randrange(1, 1_000_000)
    maps.append(make_map(
        "200 tempo events over ~1e8 ticks @ 192k", 192000, tempos, [(0, 4, 4)],
        ticks=[t, t + 10**9], samples=[], rng=rng, extra=300, span=t, bit_exact=True))

    invalid = [
        ("sample rate too low", 999.0, [(0, 120.0)], [(0, 4, 4)], "sampleRateOutOfRange"),
        ("sample rate too high", 768001.0, [(0, 120.0)], [(0, 4, 4)], "sampleRateOutOfRange"),
        ("no tempo events", 48000.0, [], [(0, 4, 4)], "noTempoEvents"),
        ("first tempo not at 0", 48000.0, [(1, 120.0)], [(0, 4, 4)], "firstEventNotAtTickZero"),
        ("tempo ticks equal", 48000.0, [(0, 120.0), (5, 100.0), (5, 90.0)], [(0, 4, 4)],
         "eventsNotAscending"),
        ("tempo ticks descending", 48000.0, [(0, 120.0), (5, 100.0), (4, 90.0)], [(0, 4, 4)],
         "eventsNotAscending"),
        ("bpm 0", 48000.0, [(0, 0.0)], [(0, 4, 4)], "tempoOutOfRange"),
        ("bpm above max", 48000.0, [(0, 120.0), (960, 1000.5)], [(0, 4, 4)], "tempoOutOfRange"),
        ("no time signatures", 48000.0, [(0, 120.0)], [], "noTimeSignatures"),
        ("first signature not at 0", 48000.0, [(0, 120.0)], [(960, 4, 4)],
         "firstEventNotAtTickZero"),
        ("signatures not ascending", 48000.0, [(0, 120.0)], [(0, 4, 4), (3840, 3, 4), (3840, 6, 8)],
         "eventsNotAscending"),
        ("denominator 3", 48000.0, [(0, 120.0)], [(0, 4, 3)], "invalidTimeSignature"),
        ("denominator 128", 48000.0, [(0, 120.0)], [(0, 4, 128)], "invalidTimeSignature"),
        ("numerator 0", 48000.0, [(0, 120.0)], [(0, 0, 4)], "invalidTimeSignature"),
        ("numerator 65", 48000.0, [(0, 120.0)], [(0, 65, 4)], "invalidTimeSignature"),
        # The checks run in a fixed order, so the first problem is the one reported.
        ("sample rate checked before tempos", 10.0, [], [], "sampleRateOutOfRange"),
        ("tempos checked before signatures", 48000.0, [(3, 120.0)], [], "firstEventNotAtTickZero"),
    ]

    doc = {
        "format": 1,
        "about": "TIME-011 shared TempoMap vectors, checked by DAWEngineTests (C++) and "
                 "DAWModelTests (Swift). Generated by gen_tempo_vectors.py from exact rationals; "
                 "do not edit by hand.",
        "ppq": PPQ,
        "maps": maps,
        "invalid": [{"name": n, "sampleRate": sr, "tempos": [list(x) for x in te],
                     "timeSignatures": [list(x) for x in si], "error": e}
                    for n, sr, te, si, e in invalid],
    }
    # One vector per line: collapse the innermost (numbers-only) arrays.
    text = json.dumps(doc, indent=1)
    text = re.sub(r"\[\s*([-0-9.e,\s]+?)\s*\]",
                  lambda m: "[" + ",".join(x.strip() for x in m.group(1).split(",")) + "]", text)
    print(text)


if __name__ == "__main__":
    main()
