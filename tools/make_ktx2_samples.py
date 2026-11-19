"""Writes checker_bc1.ktx2 (BC1/DXT1, sRGB, full mip chain
down to 4x4) and checker_astc.ktx2 (ASTC 4x4, sRGB, one
level of constant-colour "void extent" blocks): a 64 x 64 coloured checker
for KTX2Loader. For the tests only, it also writes checker_astc6x5.ktx2
(ASTC 6x5, sRGB, real blocks from tools/astc_encode.py, a mip chain down to
1 x 1, so blocks hang over the edges) and ktx2_expected (the RGBA8 texels
a decoder must produce from level 0 of checker_bc1 and of checker_astc6x5,
64 * 64 * 4 bytes each). Pure Python, no dependencies.

    python3 tools/make_ktx2_samples.py
"""
import os, struct, zlib

import astc_encode
import sample_paths

SIZE = 64

def image(size):
    px = []
    for y in range(size):
        row = []
        for x in range(size):
            cell = ((x * 4 // size) + (y * 4 // size)) % 2
            if cell:
                row.append((240, 200, 60))
            else:
                t = (x + y) / (2 * size)
                row.append((int(40 + 60 * t), int(90 + 80 * t), int(200 - 60 * t)))
        px.append(row)
    return px

def half(px):
    n = len(px) // 2
    return [[tuple((px[2*y][2*x][c] + px[2*y][2*x+1][c] + px[2*y+1][2*x][c] + px[2*y+1][2*x+1][c]) // 4
                   for c in range(3)) for x in range(n)] for y in range(n)]

def rgb565(c):
    return ((c[0] >> 3) << 11) | ((c[1] >> 2) << 5) | (c[2] >> 3)

def from565(v):
    r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))

