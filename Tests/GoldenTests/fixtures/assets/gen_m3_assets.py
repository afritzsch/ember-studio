#!/usr/bin/env python3
"""Writes the asset of the M3 goldens (T-036): clips_fades_tempo_change, locate_reset.

A mono 32-bit float WAV at 48 kHz, the session rate, so nothing is resampled (D-27):

- tone_441_48k.wav: 35000 frames of a 441 Hz sine at 0.5, no fades. Its period (108.84 frames)
  isn't a whole number, so a clip that plays the wrong source frame (off by one, stretched, or
  restarted) differs from the expected samples by far more than float rounding, whatever the
  offset. 35000 frames is 1400 ticks at 120 bpm.

Deterministic: rerunning it rewrites the same bytes. Run from anywhere:

    python3 -I Tests/GoldenTests/fixtures/assets/gen_m3_assets.py
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


write_float_wav("tone_441_48k.wav", [0.5 * math.sin(2 * math.pi * 441 * n / RATE) for n in range(35000)])
