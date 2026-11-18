"""Writes examples/assets/studio_rgbe.hdr (Radiance RGBE, run-length encoded) and
examples/assets/studio_exr.exr (OpenEXR, ZIP, half RGB): the Environment
example's studio as linear HDR, softboxes at 6 and a warm key at 40.
Pure Python, no dependencies.

    python3 tools/make_hdr_samples.py [width]
"""
import math, os, struct, sys, zlib

def studio(lat, lon):
    if lat > 0:
        t = lat / (math.pi / 2)
        c = ((120 - 70 * t) / 255, (130 - 70 * t) / 255, (150 - 60 * t) / 255)
    else:
        c = (70 / 255, 62 / 255, 56 / 255)
    c = tuple(x ** 2.2 for x in c)   # the sRGB-ish bytes, linearised
    if abs(lat - 0.5) < 0.22 and (abs(lon - 0.9) < 0.35 or abs(lon + 1.6) < 0.3):
        c = (6.0, 6.0, 6.0)
    dl, dn = lat - 0.9, lon - 2.4
    if dl * dl + dn * dn < 0.05:
        c = (40.0, 30.0, 18.0)
    return c

def pixels(w, h):
    rows = []
    for y in range(h):   # top row first
        lat = math.pi / 2 - (y + 0.5) / h * math.pi
        rows.append([studio(lat, (x + 0.5) / w * 2 * math.pi - math.pi) for x in range(w)])
    return rows

def rgbe(c):
    m = max(c)
    if m < 1e-32:
        return (0, 0, 0, 0)
    f, e = math.frexp(m)
    s = f * 256.0 / m
    return (int(c[0] * s), int(c[1] * s), int(c[2] * s), e + 128)

def rle_channel(vals):
    out = bytearray()
    i = 0
    n = len(vals)
    while i < n:
        run = 1
        while i + run < n and run < 127 and vals[i + run] == vals[i]:
            run += 1
        if run >= 3:
            out += bytes([128 + run, vals[i]])
            i += run
        else:
            j = i
            while j < n and j - i < 128 and not (j + 2 < n and vals[j] == vals[j + 1] == vals[j + 2]):
                j += 1
            out += bytes([j - i]) + bytes(vals[i:j])
            i = j
    return out

def write_hdr(path, rows, w, h):
    out = bytearray(b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n" + ("-Y %d +X %d\n" % (h, w)).encode())
    for row in rows:
        px = [rgbe(c) for c in row]
        out += bytes([2, 2, w >> 8, w & 255])
        for ch in range(4):
            out += rle_channel([p[ch] for p in px])
    open(path, "wb").write(out)

def write_exr(path, rows, w, h):
    def attr(name, typ, data):
        return name.encode() + b"\0" + typ.encode() + b"\0" + struct.pack("<i", len(data)) + data
    chlist = b"".join(n.encode() + b"\0" + struct.pack("<iB3xii", 1, 0, 1, 1) for n in "BGR") + b"\0"
    header = struct.pack("<II", 20000630, 2)
    header += attr("channels", "chlist", chlist)
    header += attr("compression", "compression", bytes([3]))
    header += attr("dataWindow", "box2i", struct.pack("<iiii", 0, 0, w - 1, h - 1))
    header += attr("displayWindow", "box2i", struct.pack("<iiii", 0, 0, w - 1, h - 1))
    header += attr("lineOrder", "lineOrder", bytes([0]))
    header += attr("pixelAspectRatio", "float", struct.pack("<f", 1))
    header += attr("screenWindowCenter", "v2f", struct.pack("<ff", 0, 0))
    header += attr("screenWindowWidth", "float", struct.pack("<f", 1))
    header += b"\0"
    chunks = []
    for y0 in range(0, h, 16):
        raw = bytearray()
        for y in range(y0, min(y0 + 16, h)):
            for ch in (2, 1, 0):   # B G R
                raw += b"".join(struct.pack("<e", rows[y][x][ch]) for x in range(w))
        t = raw[0::2] + raw[1::2]
        p = bytearray(t)
        for i in range(len(t) - 1, 0, -1):
            p[i] = (t[i] - t[i - 1] + 128 + 256) & 255
        comp = zlib.compress(bytes(p), 9)
        data = comp if len(comp) < len(raw) else bytes(raw)
        chunks.append(struct.pack("<ii", y0, len(data)) + data)
    table_start = len(header)
    offsets = []
    pos = table_start + 8 * len(chunks)
    for c in chunks:
        offsets.append(pos)
        pos += len(c)
    open(path, "wb").write(header + b"".join(struct.pack("<Q", o) for o in offsets) + b"".join(chunks))

w = int(sys.argv[1]) if len(sys.argv) > 1 else 256
h = w // 2
rows = pixels(w, h)
out = os.path.join(os.path.dirname(__file__), "..", "examples", "assets")
write_hdr(os.path.join(out, "studio_rgbe.hdr"), rows, w, h)
write_exr(os.path.join(out, "studio_exr.exr"), rows, w, h)
print("wrote studio_rgbe.hdr and studio_exr.exr,", w, "x", h)
