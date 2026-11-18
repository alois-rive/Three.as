#!/usr/bin/env python3
"""Writes glTF samples for GLTFLoader's tests and the Models example:

  examples/assets/features.glb        EXT_meshopt_compression (attributes with
      octahedral, quaternion and exponential filters, triangles, indices),
      KHR_mesh_quantization, a sparse morph target, EXT_mesh_gpu_instancing,
      KHR_materials_transmission / volume / iridescence / anisotropy /
      dispersion / specular.
  examples/assets/features_embedded.gltf   .gltf JSON with a base64 buffer.

The meshopt encoder follows the EXT_meshopt_compression specification's
bitstream appendix; a decoder written from the same text checks every
stream round-trips before it is written.
"""
import base64, json, math, os, struct

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "examples", "assets")

# ------------------------------------------------------------ meshopt encode

def zigzag8(d):
    d &= 255
    return ((~(d << 1)) & 255) if d & 0x80 else (d << 1) & 255

def unzigzag8(v):
    return (~(v >> 1)) & 255 if v & 1 else v >> 1

def encode_group(deltas):
    """Smallest of the four group encodings: (bits, bytes)."""
    if all(d == 0 for d in deltas):
        return 0, b""
    best = (3, bytes(deltas))
    for bits, width in ((1, 2), (2, 4)):
        sentinel = (1 << width) - 1
        packed = bytearray(width * 2)
        extra = bytearray()
        for i, d in enumerate(deltas):
            v = d if d < sentinel else sentinel
            if v == sentinel:
                extra.append(d)
            bit = i * width
            packed[bit >> 3] |= v << (8 - width - (bit & 7))
        out = bytes(packed) + bytes(extra)
        if len(out) < len(best[1]):
            best = (bits, out)
    return best