def bc1(px, decoded=None):
    """BC1 blocks of px; with `decoded` (rows like px), also the texels a
    decoder gives back: the palette entry each texel took, thirds rounded
    to nearest as the S3TC specification's (2 c0 + c1) / 3."""
    out = bytearray()
    n = len(px)
    for by in range(0, n, 4):
        for bx in range(0, n, 4):
            block = [px[by + j][bx + i] for j in range(4) for i in range(4)]
            lum = lambda c: c[0] * 3 + c[1] * 6 + c[2]
            hi, lo = max(block, key=lum), min(block, key=lum)
            c0, c1 = rgb565(hi), rgb565(lo)
            if c0 < c1:
                c0, c1 = c1, c0
            p0, p1 = from565(c0), from565(c1)
            if c0 == c1:
                out += struct.pack("<HHI", c0, c1, 0)
                if decoded is not None:
                    for k in range(16):
                        decoded[by + k // 4][bx + k % 4] = p0 + (255,)
                continue
            pal = [p0, p1, tuple((2 * a + b) // 3 for a, b in zip(p0, p1)), tuple((a + 2 * b) // 3 for a, b in zip(p0, p1))]
            exact = [p0, p1, tuple((2 * a + b + 1) // 3 for a, b in zip(p0, p1)),
                     tuple((a + 2 * b + 1) // 3 for a, b in zip(p0, p1))]
            bits = 0
            for k, c in enumerate(block):
                best = min(range(4), key=lambda i: sum((c[j] - pal[i][j]) ** 2 for j in range(3)))
                bits |= best << (2 * k)
                if decoded is not None:
                    decoded[by + k // 4][bx + k % 4] = exact[best] + (255,)
            out += struct.pack("<HHI", c0, c1, bits)
    return bytes(out)

def astc_void(px):
    out = bytearray()
    n = len(px)
    for by in range(0, n, 4):
        for bx in range(0, n, 4):
            block = [px[by + j][bx + i] for j in range(4) for i in range(4)]
            avg = [sum(c[k] for c in block) // 16 for k in range(3)]
            out += struct.pack("<Q", 0xFFFFFFFFFFFFFDFC)
            out += struct.pack("<HHHH", avg[0] * 257, avg[1] * 257, avg[2] * 257, 0xFFFF)
    return bytes(out)

def ktx2(path, vk_format, levels, size):
    header_len = 80 + 24 * len(levels)
    # A minimal data format descriptor (KTX2 requires one): total size only.
    dfd = struct.pack("<I", 4)
    data_start = header_len + len(dfd)
    data_start = (data_start + 15) // 16 * 16
    offsets, pos = [], data_start
    for lv in levels:
        offsets.append(pos)
        pos += len(lv)
        pos = (pos + 15) // 16 * 16
    out = bytearray(b"\xabKTX 20\xbb\r\n\x1a\n")
    out += struct.pack("<IIIIIIIII", vk_format, 1, size, size, 0, 0, 1, len(levels), 0)
    out += struct.pack("<IIIIQQ", header_len, len(dfd), 0, 0, 0, 0)
    for lv, o in zip(levels, offsets):
        out += struct.pack("<QQQ", o, len(lv), len(lv))
    out += dfd
    for lv, o in zip(levels, offsets):
        out += b"\0" * (o - len(out)) + lv
    open(path, "wb").write(out)

def downsample(px):
    """Half size (at least 1), averaging what is there."""
    h, w = len(px), len(px[0])
    nh, nw = max(1, h // 2), max(1, w // 2)
    out = []
    for y in range(nh):
        row = []
        for x in range(nw):
            ys = range(2 * y, min(h, 2 * y + 2))
            xs = range(2 * x, min(w, 2 * x + 2))
            texels = [px[j][i] for j in ys for i in xs]
            row.append(tuple(sum(t[c] for t in texels) // len(texels) for c in range(4)))
        out.append(row)
    return out

out = os.path.dirname(sample_paths.path("checker_bc1.ktx2.zlib"))
px = image(SIZE)
chain, cur = [], px
expected_bc1 = [[None] * SIZE for _ in range(SIZE)]
while True:
    chain.append(bc1(cur, expected_bc1 if cur is px else None))
    if len(cur) <= 4:
        break
    cur = half(cur)
ktx2(os.path.join(out, "checker_bc1.ktx2"), 132, chain, SIZE)          # VK_FORMAT_BC1_RGB_SRGB_BLOCK
ktx2(os.path.join(out, "checker_astc.ktx2"), 158, [astc_void(px)], SIZE)   # VK_FORMAT_ASTC_4x4_SRGB_BLOCK

# ASTC 6x5 with real blocks (one partition, a 6x5 grid of 2-bit weights,
# direct RGB endpoints), every level down to 1 x 1.
fixtures = os.path.dirname(sample_paths.path("checker_astc6x5.ktx2.zlib"))
rgba = [[c + (255,) for c in row] for row in px]
levels6x5, expected_6x5, cur = [], None, rgba
while True:
    blocks, expected = astc_encode.encode_image(cur, 6, 5, True)
    levels6x5.append(blocks)
    if expected_6x5 is None:
        expected_6x5 = expected
    if len(cur) == 1 and len(cur[0]) == 1:
        break
    cur = downsample(cur)
ktx2(os.path.join(fixtures, "checker_astc6x5.ktx2"), 164, levels6x5, SIZE)   # VK_FORMAT_ASTC_6x5_SRGB_BLOCK
flat = lambda rows: bytes(v for row in rows for t in row for v in t)
open(os.path.join(fixtures, "ktx2_expected.zlib"), "wb").write(
    zlib.compress(flat(expected_bc1) + flat(expected_6x5), 9))

# Shipped zlib-compressed (.ktx2.zlib; the Textures example and the tests
# inflate them with fflate's unzlibSync): `rive push` rejects KTX2 content in
# blob assets with HTTP 400.
for name, folder in (("checker_bc1", out), ("checker_astc", out), ("checker_astc6x5", fixtures)):
    path = os.path.join(folder, name + ".ktx2")
    data = open(path, "rb").read()
    open(path + ".zlib", "wb").write(zlib.compress(data, 9))
    os.remove(path)
    sample_paths.copy(name + ".ktx2.zlib")
print("wrote %s (%d levels), %s, %s (%d levels) and %s" % (
    sample_paths.rel("checker_bc1.ktx2.zlib"), len(chain), sample_paths.rel("checker_astc.ktx2.zlib"),
    sample_paths.rel("checker_astc6x5.ktx2.zlib"), len(levels6x5), sample_paths.rel("ktx2_expected.zlib")))
