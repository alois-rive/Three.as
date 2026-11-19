"""Writes packages/threeas/tests/fixtures/texture_vectors.bin.zlib: blocks of
every compressed format the CPU decoders read (packages/threeas/three/
textures/decoders/) with the texels a GPU's own decoder produced for them,
for tests/texture_decoders_test.as. macOS on Apple silicon only: it builds
tools/gpu_decode_reference.swift and samples the blocks with Metal.

    python3 tools/make_texture_vectors.py [--seed N] [--report]

Blocks are random bytes for BC1-5, ETC2 and EAC (every bit pattern is a
valid block there), random bytes with a chosen mode for BC7, and random
valid LDR encodings for ASTC (tools/astc_encode.py packs them: every
footprint, 1 to 4 partitions, dual planes, every LDR endpoint mode, weight
grids smaller than the block, every weight and colour range), plus
void-extent blocks.

The file (zlib-compressed, little endian):
    "TXV1", u32 record count, then per record:
    i32 three.js format, u8 sRGB, u8 block width, u8 block height,
    u8 block bytes, u8 tolerance, u8 kind, u16 block count,
    the blocks, then the expected texels, block by block, rows first, RGBA:
    kind 0 as u8 (tolerance in 8-bit steps), kind 1 (signed formats) as
    i16 of value * 16384 (tolerance in 1/255 steps).
"""
import os, random, struct, subprocess, sys, zlib

import astc_encode as astc
import sample_paths

ROOT = sample_paths.ROOT
HARNESS = os.path.join(ROOT, "build", "gpu_decode_reference")

# three.js formats (packages/threeas/three/constants.as).
F = dict(DXT1_RGB=33776, DXT1_RGBA=33777, DXT3=33778, DXT5=33779, BPTC=36492, RGTC1=36283, RGTC1_S=36284,
         RGTC2=36285, RGTC2_S=36286, ETC2_RGB=37492, ETC2_A1=37494, ETC2_RGBA=37496, R11=37488, R11_S=37489,
         RG11=37490, RG11_S=37491)
ASTC_FOOTPRINTS = [(4, 4), (5, 4), (5, 5), (6, 5), (6, 6), (8, 5), (8, 6), (8, 8), (10, 5), (10, 6), (10, 8),
                   (10, 10), (12, 10), (12, 12)]


def build_harness():
    src = os.path.join(ROOT, "tools", "gpu_decode_reference.swift")
    if not os.path.exists(HARNESS) or os.path.getmtime(HARNESS) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(HARNESS), exist_ok=True)
        subprocess.check_call(["swiftc", "-O", src, "-o", HARNESS])


