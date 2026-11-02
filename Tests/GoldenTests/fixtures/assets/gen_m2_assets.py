#!/usr/bin/env python3
"""Writes the assets of the M2 goldens (T-025): pan_law, bus_send_sum, pdc_alignment_null.

Both are mono 32-bit float WAVs at 48 kHz, the session rate, so nothing is resampled (D-27) and
the levels the fixtures' @expect lines state hold exactly:

- tone_1k_48k.wav: 12000 frames (480 ticks at 120 bpm) of a 1 kHz sine at 0.5, no fades.
  48 frames per cycle, so frame 12 of each cycle is exactly 0.5 and the clip ends on a zero
  crossing (250 whole cycles): adjacent clips join without a step.
- click_48k.wav: 4800 frames, 1.0 at frame 0 and silence after (MIX-023's click on beat 1).

Deterministic: rerunning it rewrites the same bytes. Run from anywhere:

    python3 -I Tests/GoldenTests/fixtures/assets/gen_m2_assets.py
"""
import math
import os
import struct

RATE = 48000


def write_float_wav(name, samples):
    data = struct.pack("<%df" % len(samples), *samples)
    fmt = struct.pack("<HHIIHH", 3, 1, RATE, RATE * 4, 4, 32)  # WAVE_FORMAT_IEEE_FLOAT, mono
    fact = struct.pack("<I", len(samples))
    body = (b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"fact" + struct.pack("<I", len(fact)) + fact
            + b"data" + struct.pack("<I", len(data)) + data)
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)


write_float_wav("tone_1k_48k.wav", [0.5 * math.sin(2 * math.pi * n / 48) for n in range(12000)])
write_float_wav("click_48k.wav", [1.0] + [0.0] * 4799)
