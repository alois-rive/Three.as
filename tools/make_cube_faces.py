"""Writes studio_{px,nx,py,ny,pz,nz}.png (into
packages/gallery/examples/environments/): the Environment example's
procedural studio as six cube faces, laid out as three.js
expects skybox images (it samples image cube maps at (-x, y, z) with the
GL cube rules). Pure Python, no dependencies.

    python3 tools/make_cube_faces.py [size]
"""
import math, os, struct, sys, zlib

import sample_paths

def studio(d):
    x, y, z = d
    lat = math.asin(max(-1.0, min(1.0, y)))
    lon = math.atan2(z, x)
    if lat > 0:
        t = lat / (math.pi / 2)
        r, g, b = 120 - 70 * t, 130 - 70 * t, 150 - 60 * t
    else:
        r, g, b = 70, 62, 56
    if abs(lat - 0.5) < 0.22 and (abs(lon - 0.9) < 0.35 or abs(lon + 1.6) < 0.3):
        r, g, b = 255, 255, 255
    dl, dn = lat - 0.9, lon - 2.4
    if dl * dl + dn * dn < 0.05:
        r, g, b = 255, 214, 160
    return int(r), int(g), int(b)

def cube_dir(face, sc, tc):
    # GL cube rules, inverted: the cube direction of face coordinates.
    return [(1, -tc, -sc), (-1, -tc, sc), (sc, 1, tc), (sc, -1, -tc), (sc, -tc, 1), (-sc, -tc, -1)][face]

def png(path, w, h, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    def chunk(t, c):
        return struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

size = int(sys.argv[1]) if len(sys.argv) > 1 else 128
for face, name in enumerate(["px", "nx", "py", "ny", "pz", "nz"]):
    rows = []
    for row in range(size):
        tc = (row + 0.5) / size * 2 - 1
        line = bytearray()
        for col in range(size):
            sc = (col + 0.5) / size * 2 - 1
            cx, cy, cz = cube_dir(face, sc, tc)
            n = math.sqrt(cx * cx + cy * cy + cz * cz)
            line += bytes(studio((-cx / n, cy / n, cz / n)))   # world = (-x, y, z)
        rows.append(line)
    png(sample_paths.path("studio_%s.png" % name), size, size, rows)
print("wrote 6 faces of", size)
