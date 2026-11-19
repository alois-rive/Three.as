#!/usr/bin/env python3
"""Checks ThreeAS's audio (M17) by ear-free measurement: renders the gallery's
AudioCheck artboard (packages/gallery/examples/audio/audio_check.as) headless
with `rive --render-audio`, one scenario per run, and measures the WAVs.

    python3 tools/check_audio.py            # every check
    python3 tools/check_audio.py pan loop   # some of them

Checks (48 kHz stereo renders; the listener at the origin facing -Z):

- pan        a 441 Hz tone to the right is in the right channel only
             (equal power: L = cos, R = sin of (azimuth + 90) / 180 quarter
             turns), at 45 degrees L/R = tan(22.5 deg), and with the "HRTF"
             model the right still leads.
- distance   per distance model, the level at 1, 2, 4, 8 and 16 units
             against Web Audio's formula.
- cone       a source turned 0..180 degrees away: the gain against Web
             Audio's cone formula (inner 60, outer 180, outer gain 0.2).
- loop       hum.wav looping: the output equals the file tiled, sample for
             sample, and the loop point has no step above the signal's own.
- stop       stop() mid-note: the output fades to silence in about 10 ms with
             no step above the signal's own.
- pause      pause() and play(): silent while paused, the same position after.
- analyser   AudioAnalyser on a 1 kHz oscillator: the peak bin is 1 kHz's.

Pure Python (no numpy). Exits 1 when a check fails.
"""

import array
import math
import os
import re
import struct
import subprocess
import sys
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GALLERY = os.path.join(ROOT, "packages", "gallery")
OUT = os.path.join(GALLERY, "build", "audio_check")
RATE = 48000

results = []


def render(name, seconds, **args):
    path = os.path.join(OUT, name + ".wav")
    cmd = ["rive", GALLERY, "--artboard=AudioCheck", f"--render-audio={path}", f"--advance={seconds}s"]
    for k, v in args.items():
        cmd += ["--arg", f"{k}={v}"]
    run = subprocess.run(cmd, capture_output=True, text=True)
    log = run.stdout + run.stderr
    if run.returncode != 0 or not os.path.exists(path):
        print(log)
        raise SystemExit(f"rive failed for {name}")
    rate, channels, data = read_wav(path)
    assert rate == RATE and channels == 2, (rate, channels)
    return data[0::2], data[1::2], log


