"""Writes the sample 3D LUTs the Effects example grades with (LUTPass):
warm_grade.cube (Adobe .cube, 17^3) and
warm_grade_3dl.3dl (Autodesk .3dl, the same grade, 12-bit).

The grade: teal shadows, warm highlights, a little more contrast and
saturation (a "cinematic" look), applied to display (sRGB) colour.

    python3 tools/make_lut_samples.py
"""
import os

import sample_paths

SIZE = 17
root = os.path.join(os.path.dirname(__file__), "..")


def grade(r, g, b):
    # Contrast around mid grey (a soft S curve).
    def curve(x):
        return x + 0.18 * (x - 0.5) * (1.0 - abs(2.0 * x - 1.0))
    r, g, b = curve(r), curve(g), curve(b)
    luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    # Saturation.
    s = 1.15
    r, g, b = luma + (r - luma) * s, luma + (g - luma) * s, luma + (b - luma) * s
    # Split toning: teal shadows, orange highlights.
    shadow = max(0.0, 1.0 - luma * 2.0)
    high = max(0.0, luma * 2.0 - 1.0)
    r += -0.04 * shadow + 0.08 * high
    g += 0.02 * shadow + 0.03 * high
    b += 0.06 * shadow - 0.07 * high
    clamp = lambda x: min(1.0, max(0.0, x))
    return clamp(r), clamp(g), clamp(b)


def main():
    n = SIZE - 1
    # .cube: red changes fastest, then green, then blue.
    lines = ['TITLE "ThreeAS warm grade"', "# made by tools/make_lut_samples.py",
             "LUT_3D_SIZE %d" % SIZE, "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
    for bi in range(SIZE):
        for gi in range(SIZE):
            for ri in range(SIZE):
                r, g, b = grade(ri / n, gi / n, bi / n)
                lines.append("%.6f %.6f %.6f" % (r, g, b))
    with open(sample_paths.path("warm_grade.cube"), "w") as f:
        f.write("\n".join(lines) + "\n")
    # .3dl: a grid line of input positions, then blue changes fastest; 12-bit.
    step = 1024 // n
    lines = [" ".join(str(i * step) for i in range(SIZE))]
    for ri in range(SIZE):
        for gi in range(SIZE):
            for bi in range(SIZE):
                r, g, b = grade(ri / n, gi / n, bi / n)
                lines.append("%d %d %d" % (round(r * 4095), round(g * 4095), round(b * 4095)))
    with open(sample_paths.path("warm_grade_3dl.3dl"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", sample_paths.rel("warm_grade.cube"), "and", sample_paths.rel("warm_grade_3dl.3dl"))


main()
