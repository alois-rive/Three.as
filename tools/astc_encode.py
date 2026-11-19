"""A small ASTC LDR block packer and encoder, written from the Khronos Data
Format Specification 1.3 ("ASTC"), for test vectors and samples
(tools/make_texture_vectors.py, tools/make_ktx2_samples.py). Pure Python,
no dependencies; not a production encoder.

- pack_block(...) lays out a block from chosen parameters: footprint,
  weight grid, weight range, dual plane, partitions and their seed, colour
  endpoint modes, and the integer-sequence values of the colours and
  weights. It writes the bits the way the specification reads them.
- void_extent(rgba16) is a constant-colour block.
- encode_image(pixels, bw, bh, srgb) encodes an RGBA8 image with one
  partition, a full-size weight grid and direct RGB(A) endpoints, and
  returns the blocks and the texels a decoder must produce for them
  (computed with the specification's interpolation, independently of the
  packing).
"""

# Ranges of the integer sequence encoding: (bits, trits, quints) per level.
LEVELS = [(1, 0, 0), (0, 1, 0), (2, 0, 0), (0, 0, 1), (1, 1, 0), (3, 0, 0), (1, 0, 1), (2, 1, 0), (4, 0, 0),
          (2, 0, 1), (3, 1, 0), (5, 0, 0), (3, 0, 1), (4, 1, 0), (6, 0, 0), (4, 0, 1), (5, 1, 0), (7, 0, 0),
          (5, 0, 1), (6, 1, 0), (8, 0, 0)]


def level_range(q):
    bits, trits, quints = LEVELS[q]
    return (3 if trits else 5 if quints else 1) << bits


def ise_bits(count, q):
    bits, trits, quints = LEVELS[q]
    n = bits * count
    if trits:
        n += (8 * count + 4) // 5
    if quints:
        n += (7 * count + 2) // 3
    return n


def _bit(v, i):
    return (v >> i) & 1


def decode_trits(T):
    """The five trits of an 8-bit T (the specification's procedure)."""
    if (T >> 2) & 7 == 7:
        C = (((T >> 5) & 7) << 2) | (T & 3)
        t4 = t3 = 2
    else:
        C = T & 31
        if (T >> 5) & 3 == 3:
            t4, t3 = 2, _bit(T, 7)
        else:
            t4, t3 = _bit(T, 7), (T >> 5) & 3
    if C & 3 == 3:
        t2, t1, t0 = 2, _bit(C, 4), (_bit(C, 3) << 1) | (_bit(C, 2) & (1 - _bit(C, 3)))
    elif (C >> 2) & 3 == 3:
        t2, t1, t0 = 2, 2, C & 3
    else:
        t2, t1, t0 = _bit(C, 4), (C >> 2) & 3, (_bit(C, 1) << 1) | (_bit(C, 0) & (1 - _bit(C, 1)))
    return (t0, t1, t2, t3, t4)


def decode_quints(Q):
    """The three quints of a 7-bit Q."""
    if (Q >> 1) & 3 == 3 and (Q >> 5) & 3 == 0:
        q2 = (_bit(Q, 0) << 2) | ((_bit(Q, 4) & (1 - _bit(Q, 0))) << 1) | (_bit(Q, 3) & (1 - _bit(Q, 0)))
        return (4, 4, q2)
    if (Q >> 1) & 3 == 3:
        q2 = 4
        C = (((Q >> 3) & 3) << 3) | ((~(Q >> 5) & 3) << 1) | (Q & 1)
    else:
        q2 = (Q >> 5) & 3
        C = Q & 31
    if C & 7 == 5:
        return ((C >> 3) & 3, 4, q2)
    return (C & 7, (C >> 3) & 3, q2)


TRIT_CODE = {}
for _T in range(256):
    TRIT_CODE.setdefault(decode_trits(_T), _T)
QUINT_CODE = {}
for _Q in range(128):
    QUINT_CODE.setdefault(decode_quints(_Q), _Q)