def gpu_decode(metal, bw, bh, bb, blocks):
    tmp = os.path.join(ROOT, "build", "vectors")
    os.makedirs(tmp, exist_ok=True)
    src, dst = os.path.join(tmp, "in.bin"), os.path.join(tmp, "out.bin")
    open(src, "wb").write(b"".join(blocks))
    subprocess.check_call([HARNESS, metal, str(bw), str(bh), str(bb), src, dst])
    data = open(dst, "rb").read()
    return struct.unpack("<%df" % (len(data) // 4), data)


def srgb_to_linear(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


SRGB_TABLE = [srgb_to_linear(k) for k in range(256)]


def to8(f, srgb):
    if srgb:
        return min(range(256), key=lambda k: abs(SRGB_TABLE[k] - f))
    return max(0, min(255, int(round(f * 255))))


def rand_bytes(rng, n):
    return bytes(rng.randrange(256) for _ in range(n))


def bc7_block(rng, mode):
    v = int.from_bytes(rand_bytes(rng, 16), "little")
    v = (v >> (mode + 1) << (mode + 1)) | (1 << mode)
    return v.to_bytes(16, "little")


LDR_CEMS = [0, 1, 4, 5, 6, 8, 9, 10, 12, 13]
# Stress runs (not for the fixture): VECTOR_SCALE=20 RANDOM_ASTC=200.
RANDOM_ASTC = int(os.environ.get("RANDOM_ASTC", "1"))
SCALE = int(os.environ.get("VECTOR_SCALE", "1"))


def astc_random_block(rng, bw, bh):
    """A random valid LDR block of the footprint (its parameters too)."""
    while True:
        partitions = rng.choice([1, 1, 1, 2, 2, 3, 4])
        dual = partitions < 4 and rng.random() < 0.3
        if partitions == 1 or rng.random() < 0.5:
            cems = [rng.choice(LDR_CEMS)] * partitions
        else:
            cls = rng.randrange(3)
            pool = [c for c in LDR_CEMS if c >> 2 in (cls, cls + 1)]
            cems = [rng.choice(pool) for _ in range(partitions)]
        xw, yw = rng.randint(2, min(bw, 12)), rng.randint(2, min(bh, 12))
        wq = rng.randrange(12)
        lay = astc.layout(xw, yw, dual, wq, partitions, cems)
        if lay is None:
            continue
        cq, count, _ = lay
        colors = [rng.randrange(astc.level_range(cq)) for _ in range(count)]
        weights = [rng.randrange(astc.level_range(wq)) for _ in range(xw * yw * (2 if dual else 1))]
        return astc.pack_block(xw, yw, dual, wq, partitions, rng.randrange(1024), cems, colors, weights,
                               rng.randrange(4))


def records(rng):
    """(name, format, metal format, bw, bh, bytes, sRGB, tolerance, kind, blocks)"""
    out = []
    def add(name, fmt, metal, bb, n, tol=0, kind=0, gen=None, srgb=False, bw=4, bh=4):
        n *= SCALE
        blocks = [gen() if gen else rand_bytes(rng, bb) for _ in range(n)]
        out.append((name, fmt, metal, bw, bh, bb, srgb, tol, kind, blocks))
    add("BC1 RGBA", F["DXT1_RGBA"], "bc1_rgba", 8, 24, tol=2)
    add("BC1 RGB", F["DXT1_RGB"], "bc1_rgba", 8, 8, tol=2)
    add("BC2", F["DXT3"], "bc2_rgba", 16, 12, tol=2)
    add("BC3", F["DXT5"], "bc3_rgba", 16, 24, tol=2)
    add("BC4", F["RGTC1"], "bc4_rUnorm", 8, 16, tol=2)
    add("BC4 signed", F["RGTC1_S"], "bc4_rSnorm", 8, 12, tol=4, kind=1)
    add("BC5", F["RGTC2"], "bc5_rgUnorm", 16, 12, tol=2)
    add("BC5 signed", F["RGTC2_S"], "bc5_rgSnorm", 16, 8, tol=4, kind=1)
    modes = [m for m in range(8) for _ in range(8 * SCALE)]
    add("BC7", F["BPTC"], "bc7_rgbaUnorm", 16, len(modes) // SCALE + 2,
        gen=lambda: bc7_block(rng, modes.pop()) if modes else bytes(16))
    add("ETC2 RGB8", F["ETC2_RGB"], "etc2_rgb8", 8, 32)
    add("ETC2 RGB8A1", F["ETC2_A1"], "etc2_rgb8a1", 8, 32)
    add("ETC2 RGBA8", F["ETC2_RGBA"], "eac_rgba8", 16, 16)
    add("EAC R11", F["R11"], "eac_r11Unorm", 8, 12, tol=1)
    add("EAC R11 signed", F["R11_S"], "eac_r11Snorm", 8, 8, tol=4, kind=1)
    add("EAC RG11", F["RG11"], "eac_rg11Unorm", 16, 8, tol=1)
    add("EAC RG11 signed", F["RG11_S"], "eac_rg11Snorm", 16, 8, tol=4, kind=1)
    for i, (bw, bh) in enumerate(ASTC_FOOTPRINTS):
        for srgb in (False, True):
            blocks = [astc_random_block(rng, bw, bh) for _ in range(3 * SCALE)]
            blocks.append(astc.void_extent([rng.randrange(65536) for _ in range(4)]))
            blocks += [rand_bytes(rng, 16) for _ in range(RANDOM_ASTC)]
            # Linear: Apple's GPU keeps 12 bits of the UNORM16 result, the
            # decoder rounds all 16 to 8 bits: one step apart at times.
            out.append(("ASTC %dx%d%s" % (bw, bh, " sRGB" if srgb else ""), 37808 + i,
                        "astc_%dx%d_%s" % (bw, bh, "srgb" if srgb else "ldr"), bw, bh, 16, srgb, 0 if srgb else 1, 0,
                        blocks))
    return out


def main():
    seed = 1
    if "--seed" in sys.argv:
        seed = int(sys.argv[sys.argv.index("--seed") + 1])
    rng = random.Random(seed)
    build_harness()
    recs = records(rng)
    body = bytearray()
    for name, fmt, metal, bw, bh, bb, srgb, tol, kind, blocks in recs:
        f = gpu_decode(metal, bw, bh, bb, blocks)
        body += struct.pack("<iBBBBBBH", fmt, srgb, bw, bh, bb, tol, kind, len(blocks))
        body += b"".join(blocks)
        texels = len(blocks) * bw * bh
        for t in range(texels):
            rgba = list(f[t * 4:t * 4 + 4])
            if kind == 1:
                body += struct.pack("<4h", *[int(round(max(-1.0, min(1.0, v)) * 16384)) for v in rgba])
            else:
                vals = [to8(rgba[c], srgb and c < 3) for c in range(4)]
                if fmt == F["DXT1_RGB"]:
                    vals[3] = 255   # opaque black where RGBA's is transparent
                body += bytes(vals)
        if "--report" in sys.argv:
            print("%-16s %4d blocks" % (name, len(blocks)))
    data = b"TXV1" + struct.pack("<I", len(recs)) + bytes(body)
    path = sample_paths.path("texture_vectors.bin.zlib")
    open(path, "wb").write(zlib.compress(data, 9))
    print("wrote %s (%d records, %d bytes, %d compressed)" % (os.path.relpath(path, ROOT), len(recs), len(data),
                                                             os.path.getsize(path)))


if __name__ == "__main__":
    main()
