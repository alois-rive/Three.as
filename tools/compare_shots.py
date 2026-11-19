#!/usr/bin/env python3
"""Compares two folders of screenshots (tools/screenshots.sh), pixel by pixel.

    python3 tools/compare_shots.py build/shots/before build/shots/after [--tolerance=N]
        [--max-differing=PCT]

Prints, per image, how many pixels differ (any channel by more than the
tolerance, default 0) and the largest channel difference; exits 1 when an
image differs or is missing. --max-differing lets an image pass with up to
PCT percent of its pixels differing (baked shader variants against the
uber-shader: about 1%, see docs/DEVIATIONS.md).
"""
import os
import sys

from PIL import Image, ImageChops


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    tolerance = 0
    max_differing = 0.0
    for a in sys.argv[1:]:
        if a.startswith("--tolerance="):
            tolerance = int(a.split("=", 1)[1])
        elif a.startswith("--max-differing="):
            max_differing = float(a.split("=", 1)[1])
    if len(args) != 2:
        print(__doc__)
        return 2
    a_dir, b_dir = args
    names = sorted(n for n in os.listdir(a_dir) if n.endswith(".png"))
    failed = False
    for name in names:
        b_path = os.path.join(b_dir, name)
        if not os.path.exists(b_path):
            print(f"{name}: missing in {b_dir}")
            failed = True
            continue
        a = Image.open(os.path.join(a_dir, name)).convert("RGBA")
        b = Image.open(b_path).convert("RGBA")
        if a.size != b.size:
            print(f"{name}: size {a.size} vs {b.size}")
            failed = True
            continue
        diff = ImageChops.difference(a, b)
        worst = max(hi for _, hi in diff.getextrema())
        count = 0
        if worst > tolerance:
            for px in diff.getdata():
                if max(px) > tolerance:
                    count += 1
        share = 100.0 * count / (a.size[0] * a.size[1])
        status = "same" if count == 0 else f"{count} pixels differ ({share:.2f}%, max {worst})"
        if share > max_differing or (count and max_differing == 0):
            failed = True
            if max_differing > 0:
                status += f" > {max_differing}%"
        print(f"{name}: {status}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
