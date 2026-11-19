#!/usr/bin/env python3
"""Writes STL and PLY samples for the loaders' tests and the Models example:
binary STL with per-face colours, ASCII STL with two solids, ASCII PLY
with normals, colours and a quad, binary big-endian PLY with uvs."""
import math, os, struct

import sample_paths

ASSETS = sample_paths.FIXTURES   # test fixtures only

def pyramid():
    """Square pyramid: 6 triangles (two for the base)."""
    a, b, c, d, top = (-1, 0, -1), (1, 0, -1), (1, 0, 1), (-1, 0, 1), (0, 1.5, 0)
    return [(a, b, c), (a, c, d), (a, b, top), (b, c, top), (c, d, top), (d, a, top)]

def normal(t):
    (ax, ay, az), (bx, by, bz), (cx, cy, cz) = t
    ux, uy, uz = bx - ax, by - ay, bz - az
    vx, vy, vz = cx - ax, cy - ay, cz - az
    n = (uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx)
    l = math.sqrt(sum(x * x for x in n)) or 1
    return tuple(x / l for x in n)

def stl_binary():
    tris = pyramid()
    header = b"ThreeAS sample COLOR=" + bytes([200, 120, 40, 255])
    header = header.ljust(80, b" ")
    out = header + struct.pack("<I", len(tris))
    for i, t in enumerate(tris):
        out += struct.pack("<3f", *normal(t))
        for v in t:
            out += struct.pack("<3f", *v)
        # Faces 0-1 use the default colour (bit 15 set); the sides their own.
        if i < 2:
            attr = 0x8000
        else:
            r, g, b = [(31, 4, 4), (4, 31, 4), (4, 4, 31), (31, 31, 4)][i - 2]
            attr = r | (g << 5) | (b << 10)
        out += struct.pack("<H", attr)
    open(os.path.join(ASSETS, "pyramid_binary.stl"), "wb").write(out)

def stl_ascii():
    lines = []
    tris = pyramid()
    for name, part in (("base", tris[:2]), ("sides", tris[2:])):
        lines.append("solid " + name)
        for t in part:
            lines.append("  facet normal %g %g %g" % normal(t))
            lines.append("    outer loop")
            for v in t:
                lines.append("      vertex %g %g %g" % v)
            lines.append("    endloop")
            lines.append("  endfacet")
        lines.append("endsolid " + name)
    open(os.path.join(ASSETS, "pyramid_ascii.stl"), "w").write("\n".join(lines) + "\n")

def ply_ascii():
    # A cube: 8 vertices with normals and colours, 6 quads.
    vs = [(x, y, z) for x in (-0.5, 0.5) for y in (-0.5, 0.5) for z in (-0.5, 0.5)]
    faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    lines = ["ply", "format ascii 1.0", "comment ThreeAS sample", "element vertex 8",
             "property float x", "property float y", "property float z",
             "property float nx", "property float ny", "property float nz",
             "property uchar red", "property uchar green", "property uchar blue",
             "property float quality",
             "element face 6", "property list uchar int vertex_indices", "end_header"]
    for v in vs:
        l = math.sqrt(3) * 0.5
        n = tuple(c / l for c in v)
        col = tuple(int((c + 0.5) * 255) for c in v)
        lines.append("%g %g %g %g %g %g %d %d %d %g" % (v + n + col + (v[0] + 2,)))
    for f in faces:
        lines.append("4 %d %d %d %d" % f)
    open(os.path.join(ASSETS, "cube_ascii.ply"), "w").write("\n".join(lines) + "\n")

def ply_binary():
    # A quad (two triangles), big-endian, uvs, int16 / double properties.
    vs = [(-1, -1, 0, 0, 0), (1, -1, 0, 1, 0), (1, 1, 0, 1, 1), (-1, 1, 0, 0, 1)]
    head = "\n".join(["ply", "format binary_big_endian 1.0", "element vertex 4",
                      "property double x", "property double y", "property double z",
                      "property float s", "property float t",
                      "element face 2", "property list uchar ushort vertex_indices", "end_header"]) + "\n"
    body = b""
    for v in vs:
        body += struct.pack(">3d2f", *v)
    for f in ((0, 1, 2), (0, 2, 3)):
        body += struct.pack(">B3H", 3, *f)
    open(os.path.join(ASSETS, "quad_binary.ply"), "wb").write(head.encode() + body)

if __name__ == "__main__":
    stl_binary(); stl_ascii(); ply_ascii(); ply_binary()
    print("wrote pyramid_binary.stl, pyramid_ascii.stl, cube_ascii.ply, quad_binary.ply")
