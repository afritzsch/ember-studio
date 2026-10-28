#!/usr/bin/env python3
"""Writes tone_1k_44k1.wav, the asset of the wav_playback_resampled golden (M1, IO-031, D-27).

0.5 s (22050 frames) of a 1 kHz sine at 0.5 (-6.02 dBFS), stereo, 16-bit PCM at 44.1 kHz, with
10 ms raised-cosine fades at both ends so the edges stay band-limited through the resampler.
Deterministic: rerunning it rewrites the same bytes. Run from anywhere:

    python3 -I Tests/GoldenTests/fixtures/assets/gen_tone_44k1.py
"""
import math
import os
import struct
import wave

RATE = 44100
FRAMES = RATE // 2
FADE = RATE // 100


def sample(n):
    x = 0.5 * math.sin(2 * math.pi * 1000 * n / RATE)
    edge = min(n, FRAMES - 1 - n)
    if edge < FADE:
        x *= 0.5 - 0.5 * math.cos(math.pi * edge / FADE)
    return max(-32768, min(32767, round(x * 32767)))


path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tone_1k_44k1.wav")
with wave.open(path, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(b"".join(struct.pack("<hh", s, s) for s in map(sample, range(FRAMES))))
