"""Writes examples/assets/checker_bc1.ktx2 (BC1/DXT1, sRGB, full mip chain
down to 4x4) and examples/assets/checker_astc.ktx2 (ASTC 4x4, sRGB, one
level of constant-colour "void extent" blocks): a 64 x 64 coloured checker
for KTX2Loader. Pure Python, no dependencies.

    python3 tools/make_ktx2_samples.py
"""
import os, struct

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

def bc1(px):
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
            if c0 == c1:
                out += struct.pack("<HHI", c0, c1, 0)
                continue
            p0, p1 = from565(c0), from565(c1)
            pal = [p0, p1, tuple((2 * a + b) // 3 for a, b in zip(p0, p1)), tuple((a + 2 * b) // 3 for a, b in zip(p0, p1))]
            bits = 0
            for k, c in enumerate(block):
                best = min(range(4), key=lambda i: sum((c[j] - pal[i][j]) ** 2 for j in range(3)))
                bits |= best << (2 * k)
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

out = os.path.join(os.path.dirname(__file__), "..", "examples", "assets")
px = image(SIZE)
chain, cur = [], px
while True:
    chain.append(bc1(cur))
    if len(cur) <= 4:
        break
    cur = half(cur)
ktx2(os.path.join(out, "checker_bc1.ktx2"), 132, chain, SIZE)          # VK_FORMAT_BC1_RGB_SRGB_BLOCK
ktx2(os.path.join(out, "checker_astc.ktx2"), 158, [astc_void(px)], SIZE)   # VK_FORMAT_ASTC_4x4_SRGB_BLOCK
# Shipped zlib-compressed (.ktx2.zlib; the Textures example and the tests
# inflate them with fflate's unzlibSync): `rive push` rejects KTX2 content in
# blob assets with HTTP 400.
import zlib
for name in ("checker_bc1", "checker_astc"):
    path = os.path.join(out, name + ".ktx2")
    data = open(path, "rb").read()
    open(path + ".zlib", "wb").write(zlib.compress(data, 9))
    os.remove(path)
print("wrote checker_bc1.ktx2.zlib (%d levels) and checker_astc.ktx2.zlib" % len(chain))
