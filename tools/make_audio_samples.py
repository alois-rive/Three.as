#!/usr/bin/env python3
"""Writes the Audio example's sounds: small original WAVs, synthesized here
(no recordings), into packages/gallery/examples/audio/.

    python3 tools/make_audio_samples.py

16-bit PCM (Rive's AudioAssets take WAV, MP3 or FLAC). hum.wav is at
48 kHz, the usual device rate, so the loop checks read it unresampled; the
others are at 24 kHz (they have nothing above 6 kHz) to keep the file small,
and Rive resamples them as it decodes. Every sound is a seamless loop: tones use frequencies that fit a
whole number of cycles in the loop, noise loops are cross-faded into
themselves, and one-shot shapes decay to silence before the loop point.

- hum.wav       2 s mono: a soft chord (110, 165, 220.5 Hz) breathing at 0.5 Hz
- chime.wav     1.5 s mono: an inharmonic bell strike decaying to silence
- radio.wav     2 s mono: a buzzy arpeggio (band-limited sawtooth notes)
- knock.wav     0.75 s mono: a noise burst through a resonant band-pass
- wind.wav      4 s stereo: two decorrelated low-passed noises, slowly swelling
"""

import math
import os
import random
import struct
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "packages", "gallery", "examples", "audio")


def write(name, channels, rate):
    """channels: a list of equal-length float lists in [-1, 1]."""
    path = os.path.join(OUT, name)
    n = len(channels[0])
    frames = bytearray()
    for i in range(n):
        for c in channels:
            v = max(-1.0, min(1.0, c[i]))
            frames += struct.pack("<h", int(round(v * 32767)))
    with wave.open(path, "wb") as w:
        w.setnchannels(len(channels))
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(frames))
    print(f"wrote {os.path.relpath(path)} ({n / rate:.2f} s, {len(channels)} ch, {rate} Hz)")


def hum(RATE=48000):
    seconds = 2.0
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        breath = 0.75 + 0.25 * math.sin(2 * math.pi * 0.5 * t)
        s = (0.5 * math.sin(2 * math.pi * 110 * t)
             + 0.3 * math.sin(2 * math.pi * 165 * t)
             + 0.2 * math.sin(2 * math.pi * 220.5 * t)
             + 0.08 * math.sin(2 * math.pi * 330 * t))
        out.append(0.45 * breath * s)
    return out


def chime(RATE=24000):
    seconds = 1.5
    n = int(RATE * seconds)
    partials = [(880.0, 1.0, 3.0), (2342.0, 0.5, 5.0), (3906.0, 0.25, 7.0), (5490.0, 0.12, 9.0), (1318.5, 0.3, 4.0)]
    out = []
    for i in range(n):
        t = i / RATE
        attack = min(1.0, t / 0.002)
        s = sum(a * math.exp(-d * t) * math.sin(2 * math.pi * f * t) for f, a, d in partials)
        # fade the last 50 ms to exact silence
        tail = min(1.0, (seconds - t) / 0.05)
        out.append(0.4 * attack * tail * s)
    return out


def radio(RATE=24000):
    seconds = 2.0
    n = int(RATE * seconds)
    notes = [220.0, 277.0, 330.0, 440.0]   # whole cycles in each 0.5 s note
    note_len = n // len(notes)
    out = []
    for i in range(n):
        k = i // note_len
        f = notes[k]
        t = (i - k * note_len) / RATE
        # band-limited sawtooth: 12 harmonics
        s = sum(math.sin(2 * math.pi * h * f * t) / h for h in range(1, 13))
        env = min(1.0, t / 0.01) * min(1.0, (note_len / RATE - t) / 0.01)
        out.append(0.22 * env * s)
    return out


def knock(RATE=24000):
    seconds = 0.75
    n = int(RATE * seconds)
    rng = random.Random(17)
    # resonant band-pass (RBJ) at 900 Hz, Q 6
    f0, q = 900.0, 6.0
    w0 = 2 * math.pi * f0 / RATE
    alpha = math.sin(w0) / (2 * q)
    b0, b1, b2 = alpha, 0.0, -alpha
    a0, a1, a2 = 1 + alpha, -2 * math.cos(w0), 1 - alpha
    x1 = x2 = y1 = y2 = 0.0
    out = []
    for i in range(n):
        t = i / RATE
        env = math.exp(-t / 0.035) if t < 0.3 else 0.0
        x = rng.uniform(-1, 1) * env
        y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1 = x1, x
        y2, y1 = y1, y
        out.append(y)
    peak = max(abs(v) for v in out)
    tail = int(0.05 * RATE)
    for i in range(tail):
        out[n - tail + i] *= 1 - i / tail
    return [0.8 * v / peak for v in out]


def wind(RATE=24000):
    seconds = 4.0
    fade = 0.5
    n = int(RATE * seconds)
    m = n + int(RATE * fade)
    chans = []
    for seed in (3, 5):
        rng = random.Random(seed)
        y = y2 = 0.0
        raw = []
        for i in range(m):
            t = i / RATE
            cutoff = 400 + 300 * math.sin(2 * math.pi * 0.25 * t + seed)
            a = 1 - math.exp(-2 * math.pi * cutoff / RATE)
            y += a * (rng.uniform(-1, 1) - y)
            y2 += a * (y - y2)
            swell = 0.7 + 0.3 * math.sin(2 * math.pi * 0.25 * t)
            raw.append(y2 * swell)
        # cross-fade the extra tail into the start: a seamless loop
        f = m - n
        loop = raw[:n]
        for i in range(f):
            w = i / f
            loop[i] = raw[n + i] * (1 - w) + raw[i] * w
        peak = max(abs(v) for v in loop)
        chans.append([0.5 * v / peak for v in loop])
    return chans


def main():
    os.makedirs(OUT, exist_ok=True)
    write("hum.wav", [hum()], 48000)
    write("chime.wav", [chime()], 24000)
    write("radio.wav", [radio()], 24000)
    write("knock.wav", [knock()], 24000)
    write("wind.wav", wind(), 24000)


if __name__ == "__main__":
    main()
