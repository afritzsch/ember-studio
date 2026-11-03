#!/usr/bin/env python3
"""Writes the asset of the M4 goldens sampler_pitch, midi_loop_wrap and midi_locate_no_stuck_notes
(T-044).

A mono 32-bit float WAV at 48 kHz, the session rate, so nothing is resampled (D-27):

- a440_48k.wav: 48000 frames (1 s) of 0.5 · sin(2π · 440 · n / 48000), an A4 sine. 1 s holds
  exactly 440 periods, so the fixtures' sampler zone loops the whole asset ([0, 48000)) without a
  seam: frame 48000 would be frame 0 again. Frame 0 is 0.

Deterministic: rerunning it rewrites the same bytes. Run from anywhere:

    python3 -I Tests/GoldenTests/fixtures/assets/gen_m4_assets.py
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


def sine(frequency, frames, level=0.5):
    return [level * math.sin(2 * math.pi * frequency * n / RATE) for n in range(frames)]


write_float_wav("a440_48k.wav", sine(440, 48000))