assert len(TRIT_CODE) == 243 and len(QUINT_CODE) == 125


def ise_encode(values, q):
    """The bits (a list, first bit first) of `values` in range level q."""
    bits, trits, quints = LEVELS[q]
    out = []

    def put(v, n):
        for i in range(n):
            out.append((v >> i) & 1)

    mask = (1 << bits) - 1
    if trits:
        for g in range(0, len(values), 5):
            vs = list(values[g:g + 5]) + [0] * (5 - len(values[g:g + 5]))
            T = TRIT_CODE[tuple(v >> bits for v in vs)]
            m = [v & mask for v in vs]
            put(m[0], bits); put(T, 2); put(m[1], bits); put(T >> 2, 2); put(m[2], bits)
            put(T >> 4, 1); put(m[3], bits); put(T >> 5, 2); put(m[4], bits); put(T >> 7, 1)
    elif quints:
        for g in range(0, len(values), 3):
            vs = list(values[g:g + 3]) + [0] * (3 - len(values[g:g + 3]))
            Q = QUINT_CODE[tuple(v >> bits for v in vs)]
            m = [v & mask for v in vs]
            put(m[0], bits); put(Q, 3); put(m[1], bits); put(Q >> 3, 2); put(m[2], bits); put(Q >> 5, 2)
    else:
        for v in values:
            put(v, bits)
    return out[:ise_bits(len(values), q)]


def decode_block_mode(bm):
    """(weight grid width, height, dual plane, weight range level) of an
    11-bit block mode, or None when reserved."""
    r = (bm >> 4) & 1
    h = (bm >> 9) & 1
    d = (bm >> 10) & 1
    a = (bm >> 5) & 3
    if bm & 3:
        r |= (bm & 3) << 1
        b = (bm >> 7) & 3
        k = (bm >> 2) & 3
        if k == 0:
            x, y = b + 4, a + 2
        elif k == 1:
            x, y = b + 8, a + 2
        elif k == 2:
            x, y = a + 2, b + 8
        else:
            b &= 1
            x, y = (b + 2, a + 2) if bm & 0x100 else (a + 2, b + 6)
    else:
        r |= ((bm >> 2) & 3) << 1
        if (bm >> 2) & 3 == 0:
            return None
        b = (bm >> 9) & 3
        k = (bm >> 7) & 3
        if k == 0:
            x, y = 12, a + 2
        elif k == 1:
            x, y = a + 2, 12
        elif k == 2:
            x, y, d, h = a + 6, b + 6, 0, 0
        else:
            if a == 0:
                x, y = 6, 10
            elif a == 1:
                x, y = 10, 6
            else:
                return None
    return (x, y, bool(d), r - 2 + 6 * h)


BLOCK_MODES = {}
for _bm in range(2048):
    if _bm & 0x1ff == 0x1fc:
        continue
    _m = decode_block_mode(_bm)
    if _m is not None:
        BLOCK_MODES.setdefault(_m, _bm)


def weight_layout_ok(xw, yw, dual, q):
    count = xw * yw * (2 if dual else 1)
    return (xw, yw, dual, q) in BLOCK_MODES and count <= 64 and 24 <= ise_bits(count, q) <= 96


def color_level(value_count, color_bits):
    """The colour range level the decoder picks, or None (an error block)."""
    for q in range(20, -1, -1):
        if ise_bits(value_count, q) <= color_bits:
            return q if q >= 4 else None
    return None