def read_wav(path):
    blob = open(path, "rb").read()
    pos, fmt = 12, None
    while pos < len(blob):
        cid, size = blob[pos:pos + 4], struct.unpack("<I", blob[pos + 4:pos + 8])[0]
        body = blob[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif cid == b"data":
            a = array.array("f")
            a.frombytes(body[:len(body) // 4 * 4])
            return fmt[2], fmt[1], a
        pos += 8 + size + (size & 1)
    raise ValueError(path)


def read_pcm16(path):
    with wave.open(path, "rb") as w:
        n = w.getnframes()
        raw = w.readframes(n)
        ch = w.getnchannels()
        vals = struct.unpack("<%dh" % (n * ch), raw)
        return [v / 32768.0 for v in vals[0::ch]], w.getframerate()


def rms(x, a, b):
    seg = x[a:b]
    return math.sqrt(sum(v * v for v in seg) / max(1, len(seg)))


def max_step(x, a, b):
    return max(abs(x[i] - x[i - 1]) for i in range(max(a, 1), b))


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + ": " + detail)


def segment(i, hold):
    """The middle half of the i-th `hold`-second segment (skips the ramps)."""
    a = int((i + 0.25) * hold * RATE)
    return a, a + int(0.5 * hold * RATE)


def check_pan():
    amp = 1 / math.sqrt(2)   # a unit sine's RMS
    left, right, _ = render("pan_right", 1, source="sine", freq=441, positional=1, panning="equalpower", path="2,0,0")
    l, r = rms(left, 12000, 36000), rms(right, 12000, 36000)
    want_r = 0.5 * amp
    check("pan: right source, equal power", l < 1e-6 and abs(r - want_r) < 1e-3,
          f"L rms {l:.2e}, R rms {r:.5f} (want 0 and {want_r:.5f})")
    left, right, _ = render("pan_45", 1, source="sine", freq=441, positional=1, panning="equalpower", path="2,0,-2")
    l, r = rms(left, 12000, 36000), rms(right, 12000, 36000)
    want = math.cos(0.375 * math.pi) / math.sin(0.375 * math.pi)   # x = (45 + 90) / 180
    check("pan: 45 degrees right, L/R", abs(l / r - want) < 2e-3, f"L/R {l / r:.5f} (want {want:.5f})")
    left, right, _ = render("pan_left_hrtf", 1, source="sine", freq=441, positional=1, panning="HRTF", path="-2,0,0")
    l, r = rms(left, 12000, 36000), rms(right, 12000, 36000)
    check("pan: left source, HRTF model", r < 1e-6 and l > 0.3, f"L rms {l:.5f}, R rms {r:.2e}")
    left, right, _ = render("pan_front_hrtf", 1, source="sine", freq=441, positional=1, panning="HRTF", path="1,0,-2")
    l, r = rms(left, 12000, 36000), rms(right, 12000, 36000)
    # The near (right) ear leads: find the lag of left behind right by cross-correlation.
    best, lag = -1e9, 0
    for k in range(0, 40):
        c = sum(left[i + k] * right[i] for i in range(20000, 22000))
        if c > best:
            best, lag = c, k
    az = math.degrees(math.atan2(1, 2))
    itd = 0.0875 / 343 * (math.radians(az) + math.sin(math.radians(az))) * RATE
    check("pan: HRTF interaural delay", r > l and abs(lag - itd) <= 1.5,
          f"R {r:.4f} > L {l:.4f}; left lags {lag} samples (Woodworth at {az:.1f} deg: {itd:.1f})")


def check_distance():
    hold = 0.5
    distances = [1, 2, 4, 8, 16]
    path = ";".join(f"0,0,{-d}" for d in distances)
    models = [
        ("inverse", dict(ref=1, rolloff=1), lambda d: 1 / (1 + (max(d, 1) - 1))),
        ("linear", dict(ref=1, max=20, rolloff=1), lambda d: 1 - (min(max(d, 1), 20) - 1) / 19),
        ("exponential", dict(ref=1, rolloff=1.5), lambda d: (max(d, 1) / 1) ** -1.5),
    ]
    for model, params, formula in models:
        left, right, _ = render("distance_" + model, hold * len(distances) + 0.2, source="sine", freq=441, positional=1,
                                panning="equalpower", model=model, path=path, hold=hold, **params)
        worst = 0
        rows = []
        for i, d in enumerate(distances):
            a, b = segment(i, hold)
            got = rms(left, a, b) / (math.sqrt(0.5) * math.sqrt(0.5))   # / (sine RMS x equal-power gain)
            want = formula(d)
            err = abs(got - want) / max(want, 1e-3)
            worst = max(worst, err)
            rows.append(f"{d}:{got:.4f}/{want:.4f}")
        check(f"distance: {model}", worst < 0.01, f"gain at d (got/want) {' '.join(rows)}; worst {100 * worst:.2f}%")


def check_cone():
    hold = 0.5
    angles = [0, 30, 45, 60, 90, 135, 180]

    def formula(a):
        inner, outer, g = 30.0, 90.0, 0.2
        if a <= inner:
            return 1.0
        if a >= outer:
            return g
        x = (a - inner) / (outer - inner)
        return (1 - x) + g * x
    left, right, _ = render("cone", hold * len(angles) + 0.2, source="sine", freq=441, positional=1, panning="equalpower",
                            path="0,0,-2", angles=",".join(str(a) for a in angles), hold=hold, cone="60,180,0.2")
    base = None
    worst = 0
    rows = []
    for i, ang in enumerate(angles):
        a, b = segment(i, hold)
        level = rms(left, a, b)
        if base is None:
            base = level
        got = level / base
        want = formula(ang)
        worst = max(worst, abs(got - want) / want)
        rows.append(f"{ang}:{got:.4f}/{want:.4f}")
    check("cone: inner 60, outer 180, outer gain 0.2", worst < 0.01,
          f"gain at angle (got/want) {' '.join(rows)}; worst {100 * worst:.2f}%")


def check_loop():
    src, rate = read_pcm16(os.path.join(GALLERY, "examples", "audio", "hum.wav"))
    assert rate == RATE
    left, right, _ = render("loop", 5, source="hum", loop=1)
    # Align: the output starts with the file's first frame.
    start = next(i for i, v in enumerate(left) if v != 0) - 1
    n = len(src)
    err = 0.0
    for i in range(start, len(left) - 1):
        err = max(err, abs(left[i] - src[(i - start) % n]))
    seams = [start + n * k for k in range(1, (len(left) - start) // n + 1) if start + n * k < len(left) - 2]
    seam_step = max(max_step(left, s - 2, s + 3) for s in seams)
    body_step = max_step(left, start + 1000, start + n - 1000)
    check("loop: output is the file tiled, no click at the loop point",
          err < 1e-4 and seam_step <= body_step * 1.05,
          f"{len(seams)} loop points, max |out - file| {err:.2e}; step at the seams {seam_step:.5f} "
          f"vs the signal's own {body_step:.5f}")


def check_stop():
    src, _ = read_pcm16(os.path.join(GALLERY, "examples", "audio", "hum.wav"))
    left, right, log = render("stop", 1.6, source="hum", loop=1, stopAt=1.0)
    start = next(i for i, v in enumerate(left) if v != 0) - 1
    n = len(src)
    last = max(i for i, v in enumerate(left) if abs(v) > 1e-7)
    # The envelope: the output over the file it plays, where the file is loud.
    env = []
    for i in range(last - int(0.05 * RATE), last + 1):
        ref = src[(i - start) % n]
        if abs(ref) > 0.05:
            env.append((i, left[i] / ref))
    fade_from = next(i for i, e in env if e < 0.999)
    length_ms = (last - fade_from) / RATE * 1000
    falling = all(env[k + 1][1] <= env[k][1] + 1e-4 for k in range(len(env) - 1))
    steady = max_step(left, int(0.3 * RATE), int(0.9 * RATE))
    fade = max_step(left, fade_from - 10, last + 2)
    tail = max(abs(v) for v in left[last + 1:])
    check("stop: fades out, no click", fade <= steady * 1.05 and tail == 0 and 8 <= length_ms <= 12 and falling,
          f"the envelope falls from 1 to 0 over {length_ms:.2f} ms ({'monotonic' if falling else 'NOT monotonic'}), "
          f"silent from {last / RATE:.4f} s; max step in the fade {fade:.5f} vs steady {steady:.5f}; after it {tail}")


def check_pause():
    left, right, _ = render("pause", 2.5, source="hum", loop=1, pauseAt=1.0, resumeAt=1.5)
    quiet = max(abs(v) for v in left[int(1.1 * RATE):int(1.45 * RATE)])
    after = rms(left, int(1.6 * RATE), int(2.0 * RATE))
    steady = max_step(left, int(0.3 * RATE), int(0.9 * RATE))
    edges = max(max_step(left, int(0.95 * RATE), int(1.1 * RATE)), max_step(left, int(1.45 * RATE), int(1.6 * RATE)))
    check("pause: silent while paused, resumes without clicks", quiet == 0 and after > 0.05 and edges <= steady * 1.05,
          f"peak while paused {quiet}, RMS after {after:.4f}; max step at the edges {edges:.5f} vs steady {steady:.5f}")


def check_analyser():
    _, _, log = render("analyser", 2, source="sine", freq=1000, analyser=2048, volume=0.05)
    peaks = re.findall(r"analyser peak bin (\d+) \(([\d.]+) Hz\) level (\d+)", log)
    bins = [int(p[0]) for p in peaks[1:]]
    want = 1000 / (RATE / 2048)
    ok = len(bins) > 0 and all(abs(b - want) <= 1 for b in bins)
    check("analyser: peak at the tone", ok,
          f"peak bins {bins} ({', '.join(p[1] for p in peaks[1:])} Hz); 1 kHz is bin {want:.2f}")


CHECKS = {
    "pan": check_pan,
    "distance": check_distance,
    "cone": check_cone,
    "loop": check_loop,
    "stop": check_stop,
    "pause": check_pause,
    "analyser": check_analyser,
}


def main():
    os.makedirs(OUT, exist_ok=True)
    names = sys.argv[1:] or list(CHECKS)
    for name in names:
        CHECKS[name]()
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} audio checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