def encode_attributes(data, count, stride):
    assert stride % 4 == 0 and stride <= 256 and len(data) == count * stride
    out = bytearray([0xA0])
    last = bytearray(data[0:stride])  # baseline: the first element
    max_block = min((8192 // stride) & ~15, 256)
    done = 0
    while done < count:
        block = min(count - done, max_block)
        groups = (block + 15) // 16
        for k in range(stride):
            deltas = []
            prev = last[k]
            for i in range(groups * 16):
                if i < block:
                    v = data[(done + i) * stride + k]
                    deltas.append(zigzag8(v - prev))
                    prev = v
                else:
                    deltas.append(0)
            last[k] = prev
            header = bytearray((groups + 3) // 4)
            body = bytearray()
            for g in range(groups):
                bits, enc = encode_group(deltas[g * 16:(g + 1) * 16])
                header[g >> 2] |= bits << ((g & 3) * 2)
                body += enc
            out += header + body
        done += block
    tail = max(32, stride)
    out += bytes(tail - stride) + bytes(data[0:stride])
    return bytes(out)

def decode_attributes(src, count, stride):
    assert src[0] == 0xA0
    tail = max(32, stride)
    end = len(src) - tail
    last = bytearray(src[len(src) - stride:])
    out = bytearray(count * stride)
    max_block = min((8192 // stride) & ~15, 256)
    pos, done = 1, 0
    while done < count:
        block = min(count - done, max_block)
        groups = (block + 15) // 16
        for k in range(stride):
            header = pos
            pos += (groups + 3) // 4
            deltas = []
            for g in range(groups):
                bits = (src[header + (g >> 2)] >> ((g & 3) * 2)) & 3
                if bits == 0:
                    deltas += [0] * 16
                elif bits == 3:
                    deltas += list(src[pos:pos + 16]); pos += 16
                else:
                    width = 2 if bits == 1 else 4
                    sentinel = (1 << width) - 1
                    extra = pos + width * 2
                    for i in range(16):
                        bit = i * width
                        v = (src[pos + (bit >> 3)] >> (8 - width - (bit & 7))) & sentinel
                        if v == sentinel:
                            v = src[extra]; extra += 1
                        deltas.append(v)
                    pos = extra
            p = last[k]
            for i in range(block):
                p = (p + unzigzag8(deltas[i])) & 255
                out[(done + i) * stride + k] = p
            last[k] = p
        done += block
    assert pos == end, (pos, end)
    return bytes(out)

def varint(v):
    out = bytearray()
    while True:
        b = v & 127
        v >>= 7
        if v:
            out.append(b | 128)
        else:
            out.append(b)
            return bytes(out)

def zigzag32(d):
    return ((d << 1) ^ (d >> 31)) & 0xFFFFFFFF

CODEAUX = bytes([0x00, 0x76, 0x87, 0x56, 0x67, 0x78, 0xA9, 0x86, 0x65, 0x89, 0x68, 0x98, 0x01, 0x69, 0, 0])

class TriState:
    def __init__(self):
        self.edges = [(0, 0)] * 16
        self.eo = 0
        self.verts = [0] * 16
        self.vo = 0
        self.next = 0
        self.last = 0
    def push_edge(self, a, b):
        self.edges[self.eo] = (a, b); self.eo = (self.eo + 1) & 15
    def push_vert(self, v):
        self.verts[self.vo] = v; self.vo = (self.vo + 1) & 15
    def edge(self, x):
        return self.edges[(self.eo - 1 - x) & 15]
    def vert(self, y):
        return self.verts[(self.vo - 1 - y) & 15]

def encode_triangles(indices):
    s = TriState()
    codes, data = bytearray(), bytearray()
    def explicit(v):
        nonlocal data
        data += varint(zigzag32(v - s.last))
        s.last = v
    for t in range(0, len(indices), 3):
        tri = indices[t:t + 3]
        rots = [(tri[0], tri[1], tri[2]), (tri[1], tri[2], tri[0]), (tri[2], tri[0], tri[1])]
        done = False
        for x in range(15):
            for a, b, c in rots:
                if s.edge(x) != (a, b):
                    continue
                if c == s.next:
                    codes.append(x << 4); s.next += 1; s.push_vert(c)
                else:
                    y = next((y for y in range(1, 13) if s.vert(y) == c), None)
                    if y is not None:
                        codes.append((x << 4) | y)
                    elif c == s.last - 1 or c == s.last + 1:
                        codes.append((x << 4) | (0xD if c == s.last - 1 else 0xE)); s.last = c; s.push_vert(c)
                    else:
                        codes.append((x << 4) | 0xF); explicit(c); s.push_vert(c)
                s.push_edge(c, b); s.push_edge(a, c)
                done = True
                break
            if done:
                break
        if done:
            continue
        # No shared edge: rotate so that a == next when possible.
        a, b, c = next((r for r in rots if r[0] == s.next), rots[0])
        if a == s.next:
            nxt = s.next + 1
            def pick(v, nxt):
                if v == nxt:
                    return 0, nxt + 1
                y = next((y for y in range(0, 14) if s.vert(y) == v), None)
                return (y + 1 if y is not None else None), nxt
            z, n2 = pick(b, nxt)
            w, n3 = pick(c, n2) if z is not None else (None, n2)
            code = ((z << 4) | w) if (z is not None and w is not None) else None
            if code is not None and code in CODEAUX[:14]:
                codes.append(0xF0 | CODEAUX.index(code))
                s.next = n3
                s.push_vert(a)
                if z == 0: s.push_vert(b)
                if w == 0: s.push_vert(c)
                s.push_edge(b, a); s.push_edge(c, b); s.push_edge(a, c)
                continue
        # Explicit (0xfe when a is next, 0xff otherwise).
        fe = a == s.next
        nxt = s.next + 1 if fe else s.next
        def pick2(v, nxt):
            if v == nxt:
                return 0, nxt + 1
            y = next((y for y in range(0, 14) if s.vert(y) == v), None)
            return (y + 1, nxt) if y is not None else (0xF, nxt)
        # The vertex FIFO is read before anything is pushed for this triangle.
        z, n2 = pick2(b, nxt)
        w, n3 = pick2(c, n2)
        if z == 0 and w == 0:
            w, n3 = 0xF, n2   # 0x00 would reset next
        codes.append(0xFE if fe else 0xFF)
        data.append((z << 4) | w)
        if fe:
            s.next += 1
        else:
            explicit(a)
        if z == 0: s.next += 1
        elif z == 0xF: explicit(b)
        if w == 0: s.next += 1
        elif w == 0xF: explicit(c)
        s.push_vert(a)
        if z in (0, 0xF): s.push_vert(b)
        if w in (0, 0xF): s.push_vert(c)
        s.push_edge(b, a); s.push_edge(c, b); s.push_edge(a, c)
    return bytes([0xE1]) + bytes(codes) + bytes(data) + CODEAUX

def decode_triangles(src, count):
    assert src[0] == 0xE1
    s = TriState()
    aux = src[len(src) - 16:]
    cp, dp = 1, 1 + count // 3
    def read_index():
        nonlocal dp
        v, shift = 0, 0
        while True:
            b = src[dp]; dp += 1
            v |= (b & 127) << shift; shift += 7
            if b < 128: break
        d = ~(v >> 1) if v & 1 else v >> 1
        s.last += d
        return s.last
    out = []
    for _ in range(count // 3):
        code = src[cp]; cp += 1
        hi, lo = code >> 4, code & 15
        if hi < 15:
            a, b = s.edge(hi)
            if lo == 0:
                c = s.next; s.next += 1; s.push_vert(c)
            elif lo < 0xD:
                c = s.vert(lo)
            elif lo < 0xF:
                c = s.last - 1 if lo == 0xD else s.last + 1; s.last = c; s.push_vert(c)
            else:
                c = read_index(); s.push_vert(c)
            s.push_edge(c, b); s.push_edge(a, c)
        else:
            if lo < 0xE:
                zw = aux[lo]; explicit = False
                a = s.next; s.next += 1
            else:
                explicit = True
                zw = src[dp]; dp += 1
                if zw == 0: s.next = 0
                if lo == 0xE:
                    a = s.next; s.next += 1
                else:
                    a = read_index()
            z, w = zw >> 4, zw & 15
            fifo = list(s.verts); vo = s.vo
            def get(n):
                if n == 0:
                    v = s.next; s.next += 1; return v
                if n < 15 or not explicit:
                    return fifo[(vo - n) & 15]
                return read_index()
            b = get(z); c = get(w)
            s.push_vert(a)
            if z in (0, 15): s.push_vert(b)
            if w in (0, 15): s.push_vert(c)
            s.push_edge(b, a); s.push_edge(c, b); s.push_edge(a, c)
        out += [a, b, c]
    assert dp == len(src) - 16, (dp, len(src) - 16)
    return out

def encode_indices(seq):
    out = bytearray([0xD1])
    last = [0, 0]
    for i, v in enumerate(seq):
        base = i & 1   # alternate baselines to exercise both
        d = v - last[base]
        zz = ((d << 1) ^ (d >> 31)) & 0x7FFFFFFF
        out += varint((zz << 1) | base)
        last[base] = v
    return bytes(out) + bytes(4)

def same_triangles(a, b):
    """Equal up to each triangle's rotation (the codec keeps the winding)."""
    def canon(t):
        r = [tuple(t), (t[1], t[2], t[0]), (t[2], t[0], t[1])]
        return min(r)
    return len(a) == len(b) and all(canon(a[i:i + 3]) == canon(b[i:i + 3]) for i in range(0, len(a), 3))

# ------------------------------------------------------------ geometry

def torus(R=0.6, r=0.25, seg=24, sides=12):
    pos, nrm, uv, idx = [], [], [], []
    for i in range(seg + 1):
        u = i / seg * 2 * math.pi
        for j in range(sides + 1):
            v = j / sides * 2 * math.pi
            cx, cz = math.cos(u), math.sin(u)
            nx, ny, nz = math.cos(v) * cx, math.sin(v), math.cos(v) * cz
            pos.append(((R + r * math.cos(v)) * cx, r * math.sin(v), (R + r * math.cos(v)) * cz))
            nrm.append((nx, ny, nz))
            uv.append((i / seg, j / sides))
    for i in range(seg):
        for j in range(sides):
            a = i * (sides + 1) + j
            b = a + sides + 1
            idx += [a, b, a + 1, b, b + 1, a + 1]
    return pos, nrm, uv, idx

def oct_encode(n):
    x, y, z = n
    s = abs(x) + abs(y) + abs(z)
    x, y, z = x / s, y / s, z / s
    if z < 0:
        x, y = (1 - abs(y)) * (1 if x >= 0 else -1), (1 - abs(x)) * (1 if y >= 0 else -1)
    return (round(x * 127), round(y * 127), 127, 0)

def quat_encode(q):
    m = max(range(4), key=lambda i: abs(q[i]))
    if q[m] < 0:
        q = [-c for c in q]
    one = 32767
    comps = [q[(m + k) % 4] for k in (1, 2, 3)]
    enc = [round(c * math.sqrt(2) * one) for c in comps]
    return enc + [(one & ~3) | m]

def exp_encode(v, e=-15):
    m = round(v * (2 ** -e))
    return ((e & 255) << 24) | (m & 0xFFFFFF)

# ------------------------------------------------------------ glb

class Builder:
    def __init__(self):
        self.bin = bytearray()
        self.views, self.accessors = [], []
    def add(self, data, align=4):
        while len(self.bin) % align:
            self.bin.append(0)
        off = len(self.bin)
        self.bin += data
        return off
    def view(self, data, stride=None, target=None):
        off = self.add(data)
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if stride: v["byteStride"] = stride
        if target: v["target"] = target
        self.views.append(v)
        return len(self.views) - 1
    def meshopt_view(self, raw, count, stride, mode, flt="NONE", target=None, byte_stride=True):
        if mode == "ATTRIBUTES":
            enc = encode_attributes(raw, count, stride)
            assert decode_attributes(enc, count, stride) == raw
        elif mode == "TRIANGLES":
            idx = list(struct.unpack("<%d%s" % (count, "H" if stride == 2 else "I"), raw))
            enc = encode_triangles(idx)
            assert same_triangles(decode_triangles(enc, count), idx), "triangle codec round trip"
        else:
            idx = list(struct.unpack("<%d%s" % (count, "H" if stride == 2 else "I"), raw))
            enc = encode_indices(idx)
        off = self.add(enc)
        ext = {"buffer": 0, "byteOffset": off, "byteLength": len(enc), "byteStride": stride, "count": count, "mode": mode}
        if flt != "NONE": ext["filter"] = flt
        v = {"buffer": 1, "byteOffset": self.fallback, "byteLength": count * stride,
             "extensions": {"EXT_meshopt_compression": ext}}
        self.fallback += (count * stride + 3) & ~3
        if byte_stride and mode == "ATTRIBUTES": v["byteStride"] = stride
        if target: v["target"] = target
        self.views.append(v)
        return len(self.views) - 1
    def accessor(self, view, ct, count, type, normalized=False, mn=None, mx=None, offset=0):
        a = {"bufferView": view, "componentType": ct, "count": count, "type": type}
        if offset: a["byteOffset"] = offset
        if normalized: a["normalized"] = True
        if mn is not None: a["min"] = mn; a["max"] = mx
        self.accessors.append(a)
        return len(self.accessors) - 1

def build():
    b = Builder()
    b.fallback = 0
    pos, nrm, uv, idx = torus()
    n = len(pos)
    mn = [min(p[i] for p in pos) for i in range(3)]
    mx = [max(p[i] for p in pos) for i in range(3)]

    # Mesh 0 (meshopt): float positions, octahedral int8 normals,
    # exponential uvs, triangle-coded indices.
    raw_pos = b"".join(struct.pack("<3f", *p) + b"\0\0\0\0" for p in pos)   # stride 16
    v_pos = b.meshopt_view(raw_pos, n, 16, "ATTRIBUTES", target=34962)
    raw_nrm = b"".join(struct.pack("<4b", *oct_encode(q)) for q in nrm)
    v_nrm = b.meshopt_view(raw_nrm, n, 4, "ATTRIBUTES", "OCTAHEDRAL", target=34962)
    raw_uv = b"".join(struct.pack("<2I", exp_encode(t[0]), exp_encode(t[1])) for t in uv)
    v_uv = b.meshopt_view(raw_uv, n, 8, "ATTRIBUTES", "EXPONENTIAL", target=34962)
    raw_idx = struct.pack("<%dH" % len(idx), *idx)
    v_idx = b.meshopt_view(raw_idx, len(idx), 2, "TRIANGLES", target=34963)
    a_pos = b.accessor(v_pos, 5126, n, "VEC3", mn=mn, mx=mx)
    a_nrm = b.accessor(v_nrm, 5120, n, "VEC3", normalized=True)
    a_uv = b.accessor(v_uv, 5126, n, "VEC2")
    a_idx = b.accessor(v_idx, 5123, len(idx), "SCALAR")

    # Mesh 1 (meshopt INDICES): the torus's ring lines.
    lines = []
    for i in range(0, n - 1):
        if (i + 1) % 13: lines += [i, i + 1]
    v_lines = b.meshopt_view(struct.pack("<%dI" % len(lines), *lines), len(lines), 4, "INDICES", target=34963)
    a_lines = b.accessor(v_lines, 5125, len(lines), "SCALAR")

    # Mesh 2 (KHR_mesh_quantization): int16 positions (node scale undoes it),
    # int8 normals, uint16 normalized uvs; a sparse morph target.
    q = 1 / 32767 * 1.0
    raw_qpos = b"".join(struct.pack("<3h", *(round(c / 0.9 * 32767) for c in p)) + b"\0\0" for p in pos)
    v_qpos = b.view(raw_qpos, stride=8, target=34962)
    a_qpos = b.accessor(v_qpos, 5122, n, "VEC3", normalized=True,
                        mn=[round(c / 0.9 * 32767) / 32767 for c in mn], mx=[round(c / 0.9 * 32767) / 32767 for c in mx])
    v_qnrm = b.view(b"".join(struct.pack("<3b", *(round(c * 127) for c in q3)) + b"\0" for q3 in nrm), stride=4, target=34962)
    a_qnrm = b.accessor(v_qnrm, 5120, n, "VEC3", normalized=True)
    v_quv = b.view(b"".join(struct.pack("<2H", round(t[0] * 65535), round(t[1] * 65535)) for t in uv), stride=4, target=34962)
    a_quv = b.accessor(v_quv, 5123, n, "VEC2", normalized=True)
    v_qidx = b.view(struct.pack("<%dH" % len(idx), *idx), target=34963)
    a_qidx = b.accessor(v_qidx, 5123, len(idx), "SCALAR")
    sparse_ids = [0, 5, 77]
    v_sid = b.view(struct.pack("<3H", *sparse_ids))
    v_sval = b.view(struct.pack("<9f", 0, 0.5, 0, 0.25, 0, 0, 0, 0, -1))
    a_morph = len(b.accessors)
    b.accessors.append({"componentType": 5126, "count": n, "type": "VEC3", "min": [0, 0, -1], "max": [0.25, 0.5, 0],
                        "sparse": {"count": 3, "indices": {"bufferView": v_sid, "componentType": 5123},
                                   "values": {"bufferView": v_sval}}})

    # Instancing (EXT_mesh_gpu_instancing): 5 instances in a row.
    v_it = b.view(b"".join(struct.pack("<3f", (i - 2) * 1.6, 0, 0) for i in range(5)))
    a_it = b.accessor(v_it, 5126, 5, "VEC3")
    v_is = b.view(b"".join(struct.pack("<3f", s, s, s) for s in (0.5, 0.7, 0.9, 0.7, 0.5)))
    a_is = b.accessor(v_is, 5126, 5, "VEC3")
    v_ic = b.view(b"".join(struct.pack("<3f", *c) for c in ((1, .3, .3), (1, .8, .3), (.3, 1, .4), (.3, .6, 1), (.8, .4, 1))))
    a_ic = b.accessor(v_ic, 5126, 5, "VEC3")

    # Animation: a meshopt quaternion-filtered rotation track.
    times = [0, 1, 2, 3, 4]
    v_t = b.view(struct.pack("<5f", *times))
    a_t = b.accessor(v_t, 5126, 5, "SCALAR", mn=[0], mx=[4])
    quats = []
    for t in times:
        ang = t / 4 * 2 * math.pi
        quats.append([0, math.sin(ang / 2), 0, math.cos(ang / 2)])
    raw_q = b"".join(struct.pack("<4h", *quat_encode(qq)) for qq in quats)
    v_q = b.meshopt_view(raw_q, 5, 8, "ATTRIBUTES", "QUATERNION")
    a_q = b.accessor(v_q, 5122, 5, "VEC4", normalized=True)

    gltf = {
        "asset": {"version": "2.0", "generator": "ThreeAS tools/make_gltf_samples.py"},
        "extensionsUsed": ["EXT_meshopt_compression", "KHR_mesh_quantization", "EXT_mesh_gpu_instancing",
                           "KHR_materials_transmission", "KHR_materials_volume", "KHR_materials_iridescence",
                           "KHR_materials_anisotropy", "KHR_materials_dispersion", "KHR_materials_specular",
                           "KHR_materials_ior"],
        "extensionsRequired": ["EXT_meshopt_compression", "KHR_mesh_quantization"],
        "scene": 0,
        "scenes": [{"nodes": [0, 1, 2, 3]}],
        "nodes": [
            {"name": "Glass", "mesh": 0, "translation": [0, 1.2, 0]},
            {"name": "Rings", "mesh": 1, "translation": [0, 1.2, 0]},
            {"name": "Quantized", "mesh": 2, "translation": [0, -0.2, 0], "scale": [0.9, 0.9, 0.9]},
            {"name": "Row", "mesh": 3, "translation": [0, -1.6, 0],
             "extensions": {"EXT_mesh_gpu_instancing": {"attributes": {"TRANSLATION": a_it, "SCALE": a_is, "_COLOR_0": a_ic}}}},
        ],
        "meshes": [
            {"name": "Glass", "primitives": [{"attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv},
                                              "indices": a_idx, "material": 0}]},
            {"name": "Rings", "primitives": [{"attributes": {"POSITION": a_pos}, "indices": a_lines, "mode": 1, "material": 2}]},
            {"name": "Quantized", "primitives": [{"attributes": {"POSITION": a_qpos, "NORMAL": a_qnrm, "TEXCOORD_0": a_quv},
                                                  "indices": a_qidx, "material": 1, "targets": [{"POSITION": a_morph}]}],
             "weights": [1], "extras": {"targetNames": ["Bump"]}},
            {"name": "Row", "primitives": [{"attributes": {"POSITION": a_qpos, "NORMAL": a_qnrm}, "indices": a_qidx, "material": 3}]},
        ],
        "materials": [
            {"name": "Glass", "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 0.05},
             "extensions": {"KHR_materials_transmission": {"transmissionFactor": 1},
                            "KHR_materials_volume": {"thicknessFactor": 0.4, "attenuationDistance": 0.8,
                                                     "attenuationColor": [0.6, 0.9, 1.0]},
                            "KHR_materials_ior": {"ior": 1.45},
                            "KHR_materials_dispersion": {"dispersion": 0.3}}},
            {"name": "Pearl", "pbrMetallicRoughness": {"baseColorFactor": [0.9, 0.9, 0.95, 1], "metallicFactor": 0.2, "roughnessFactor": 0.3},
             "extensions": {"KHR_materials_iridescence": {"iridescenceFactor": 1, "iridescenceIor": 1.4,
                                                          "iridescenceThicknessMinimum": 200, "iridescenceThicknessMaximum": 600},
                            "KHR_materials_specular": {"specularFactor": 0.8, "specularColorFactor": [1, 0.9, 0.8]}}},
            {"name": "Lines", "pbrMetallicRoughness": {"baseColorFactor": [1.0, 0.75, 0.2, 1]}},
            {"name": "Brushed", "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 1, "roughnessFactor": 0.35},
             "extensions": {"KHR_materials_anisotropy": {"anisotropyStrength": 0.8, "anisotropyRotation": 0.5}}},
        ],
        "animations": [{"name": "Spin", "channels": [{"sampler": 0, "target": {"node": 0, "path": "rotation"}}],
                        "samplers": [{"input": a_t, "output": a_q, "interpolation": "LINEAR"}]}],
        "accessors": b.accessors,
        "bufferViews": b.views,
    }
    while len(b.bin) % 4:
        b.bin.append(0)
    gltf["buffers"] = [{"byteLength": len(b.bin)},
                       {"byteLength": b.fallback, "extensions": {"EXT_meshopt_compression": {"fallback": True}}}]
    js = json.dumps(gltf, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    glb = struct.pack("<3I", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(b.bin))
    glb += struct.pack("<2I", len(js), 0x4E4F534A) + js + struct.pack("<2I", len(b.bin), 0x004E4942) + bytes(b.bin)
    with open(os.path.join(ASSETS, "features.glb"), "wb") as f:
        f.write(glb)
    print("features.glb", len(glb), "bytes")

def build_embedded():
    """A .gltf with one base64 buffer: a triangle with a colour per vertex."""
    pos = struct.pack("<9f", 0, 0, 0, 1, 0, 0, 0, 1, 0)
    col = struct.pack("<9f", 1, 0, 0, 0, 1, 0, 0, 0, 1)
    data = pos + col
    gltf = {
        "asset": {"version": "2.0"},
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "Triangle", "mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "COLOR_0": 1}}]}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]},
            {"bufferView": 0, "byteOffset": 36, "componentType": 5126, "count": 3, "type": "VEC3"},
        ],
        "bufferViews": [{"buffer": 0, "byteLength": len(data)}],
        "buffers": [{"byteLength": len(data),
                     "uri": "data:application/octet-stream;base64," + base64.b64encode(data).decode()}],
    }
    with open(os.path.join(ASSETS, "features_embedded.gltf"), "w") as f:
        json.dump(gltf, f, indent=1)
    print("features_embedded.gltf")

if __name__ == "__main__":
    # Codec self-checks on edge cases first.
    for count, stride in ((1, 4), (17, 8), (300, 12), (513, 4)):
        raw = bytes((i * 7 + (i // stride) * 3) & 255 for i in range(count * stride))
        assert decode_attributes(encode_attributes(raw, count, stride), count, stride) == raw
    tris = [0, 1, 2, 2, 1, 3, 4, 5, 6, 0, 2, 7, 9, 3, 1, 8, 8, 8, 3, 4, 0]
    assert same_triangles(decode_triangles(encode_triangles(tris), len(tris)), tris)
    build()
    build_embedded()