def layout(xw, yw, dual, wq, partitions, cems):
    """(colour level, colour bit count, extra CEM bits) of a layout, or
    None when it cannot be encoded."""
    if not weight_layout_ok(xw, yw, dual, wq) or (dual and partitions == 4):
        return None
    weight_bits = ise_bits(xw * yw * (2 if dual else 1), wq)
    extra = 0
    if partitions > 1 and len(set(cems)) > 1:
        base = min(c >> 2 for c in cems)
        if max(c >> 2 for c in cems) > base + 1:
            return None
        extra = 3 * partitions - 4
    below = 128 - weight_bits - extra - (2 if dual else 0)
    start = 17 if partitions == 1 else 29
    count = sum(((c >> 2) + 1) * 2 for c in cems)
    if count > 18:
        return None
    cq = color_level(count, below - start)
    if cq is None:
        return None
    return cq, count, extra


def pack_block(xw, yw, dual, wq, partitions, seed, cems, color_values, weight_values, ccs=0):
    """A 16-byte block. color_values are integers in the colour range level
    layout() gives; weight_values are xw * yw (twice that, interleaved, with
    a dual plane) integers in range level wq."""
    lay = layout(xw, yw, dual, wq, partitions, cems)
    assert lay is not None, "layout cannot be encoded"
    cq, count, extra = lay
    assert len(color_values) == count
    assert len(weight_values) == xw * yw * (2 if dual else 1)
    bits = [0] * 128

    def put(pos, v, n):
        for i in range(n):
            bits[pos + i] = (v >> i) & 1

    put(0, BLOCK_MODES[(xw, yw, dual, wq)], 11)
    put(11, partitions - 1, 2)
    weight_bits = ise_encode(weight_values, wq)
    below = 128 - len(weight_bits)
    if partitions == 1:
        put(13, cems[0], 4)
        start = 17
    else:
        put(13, seed, 10)
        start = 29
        if extra == 0:
            put(23, 0, 2)
            put(25, cems[0], 4)
        else:
            base = min(c >> 2 for c in cems)
            put(23, base + 1, 2)
            enc = 0
            for p, c in enumerate(cems):
                enc |= ((c >> 2) - base) << p
                enc |= (c & 3) << (partitions + 2 * p)
            put(25, enc & 15, 4)
            below -= extra
            put(below, enc >> 4, extra)
    if dual:
        below -= 2
        put(below, ccs, 2)
    cbits = ise_encode(color_values, cq)
    assert start + len(cbits) <= below
    for i, b in enumerate(cbits):
        bits[start + i] = b
    for i, b in enumerate(weight_bits):
        bits[127 - i] = b
    v = 0
    for i, b in enumerate(bits):
        v |= b << i
    return v.to_bytes(16, "little")


def void_extent(rgba16):
    """A constant-colour block (UNORM16 channels), extent all ones."""
    lo = 0x1fc | (1 << 10) | (1 << 11) | (0x1fff << 12) | (0x1fff << 25) | (0x1fff << 38) | (0x1fff << 51)
    hi = rgba16[0] | (rgba16[1] << 16) | (rgba16[2] << 32) | (rgba16[3] << 48)
    return lo.to_bytes(8, "little") + hi.to_bytes(8, "little")


# ---------------------------------------------------------------- unquantization

def unquantize_color(q, v):
    bits, trits, quints = LEVELS[q]
    if not trits and not quints:
        out, filled = 0, 0
        while filled < 8:
            out = (out << bits) | v
            filled += bits
        return out >> (filled - 8)
    D, m = v >> bits, v & ((1 << bits) - 1)
    A = 0x1ff if m & 1 else 0
    x = m >> 1
    if trits:
        C, B = {1: (204, 0), 2: (93, x * 0x116), 3: (44, (x << 7) | (x << 2) | x), 4: (22, (x << 6) | x),
                5: (11, (x << 5) | (x >> 2)), 6: (5, (x << 4) | (x >> 4))}[bits]
    else:
        C, B = {1: (113, 0), 2: (54, x * 0x10c), 3: (26, (x << 7) | (x << 1) | (x >> 1)), 4: (13, (x << 6) | (x >> 1)),
                5: (6, (x << 5) | (x >> 3))}[bits]
    T = (D * C + B) ^ A
    return (A & 0x80) | (T >> 2)


