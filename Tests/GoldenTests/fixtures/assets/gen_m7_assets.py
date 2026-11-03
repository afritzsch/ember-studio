#!/usr/bin/env python3
"""Writes the asset of the M7 golden sidechain_compressor (T-071).

A mono 32-bit float WAV at 48 kHz, the session rate, so nothing is resampled (D-27):

- kick_48k.wav: 9600 frames (0.2 s, 384 ticks at 120 bpm) of a kick-like key: a sine sweeping
  from 150 Hz down to 50 Hz (f(t) = 50 + 100·e^(−t/30 ms)) under an e^(−t/120 ms) decay, peak
  near 0.9, with a linear fade over the last 480 frames so it ends on exactly 0. Frame 0 is 0
  (the sweep starts at phase 0).

Deterministic: rerunning it rewrites the same bytes. Run from anywhere:

    python3 -I Tests/GoldenTests/fixtures/assets/gen_m7_assets.py
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


def kick(frames=9600, fade=480):
    out = []
    for n in range(frames):
        t = n / RATE
        phase = 2 * math.pi * (50 * t + 100 * 0.03 * (1 - math.exp(-t / 0.03)))
        s = 0.9 * math.exp(-t / 0.12) * math.sin(phase)
        if n >= frames - fade:
            s *= (frames - 1 - n) / fade
        out.append(s)
    return out


write_float_wav("kick_48k.wav", kick())
