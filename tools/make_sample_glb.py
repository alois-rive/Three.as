#!/usr/bin/env python3
"""Writes sample.glb (packages/gallery/examples/model/): a small glTF 2.0
binary exercising what ThreeAS's GLTFLoader reads. Standard library only (struct, zlib, json).

Contents: an embedded PNG (base colour), PBR materials (textured, metallic,
alpha-blended double-sided), a node hierarchy (an arm), a skinned tail
(three joints) with a morph target, LINEAR / STEP / CUBICSPLINE animations,
a KHR_lights_punctual light and a camera.

    python3 tools/make_sample_glb.py
"""
import json, math, os, struct, zlib

import sample_paths

OUT = sample_paths.path("sample.glb")

bin_data = bytearray()
buffer_views, accessors = [], []


def align4():
    while len(bin_data) % 4:
        bin_data.append(0)


def add_view(data, target=None):
    align4()
    view = {"buffer": 0, "byteOffset": len(bin_data), "byteLength": len(data)}
    if target:
        view["target"] = target
    bin_data.extend(data)
    buffer_views.append(view)
    return len(buffer_views) - 1


def add_accessor(values, type_, component=5126, target=None, minmax=False, normalized=False):
    n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[type_]
    fmt = {5126: "f", 5123: "H", 5125: "I", 5121: "B", 5122: "h"}[component]
    data = struct.pack("<%d%s" % (len(values), fmt), *values)
    acc = {"bufferView": add_view(data, target), "componentType": component,
           "count": len(values) // n, "type": type_}
    if normalized:
        acc["normalized"] = True
    if minmax:
        acc["min"] = [min(values[i::n]) for i in range(n)]
        acc["max"] = [max(values[i::n]) for i in range(n)]
    accessors.append(acc)
    return len(accessors) - 1


def png(width, height, pixel):
    raw = b"".join(b"\x00" + bytes(c for x in range(width) for c in pixel(x, y)) for y in range(height))
    def chunk(t, c):
        return struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def box(sx, sy, sz, y0=0.0):
    """Positions, normals, uvs, indices of a box (y from y0 to y0 + sy)."""
    P, N, U, I = [], [], [], []
    faces = [((1, 0, 0), (0, 0, -1), (0, 1, 0)), ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
             ((0, 1, 0), (1, 0, 0), (0, 0, -1)), ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
             ((0, 0, 1), (1, 0, 0), (0, 1, 0)), ((0, 0, -1), (-1, 0, 0), (0, 1, 0))]
    h = (sx / 2, sy / 2, sz / 2)
    for n, u, v in faces:
        base = len(P) // 3
        for cu, cv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            p = [n[k] * h[k] + cu * u[k] * h[k] + cv * v[k] * h[k] for k in range(3)]
            p[1] += y0 + sy / 2
            P += p
            N += list(n)
            U += [(cu + 1) / 2, 1 - (cv + 1) / 2]   # glTF uv: v down
        I += [base, base + 1, base + 2, base, base + 2, base + 3]
    return P, N, U, I


def quat_z(angle):
    return [0.0, 0.0, math.sin(angle / 2), math.cos(angle / 2)]


# --- texture: a coloured checker -------------------------------------------
def checker(x, y):
    on = ((x // 8) + (y // 8)) % 2 == 0
    return (240, 180, 60) if on else (60, 90, 160)

image_view = add_view(png(64, 64, checker))

# --- meshes ------------------------------------------------------------------
meshes = []

P, N, U, I = box(2.4, 0.3, 2.4, 0.0)
meshes.append({"name": "Base", "primitives": [{
    "attributes": {"POSITION": add_accessor(P, "VEC3", target=34962, minmax=True),
                   "NORMAL": add_accessor(N, "VEC3", target=34962),
                   "TEXCOORD_0": add_accessor(U, "VEC2", target=34962)},
    "indices": add_accessor(I, "SCALAR", 5123, target=34963), "material": 0}]})

P, N, U, I = box(0.22, 1.0, 0.22, 0.0)
meshes.append({"name": "ArmSegment", "primitives": [{
    "attributes": {"POSITION": add_accessor(P, "VEC3", target=34962, minmax=True),
                   "NORMAL": add_accessor(N, "VEC3", target=34962)},
    "indices": add_accessor(I, "SCALAR", 5123, target=34963), "material": 1}]})

# The skinned tail: a ring cylinder from y = 0 to 1.2 at x = 0.75, three joints.
rings, sides, height = 12, 16, 1.2
P, N, J, W, I, M = [], [], [], [], [], []
for r in range(rings + 1):
    y = height * r / rings
    t = y / height * 2          # 0..2 across two segments
    seg = min(int(t), 1)
    f = t - seg
    for s in range(sides + 1):
        a = 2 * math.pi * s / sides
        nx, nz = math.cos(a), math.sin(a)
        radius = 0.16 * (1 - 0.5 * y / height)
        P += [0.75 + nx * radius, 0.3 + y, nz * radius]
        N += [nx, 0.0, nz]
        J += [seg, seg + 1, 0, 0]
        W += [1 - f, f, 0.0, 0.0]
        M += [nx * 0.12, 0.0, nz * 0.12]   # morph "puff": outwards
for r in range(rings):
    for s in range(sides):
        a = r * (sides + 1) + s
        b = a + sides + 1
        I += [a, b, a + 1, b, b + 1, a + 1]
meshes.append({"name": "Tail", "primitives": [{
    "attributes": {"POSITION": add_accessor(P, "VEC3", target=34962, minmax=True),
                   "NORMAL": add_accessor(N, "VEC3", target=34962),
                   "JOINTS_0": add_accessor(J, "VEC4", 5121, target=34962),
                   "WEIGHTS_0": add_accessor(W, "VEC4", target=34962)},
    "targets": [{"POSITION": add_accessor(M, "VEC3", minmax=True)}],
    "indices": add_accessor(I, "SCALAR", 5123, target=34963), "material": 3}],
    "weights": [0.0], "extras": {"targetNames": ["puff"]}})

# A double-sided, alpha-blended pane.
P = [-0.6, 0, 0, 0.6, 0, 0, 0.6, 0.8, 0, -0.6, 0.8, 0]
N = [0, 0, 1] * 4
U = [0, 1, 1, 1, 1, 0, 0, 0]
meshes.append({"name": "Pane", "primitives": [{
    "attributes": {"POSITION": add_accessor(P, "VEC3", target=34962, minmax=True),
                   "NORMAL": add_accessor(N, "VEC3", target=34962),
                   "TEXCOORD_0": add_accessor(U, "VEC2", target=34962)},
    "indices": add_accessor([0, 1, 2, 0, 2, 3], "SCALAR", 5123, target=34963), "material": 2}]})

# --- skin: joints at the tail's base, middle and tip ---------------------------
joint_pos = [(0.75, 0.3, 0.0), (0.75, 0.9, 0.0), (0.75, 1.5, 0.0)]
ibm = []
for x, y, z in joint_pos:
    ibm += [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -x, -y, -z, 1]
skin = {"joints": [6, 7, 8], "inverseBindMatrices": add_accessor(ibm, "MAT4"), "skeleton": 6}

# --- animations ---------------------------------------------------------------
times = [0.0, 1.0, 2.0]
t_acc = add_accessor(times, "SCALAR", minmax=True)
shoulder = add_accessor(quat_z(0.6) + quat_z(-0.6) + quat_z(0.6), "VEC4")
# CUBICSPLINE: in-tangent, value, out-tangent per key.
elbow_vals = []
for v in (quat_z(-1.0), quat_z(0.2), quat_z(-1.0)):
    elbow_vals += [0, 0, 0, 0] + v + [0, 0, 0, 0]
elbow = add_accessor(elbow_vals, "VEC4")
tail_mid = add_accessor(quat_z(0.5) + quat_z(-0.5) + quat_z(0.5), "VEC4")
tail_tip = add_accessor(quat_z(0.7) + quat_z(-0.7) + quat_z(0.7), "VEC4")
step_t = add_accessor([0.0, 1.0], "SCALAR", minmax=True)
pane_pos = add_accessor([0.0, 0.35, -0.9, 0.0, 0.6, -0.9], "VEC3")
puff = add_accessor([0.0, 1.0, 0.0], "SCALAR")

animations = [
    {"name": "Wave", "samplers": [
        {"input": t_acc, "output": shoulder, "interpolation": "LINEAR"},
        {"input": t_acc, "output": elbow, "interpolation": "CUBICSPLINE"},
        {"input": step_t, "output": pane_pos, "interpolation": "STEP"}],
     "channels": [
        {"sampler": 0, "target": {"node": 1, "path": "rotation"}},
        {"sampler": 1, "target": {"node": 2, "path": "rotation"}},
        {"sampler": 2, "target": {"node": 4, "path": "translation"}}]},
    {"name": "Sway", "samplers": [
        {"input": t_acc, "output": tail_mid, "interpolation": "LINEAR"},
        {"input": t_acc, "output": tail_tip, "interpolation": "LINEAR"},
        {"input": t_acc, "output": puff, "interpolation": "LINEAR"}],
     "channels": [
        {"sampler": 0, "target": {"node": 7, "path": "rotation"}},
        {"sampler": 1, "target": {"node": 8, "path": "rotation"}},
        {"sampler": 2, "target": {"node": 3, "path": "weights"}}]},
]

# --- document -----------------------------------------------------------------
gltf = {
    "asset": {"version": "2.0", "generator": "ThreeAS tools/make_sample_glb.py"},
    "extensionsUsed": ["KHR_lights_punctual"],
    "extensions": {"KHR_lights_punctual": {"lights": [
        {"type": "point", "color": [1.0, 0.85, 0.6], "intensity": 6.0, "range": 8.0}]}},
    "scene": 0,
    "scenes": [{"name": "Sample", "nodes": [0, 1, 3, 4, 5, 6, 9]}],
    "nodes": [
        {"name": "Base", "mesh": 0},                                                     # 0
        {"name": "Shoulder", "mesh": 1, "translation": [-0.7, 0.3, 0.0], "children": [2]},  # 1
        {"name": "Elbow", "mesh": 1, "translation": [0.0, 1.0, 0.0]},                    # 2
        {"name": "Tail", "mesh": 2, "skin": 0},                                          # 3
        {"name": "Pane", "mesh": 3, "translation": [0.0, 0.35, -0.9]},                    # 4
        {"name": "Lamp", "translation": [0.0, 2.2, 1.2],
         "extensions": {"KHR_lights_punctual": {"light": 0}}},                            # 5
        {"name": "TailRoot", "translation": list(joint_pos[0]), "children": [7]},         # 6
        {"name": "TailMid", "translation": [0.0, 0.6, 0.0], "children": [8]},             # 7
        {"name": "TailTip", "translation": [0.0, 0.6, 0.0]},                              # 8
        {"name": "Camera", "camera": 0, "translation": [0.0, 1.4, 4.0],
         "rotation": [-0.1, 0.0, 0.0, 0.995]},                                            # 9
    ],
    "cameras": [{"type": "perspective", "perspective": {"yfov": 0.8, "znear": 0.1, "zfar": 100.0}}],
    "meshes": meshes,
    "skins": [skin],
    "animations": animations,
    "materials": [
        {"name": "Checker", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
                                                     "metallicFactor": 0.0, "roughnessFactor": 0.6}},
        {"name": "Gold", "pbrMetallicRoughness": {"baseColorFactor": [1.0, 0.7, 0.25, 1.0],
                                                  "metallicFactor": 1.0, "roughnessFactor": 0.3}},
        {"name": "Glass", "alphaMode": "BLEND", "doubleSided": True,
         "pbrMetallicRoughness": {"baseColorFactor": [0.3, 0.7, 1.0, 0.45], "metallicFactor": 0.0,
                                  "roughnessFactor": 0.1}},
        {"name": "Skin", "pbrMetallicRoughness": {"baseColorFactor": [0.18, 0.75, 0.68, 1.0],
                                                  "metallicFactor": 0.0, "roughnessFactor": 0.5},
         "emissiveFactor": [0.0, 0.05, 0.04]},
    ],
    "textures": [{"source": 0, "sampler": 0}],
    "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
    "images": [{"bufferView": image_view, "mimeType": "image/png"}],
    "bufferViews": buffer_views,
    "accessors": accessors,
}
align4()
gltf["buffers"] = [{"byteLength": len(bin_data)}]

js = json.dumps(gltf, separators=(",", ":")).encode()
js += b" " * ((4 - len(js) % 4) % 4)
total = 12 + 8 + len(js) + 8 + len(bin_data)
with open(OUT, "wb") as f:
    f.write(struct.pack("<III", 0x46546C67, 2, total))
    f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
    f.write(struct.pack("<II", len(bin_data), 0x004E4942) + bytes(bin_data))
print("wrote", os.path.normpath(OUT), total, "bytes")