def unquantize_weight(q, v):
    bits, trits, quints = LEVELS[q]
    if not trits and not quints:
        out, filled = 0, 0
        while filled < 6:
            out = (out << bits) | v
            filled += bits
        out >>= filled - 6
    elif bits == 0:
        out = [0, 32, 63][v] if trits else [0, 16, 32, 47, 63][v]
    else:
        D, m = v >> bits, v & ((1 << bits) - 1)
        A = 0x7f if m & 1 else 0
        x = m >> 1
        if trits:
            C, B = {1: (50, 0), 2: (23, x * 0x45), 3: (11, (x << 5) | x)}[bits]
        else:
            C, B = {1: (28, 0), 2: (13, x * 0x42)}[bits]
        T = (D * C + B) ^ A
        out = (A & 0x20) | (T >> 2)
    return out + 1 if out > 32 else out


def interpolate(e0, e1, w, srgb):
    """The 8-bit texel channel between 8-bit endpoints e0, e1 at weight w
    (0..64): sRGB expands (e << 8) | 0x80 and keeps the top 8 bits; linear
    expands e * 257 and rounds the UNORM16 result to 8 bits."""
    if srgb:
        c0, c1 = (e0 << 8) | 0x80, (e1 << 8) | 0x80
    else:
        c0, c1 = e0 * 257, e1 * 257
    c = (c0 * (64 - w) + c1 * w + 32) >> 6
    return c >> 8 if srgb else (c * 255 + 32767) // 65535


# ---------------------------------------------------------------- encoder

def encode_image(px, bw, bh, srgb):
    """Encodes px (rows of (r, g, b, a) tuples) with one partition, a
    bw x bh weight grid and CEM 8 (RGB direct) or 12 (RGBA direct) at 8-bit
    endpoints, choosing 2-bit weights by projection onto the endpoint line.
    Returns (blocks, expected texels as rows of tuples)."""
    height, width = len(px), len(px[0])
    expected = [[None] * width for _ in range(height)]
    out = bytearray()
    wq = 2   # 4 levels: weights 0, 21, 43, 64
    for by in range(0, height, bh):
        for bx in range(0, width, bw):
            texels = [px[min(by + y, height - 1)][min(bx + x, width - 1)] for y in range(bh) for x in range(bw)]
            alpha = any(t[3] != 255 for t in texels)
            cem = 12 if alpha else 8
            lum = lambda t: t[0] * 3 + t[1] * 6 + t[2] + t[3]
            lo_t, hi_t = min(texels, key=lum), max(texels, key=lum)
            e0, e1 = list(lo_t), list(hi_t)
            # Keep the decoder's order (no blue contraction): sum(e1) >= sum(e0).
            if sum(e1[:3]) < sum(e0[:3]):
                e0, e1 = e1, e0
            weights = []
            d = [e1[c] - e0[c] for c in range(4)]
            dd = sum(x * x for x in d) or 1
            for t in texels:
                f = sum((t[c] - e0[c]) * d[c] for c in range(4)) / dd
                weights.append(max(0, min(3, int(round(f * 3)))))
            ch = 4 if alpha else 3
            colors = []
            for c in range(ch):
                colors += [e0[c], e1[c]]
            lay = layout(bw, bh, False, wq, 1, [cem])
            if lay is None or lay[0] != 20:
                raise ValueError("footprint %dx%d cannot hold 8-bit endpoints with 2-bit weights" % (bw, bh))
            out += pack_block(bw, bh, False, wq, 1, 0, [cem], colors, weights)
            if not alpha:
                e0[3] = e1[3] = 255
            for y in range(bh):
                for x in range(bw):
                    if by + y < height and bx + x < width:
                        w = unquantize_weight(wq, weights[y * bw + x])
                        expected[by + y][bx + x] = tuple(interpolate(e0[c], e1[c], w, srgb) for c in range(4))
    return bytes(out), expected
