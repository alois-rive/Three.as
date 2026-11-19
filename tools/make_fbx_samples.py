#!/usr/bin/env python3
"""Writes FBX samples for FBXLoader's tests and the Models example:

  fbx_scene.fbx   binary FBX 7400 (32-bit node records,
      zlib-compressed arrays): a node hierarchy with translations,
      rotations, pre-rotation, scaling and a rotation pivot; a cube of quads
      with normals, uvs and two materials (Phong with an embedded PNG
      texture, Lambert with transparency) by polygon; a pentagon with
      vertex colours, a geometric translation and a blend shape; a skinned
      strip with two clusters, two bones and a bind pose; a NURBS curve; a
      directional light and a camera; an animation stack with position,
      rotation (with a span over 180 degrees) and blend shape curves.
  fbx_v7500.fbx   binary FBX 7500 (64-bit node records,
      uncompressed arrays): one triangle and one quad.
  fbx_ascii.fbx   ASCII FBX 7400: a parent Null and a mesh
      (a quad and a triangle with normals, uvs, a Lambert material and a
      base64 embedded PNG).

The layout follows Blender's io_scene_fbx encoder and three.js's
BinaryParser / TextParser: a 27-byte header, node records (end offset,
property count, property list length, name, properties, nested records
ended by a NULL record), typed properties (C D F I L R S Y and arrays b c d
f i l with an encoding flag, 1 = zlib) and a footer.
"""
import math, os, shutil, struct, zlib, base64

import sample_paths

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = sample_paths.FIXTURES   # fbx_scene.fbx is copied to the Models example

KTIME = 46186158000   # FBX ticks a second

# ------------------------------------------------------------------ the tree

class Node:
    def __init__(self, name, props=(), children=()):
        self.name = name
        self.props = list(props)
        self.children = list(children)

    def add(self, *children):
        self.children.extend(children)
        return self

# Typed property values: (type code, value).
def I(v): return ("I", int(v))
def L(v): return ("L", int(v))
def D(v): return ("D", float(v))
def F(v): return ("F", float(v))
def S(v): return ("S", v)
def R(v): return ("R", bytes(v))
def C(v): return ("C", bool(v))
def Y(v): return ("Y", int(v))
def darr(v, compress=True): return ("d", [float(x) for x in v], compress)
def farr(v, compress=True): return ("f", [float(x) for x in v], compress)
def iarr(v, compress=True): return ("i", [int(x) for x in v], compress)
def larr(v, compress=True): return ("l", [int(x) for x in v], compress)

def P(name, type1, type2, flag, *values):
    return Node("P", [S(name), S(type1), S(type2), S(flag)] + list(values))

def props70(*ps):
    return Node("Properties70", [], ps)

def leaf(name, value):
    return Node(name, [value])

# ------------------------------------------------------------------- binary

ARRAY_FORMATS = {"d": "<%dd", "f": "<%df", "i": "<%di", "l": "<%dq", "b": "<%dB", "c": "<%dB"}

def encode_property(p):
    t = p[0]
    if t == "C": return b"C" + struct.pack("<B", 1 if p[1] else 0)
    if t == "Y": return b"Y" + struct.pack("<h", p[1])
    if t == "I": return b"I" + struct.pack("<i", p[1])
    if t == "L": return b"L" + struct.pack("<q", p[1])
    if t == "F": return b"F" + struct.pack("<f", p[1])
    if t == "D": return b"D" + struct.pack("<d", p[1])
    if t == "S":
        data = p[1].encode("utf-8") if isinstance(p[1], str) else p[1]
        return b"S" + struct.pack("<I", len(data)) + data
    if t == "R": return b"R" + struct.pack("<I", len(p[1])) + p[1]
    values, compress = p[1], p[2]
    raw = struct.pack(ARRAY_FORMATS[t] % len(values), *values)
    if compress:
        data = zlib.compress(raw, 9)
        return t.encode() + struct.pack("<III", len(values), 1, len(data)) + data
    return t.encode() + struct.pack("<III", len(values), 0, len(raw)) + raw

def encode_node(node, offset, wide):
    """The node record at file offset `offset`."""
    head = 25 if wide else 13
    name = node.name.encode()
    props = b"".join(encode_property(p) for p in node.props)
    body = bytearray()
    start = offset + head + len(name) + len(props)
    if node.children or not node.props:
        at = start
        for child in node.children:
            data = encode_node(child, at, wide)
            body += data
            at += len(data)
        body += b"\0" * head   # NULL record
    end = start + len(body)
    fmt = "<QQQB" if wide else "<IIIB"
    return struct.pack(fmt, end, len(node.props), len(props), len(name)) + name + props + bytes(body)

FOOT_ID = b"\xfa\xbc\xab\x09\xd0\xc8\xd4\x66\xb1\x76\xfb\x83\x1c\xf7\x26\x7e"
FOOT_MAGIC = b"\xf8\x5a\x8c\x6a\xde\xf5\xd9\x7e\xec\xe9\x0c\xe3\x75\x8f\x29\x0b"

def write_binary(path, nodes, version):
    wide = version >= 7500
    out = bytearray(b"Kaydara FBX Binary  \x00\x1a\x00" + struct.pack("<I", version))
    for node in nodes:
        out += encode_node(node, len(out), wide)
    out += b"\0" * (25 if wide else 13)
    out += FOOT_ID
    pad = ((len(out) + 15) & ~15) - len(out)
    if pad == 0:
        pad = 16
    out += b"\0" * pad
    out += struct.pack("<I", version)
    out += b"\0" * 120
    out += FOOT_MAGIC
    with open(path, "wb") as f:
        f.write(out)
    return len(out)

# -------------------------------------------------------------------- ASCII

def ascii_value(p):
    t = p[0]
    if t == "S":
        s = p[1]
        if "\x00\x01" in s:   # "Name\0\1Class" -> "Class::Name"
            name, cls = s.split("\x00\x01")
            s = cls + "::" + name
        return '"' + s + '"'
    if t == "C": return "T" if p[1] else "F"   # booleans are written as letters
    if t in ("D", "F"): return repr(p[1]) if p[1] != int(p[1]) else str(int(p[1]))
    if t == "R": return '"' + base64.b64encode(p[1]).decode() + '"'
    return str(p[1])

def ascii_number(v):
    return str(int(v)) if float(v) == int(v) else repr(float(v))

def write_ascii_node(lines, node, depth):
    tabs = "\t" * depth
    if node.name == "P":
        head = ", ".join(ascii_value(p) for p in node.props[:4])
        rest = "".join("," + (ascii_value(p) if p[0] in ("S",) else ascii_number(p[1])) for p in node.props[4:])
        lines.append(tabs + "P: " + head + rest)
        return
    if len(node.props) == 1 and node.props[0][0] in ARRAY_FORMATS and not node.children:
        values = node.props[0][1]
        lines.append(tabs + "%s: *%d {" % (node.name, len(values)))
        lines.append(tabs + "\ta: " + ",".join(ascii_number(v) for v in values))
        lines.append(tabs + "} ")
        return
    if len(node.props) == 1 and node.props[0][0] == "R":
        # embedded data: "Content: ," then the base64 on the next line
        lines.append(tabs + "%s: , " % node.name)
        lines.append(tabs + "\t" + ascii_value(node.props[0]))
        return
    values = ",".join(ascii_value(p) for p in node.props) if node.name == "C" else \
        ", ".join(ascii_value(p) for p in node.props)
    if node.children:
        lines.append(tabs + "%s: %s {" % (node.name, values))
        for child in node.children:
            write_ascii_node(lines, child, depth + 1)
        lines.append(tabs + "}")
    else:
        lines.append(tabs + "%s: %s" % (node.name, values))

def write_ascii(path, nodes):
    lines = ["; FBX 7.4.0 project file", "; Written by tools/make_fbx_samples.py", "; ---------------------", ""]
    for node in nodes:
        write_ascii_node(lines, node, 0)
        lines.append("")
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

# -------------------------------------------------------------- PNG helper

def png(width, height, pixel):
    """A PNG (RGBA) of pixel(x, y) -> (r, g, b, a)."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw += bytes(pixel(x, y))
    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))

def checker(x, y):
    return (230, 200, 60, 255) if (x // 2 + y // 2) % 2 == 0 else (40, 60, 160, 255)

# --------------------------------------------------------------- the scene

def header(version):
    return Node("FBXHeaderExtension", [], [
        leaf("FBXHeaderVersion", I(1003)),
        leaf("FBXVersion", I(version)),
        leaf("Creator", S("tools/make_fbx_samples.py")),
    ])

def global_settings(unit_scale=1.0):
    return Node("GlobalSettings", [], [
        leaf("Version", I(1000)),
        props70(
            P("UpAxis", "int", "Integer", "", I(1)),
            P("UnitScaleFactor", "double", "Number", "", D(unit_scale)),
            P("AmbientColor", "ColorRGB", "Color", "", D(0), D(0), D(0)),
        ),
    ])

def model(id_, name, kind, props=(), version=232):
    return Node("Model", [L(id_), S(name + "\x00\x01Model"), S(kind)], [
        leaf("Version", I(version)),
        props70(*props),
        leaf("Shading", C(True)),
        leaf("Culling", S("CullingOff")),
    ])

def vec(name, x, y, z, kind=None):
    kind = kind or name
    return P(name, kind, "", "A", D(x), D(y), D(z))

def layer_element(name, mapping, reference, arrays, index=0):
    return Node(name, [I(index)], [
        leaf("Version", I(101)),
        leaf("Name", S("")),
        leaf("MappingInformationType", S(mapping)),
        leaf("ReferenceInformationType", S(reference)),
    ] + [leaf(n, a) for n, a in arrays])

def mesh_geometry(id_, name, vertices, polygon_index, layers, compress=True):
    return Node("Geometry", [L(id_), S(name + "\x00\x01Geometry"), S("Mesh")], [
        leaf("Vertices", darr(vertices, compress)),
        leaf("PolygonVertexIndex", iarr(polygon_index, compress)),
        leaf("GeometryVersion", I(124)),
    ] + layers)

def matrix_translation(x, y, z):
    return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1]

def curve(id_, times, values):
    return Node("AnimationCurve", [L(id_), S("\x00\x01AnimCurve"), S("")], [
        leaf("Default", D(values[0])),
        leaf("KeyVer", I(4009)),
        leaf("KeyTime", larr([int(round(t * KTIME)) for t in times])),
        leaf("KeyValueFloat", farr(values)),
        leaf("KeyAttrFlags", iarr([24840])),
        leaf("KeyAttrDataFloat", farr([0, 0, 255790911, 0])),
        leaf("KeyAttrRefCount", iarr([len(times)])),
    ])

def curve_node(id_, attr, channels):
    return Node("AnimationCurveNode", [L(id_), S(attr + "\x00\x01AnimCurveNode"), S("")], [
        props70(*[P(c, "Number", "", "A", D(v)) for c, v in channels]),
    ])

def OO(child, parent): return Node("C", [S("OO"), L(child), L(parent)])
def OP(child, parent, prop): return Node("C", [S("OP"), L(child), L(parent), S(prop)])

BIG = 2_000_000_000_000   # ids above 2^32, as Autodesk's tools write them

def scene_nodes():
    ids = {}
    def ID(name):
        if name not in ids:
            ids[name] = BIG + 1000 + len(ids)
        return ids[name]

    objects = Node("Objects")
    conns = Node("Connections")

    # --- hierarchy: Root (Null) > Box (Mesh), Pivoted (Null), Pentagon (Mesh)
    objects.add(model(ID("Root"), "Root", "Null", [vec("Lcl Translation", 0, 1, 0)]))
    conns.add(OO(ID("Root"), 0))
    objects.add(model(ID("Box"), "Box", "Mesh", [
        P("PreRotation", "Vector3D", "Vector", "", D(-90), D(0), D(0)),
        vec("Lcl Translation", 2, 0, 0),
        vec("Lcl Rotation", 0, 90, 0),
        vec("Lcl Scaling", 0.5, 0.5, 0.5),
    ]))
    conns.add(OO(ID("Box"), ID("Root")))
    objects.add(model(ID("Pivoted"), "Pivoted", "Null", [
        P("RotationPivot", "Vector3D", "Vector", "", D(1), D(0), D(0)),
        vec("Lcl Rotation", 0, 0, 90),
    ]))
    conns.add(OO(ID("Pivoted"), ID("Root")))

    # --- the cube: 8 points, 6 quads, normals by polygon vertex, uvs indexed,
    # materials by polygon (the top face uses the second material)
    v = [-1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1, -1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1]
    faces = [
        ([0, 3, 2, 1], (0, 0, -1)), ([4, 5, 6, 7], (0, 0, 1)), ([0, 1, 5, 4], (0, -1, 0)),
        ([1, 2, 6, 5], (1, 0, 0)), ([2, 3, 7, 6], (0, 1, 0)), ([3, 0, 4, 7], (-1, 0, 0)),
    ]
    pvi, normals, uv_index = [], [], []
    for f, n in faces:
        pvi += f[:3] + [f[3] ^ -1]
        normals += list(n) * 4
        uv_index += [0, 1, 2, 3]
    objects.add(mesh_geometry(ID("BoxGeo"), "BoxGeo", v, pvi, [
        layer_element("LayerElementNormal", "ByPolygonVertex", "Direct", [("Normals", darr(normals))]),
        layer_element("LayerElementUV", "ByPolygonVertex", "IndexToDirect", [
            ("UV", darr([0, 0, 1, 0, 1, 1, 0, 1])), ("UVIndex", iarr(uv_index))]),
        layer_element("LayerElementMaterial", "ByPolygon", "IndexToDirect", [("Materials", iarr([0, 0, 0, 0, 1, 0]))]),
    ]))
    conns.add(OO(ID("BoxGeo"), ID("Box")))

    # --- materials: a Phong with an embedded texture, a transparent Lambert
    objects.add(Node("Material", [L(ID("Gold")), S("Gold\x00\x01Material"), S("")], [
        leaf("Version", I(102)), leaf("ShadingModel", S("phong")), leaf("MultiLayer", I(0)),
        props70(
            P("DiffuseColor", "Color", "", "A", D(0.8), D(0.6), D(0.2)),
            P("Diffuse", "Vector3D", "Vector", "", D(0.8), D(0.6), D(0.2)),
            P("Specular", "Vector3D", "Vector", "", D(0.5), D(0.5), D(0.5)),
            P("Shininess", "double", "Number", "", D(20)),
            P("Emissive", "Vector3D", "Vector", "", D(0), D(0), D(0)),
        ),
    ]))
    objects.add(Node("Material", [L(ID("Glass")), S("Glass\x00\x01Material"), S("")], [
        leaf("Version", I(102)), leaf("ShadingModel", S("lambert")), leaf("MultiLayer", I(0)),
        props70(
            P("DiffuseColor", "Color", "", "A", D(0.2), D(0.4), D(1.0)),
            P("TransparencyFactor", "Number", "", "A", D(0.25)),
        ),
    ]))
    conns.add(OO(ID("Gold"), ID("Box")))
    conns.add(OO(ID("Glass"), ID("Box")))
    texture_png = png(8, 8, checker)
    objects.add(Node("Video", [L(ID("CheckerVideo")), S("checker\x00\x01Video"), S("Clip")], [
        leaf("Type", S("Clip")),
        props70(P("Path", "KString", "XRefUrl", "", S("C:\\textures\\checker.png"))),
        leaf("UseMipMap", I(0)),
        leaf("Filename", S("C:\\textures\\checker.png")),
        leaf("RelativeFilename", S("textures\\checker.png")),
        leaf("Content", R(texture_png)),
    ]))
    objects.add(Node("Texture", [L(ID("CheckerTex")), S("Checker\x00\x01Texture"), S("")], [
        leaf("Type", S("TextureVideoClip")), leaf("Version", I(202)),
        leaf("TextureName", S("Checker\x00\x01Texture")),
        props70(
            P("WrapModeU", "enum", "", "", I(0)),
            P("WrapModeV", "enum", "", "", I(1)),
            P("Scaling", "Vector", "", "A", D(2), D(3), D(1)),
        ),
        leaf("Media", S("checker\x00\x01Video")),
        leaf("FileName", S("C:\\textures\\checker.png")),
        leaf("RelativeFilename", S("textures\\checker.png")),
    ]))
    conns.add(OO(ID("CheckerVideo"), ID("CheckerTex")))
    conns.add(OP(ID("CheckerTex"), ID("Gold"), "DiffuseColor"))

    # --- a pentagon and a triangle, vertex colours by control point, a
    # geometric translation, a blend shape moving point 0 along +z
    pent = []
    for k in range(5):
        a = math.pi / 2 + k * 2 * math.pi / 5
        pent += [math.cos(a), math.sin(a), 0]
    pent += [1.5, -1, 0, 2.5, -1, 0, 2, 0, 0]
    pvi = [0, 1, 2, 3, 4 ^ -1, 5, 6, 7 ^ -1]
    colors = []
    for k in range(8):
        colors += [1.0, k / 7.0, 0.0, 1.0]
    objects.add(model(ID("Pentagon"), "Pentagon", "Mesh", [
        vec("Lcl Translation", -2, 0, 0),
        P("GeometricTranslation", "Vector3D", "Vector", "", D(0), D(0.5), D(0)),
    ]))
    conns.add(OO(ID("Pentagon"), ID("Root")))
    objects.add(mesh_geometry(ID("PentGeo"), "PentGeo", pent, pvi, [
        layer_element("LayerElementNormal", "ByPolygon", "Direct", [("Normals", darr([0, 0, 1, 0, 0, 1]))]),
        layer_element("LayerElementColor", "ByVertice", "Direct", [("Colors", darr(colors))]),
    ]))
    conns.add(OO(ID("PentGeo"), ID("Pentagon")))
    objects.add(Node("Deformer", [L(ID("Morpher")), S("Morpher\x00\x01Deformer"), S("BlendShape")], [leaf("Version", I(100))]))
    objects.add(Node("Deformer", [L(ID("BulgeChannel")), S("Bulge\x00\x01SubDeformer"), S("BlendShapeChannel")], [
        leaf("Version", I(100)), leaf("DeformPercent", D(0)), leaf("FullWeights", darr([100])),
    ]))
    objects.add(Node("Geometry", [L(ID("BulgeShape")), S("Bulge\x00\x01Geometry"), S("Shape")], [
        leaf("Version", I(100)), leaf("Indexes", iarr([0])), leaf("Vertices", darr([0, 0, 1])),
        leaf("Normals", darr([0, 0, 0])),
    ]))
    conns.add(OO(ID("Morpher"), ID("PentGeo")))
    conns.add(OO(ID("BulgeChannel"), ID("Morpher")))
    conns.add(OO(ID("BulgeShape"), ID("BulgeChannel")))

    # --- a skinned strip: 6 points, 2 quads, bones at y = 0 and y = 1
    objects.add(model(ID("Armature"), "Armature", "Null", [vec("Lcl Translation", 0, 0, -2)]))
    conns.add(OO(ID("Armature"), 0))
    objects.add(model(ID("Bone0"), "Bone0", "LimbNode", []))
    conns.add(OO(ID("Bone0"), ID("Armature")))
    objects.add(model(ID("Bone1"), "Bone1", "LimbNode", [vec("Lcl Translation", 0, 1, 0)]))
    conns.add(OO(ID("Bone1"), ID("Bone0")))
    objects.add(model(ID("Strip"), "Strip", "Mesh", []))
    conns.add(OO(ID("Strip"), ID("Armature")))
    strip = [-0.5, 0, 0, 0.5, 0, 0, -0.5, 1, 0, 0.5, 1, 0, -0.5, 2, 0, 0.5, 2, 0]
    objects.add(mesh_geometry(ID("StripGeo"), "StripGeo", strip, [0, 1, 3, 2 ^ -1, 2, 3, 5, 4 ^ -1], [
        layer_element("LayerElementNormal", "ByVertice", "Direct", [("Normals", darr([0, 0, 1] * 6))]),
    ]))
    conns.add(OO(ID("StripGeo"), ID("Strip")))
    objects.add(Node("Deformer", [L(ID("Skin")), S("Skin\x00\x01Deformer"), S("Skin")], [
        leaf("Version", I(101)), leaf("Link_DeformAcuracy", D(50)),
    ]))
    conns.add(OO(ID("Skin"), ID("StripGeo")))
    # the strip sits at z = -2 (its Armature): bind matrices are world space
    for b, (idx, w, y) in enumerate((([0, 1, 2, 3], [1, 1, 0.5, 0.5], 0), ([2, 3, 4, 5], [0.5, 0.5, 1, 1], 1))):
        objects.add(Node("Deformer", [L(ID("Cluster%d" % b)), S("Cluster%d\x00\x01SubDeformer" % b), S("Cluster")], [
            leaf("Version", I(100)), leaf("UserData", S("")),
            leaf("Indexes", iarr(idx)), leaf("Weights", darr(w)),
            leaf("Transform", darr(matrix_translation(0, -y, 0))),
            leaf("TransformLink", darr(matrix_translation(0, y, -2))),
        ]))
        conns.add(OO(ID("Cluster%d" % b), ID("Skin")))
        conns.add(OO(ID("Bone%d" % b), ID("Cluster%d" % b)))
    objects.add(Node("Pose", [L(ID("BindPose")), S("BIND_POSES\x00\x01Pose"), S("BindPose")], [
        leaf("Type", S("BindPose")), leaf("Version", I(100)), leaf("NbPoseNodes", I(3)),
        Node("PoseNode", [], [leaf("Node", L(ID("Strip"))), leaf("Matrix", darr(matrix_translation(0, 0, -2)))]),
        Node("PoseNode", [], [leaf("Node", L(ID("Bone0"))), leaf("Matrix", darr(matrix_translation(0, 0, -2)))]),
        Node("PoseNode", [], [leaf("Node", L(ID("Bone1"))), leaf("Matrix", darr(matrix_translation(0, 1, -2)))]),
    ]))

    # --- a NURBS curve (degree 2, open)
    objects.add(Node("Geometry", [L(ID("ArcGeo")), S("Arc\x00\x01Geometry"), S("NurbsCurve")], [
        leaf("Type", S("NurbsCurve")), leaf("NurbsCurveVersion", I(100)), leaf("Order", I(3)),
        leaf("Dimension", I(3)), leaf("Form", S("Open")), leaf("Rational", I(0)),
        leaf("Points", darr([-1, 0, 0, 1, -1, 1, 0, 1, 1, 1, 0, 1, 1, 0, 0, 1])),
        leaf("KnotVector", darr([0, 0, 0, 0.5, 1, 1, 1])),
    ]))
    objects.add(model(ID("Arc"), "Arc", "NurbsCurve", [vec("Lcl Translation", 0, 2.5, 0)]))
    conns.add(OO(ID("Arc"), 0))
    conns.add(OO(ID("ArcGeo"), ID("Arc")))

    # --- a directional light and a camera
    objects.add(Node("NodeAttribute", [L(ID("SunAttr")), S("\x00\x01NodeAttribute"), S("Light")], [
        leaf("TypeFlags", S("Light")), leaf("GeometryVersion", I(124)),
        props70(
            P("LightType", "enum", "", "", I(1)),
            P("Color", "Color", "", "A", D(1), D(0.9), D(0.8)),
            P("Intensity", "Number", "", "A", D(150)),
            P("CastShadows", "bool", "", "", I(1)),
        ),
    ]))
    objects.add(model(ID("Sun"), "Sun", "Light", [vec("Lcl Translation", 3, 5, 2)]))
    conns.add(OO(ID("Sun"), 0))
    conns.add(OO(ID("SunAttr"), ID("Sun")))
    objects.add(Node("NodeAttribute", [L(ID("CamAttr")), S("\x00\x01NodeAttribute"), S("Camera")], [
        leaf("TypeFlags", S("Camera")), leaf("GeometryVersion", I(124)),
        props70(
            P("FieldOfView", "FieldOfView", "", "A", D(40)),
            P("AspectWidth", "double", "Number", "", D(320)),
            P("AspectHeight", "double", "Number", "", D(200)),
            P("NearPlane", "double", "Number", "", D(10)),
            P("FarPlane", "double", "Number", "", D(5000)),
        ),
    ]))
    objects.add(model(ID("Cam"), "Cam", "Camera", [vec("Lcl Translation", 0, 2, 8)]))
    conns.add(OO(ID("Cam"), 0))
    conns.add(OO(ID("CamAttr"), ID("Cam")))

    # --- animation: Root rises (y only), Bone1 turns about z (0, 90, 300
    # degrees: the last span is over 180), the blend shape goes to 100%
    objects.add(Node("AnimationStack", [L(ID("Take")), S("Take 001\x00\x01AnimStack"), S("")], [
        props70(P("LocalStop", "KTime", "Time", "", L(2 * KTIME))),
    ]))
    objects.add(Node("AnimationLayer", [L(ID("Layer")), S("BaseLayer\x00\x01AnimLayer"), S("")]))
    conns.add(OO(ID("Layer"), ID("Take")))
    objects.add(curve_node(ID("RootT"), "T", [("d|X", 0), ("d|Y", 1), ("d|Z", 0)]))
    objects.add(curve(ID("RootTY"), [0, 1], [1, 2]))
    conns.add(OO(ID("RootT"), ID("Layer")))
    conns.add(OP(ID("RootT"), ID("Root"), "Lcl Translation"))
    conns.add(OP(ID("RootTY"), ID("RootT"), "d|Y"))
    objects.add(curve_node(ID("Bone1R"), "R", [("d|X", 0), ("d|Y", 0), ("d|Z", 0)]))
    for axis, values in (("X", [0, 0, 0]), ("Y", [0, 0, 0]), ("Z", [0, 90, 300])):
        objects.add(curve(ID("Bone1R" + axis), [0, 1, 2], values))
        conns.add(OP(ID("Bone1R" + axis), ID("Bone1R"), "d|" + axis))
    conns.add(OO(ID("Bone1R"), ID("Layer")))
    conns.add(OP(ID("Bone1R"), ID("Bone1"), "Lcl Rotation"))
    objects.add(curve_node(ID("BulgeDP"), "DeformPercent", [("d|DeformPercent", 0)]))
    objects.add(curve(ID("BulgeCurve"), [0, 2], [0, 100]))
    conns.add(OO(ID("BulgeDP"), ID("Layer")))
    conns.add(OP(ID("BulgeDP"), ID("BulgeChannel"), "DeformPercent"))
    conns.add(OP(ID("BulgeCurve"), ID("BulgeDP"), "d|DeformPercent"))

    return [header(7400), global_settings(2.54), objects, conns]

def v7500_nodes():
    objects = Node("Objects")
    conns = Node("Connections")
    objects.add(model(10, "Wide", "Mesh", [vec("Lcl Translation", 0, 0, 1)]))
    conns.add(OO(10, 0))
    verts = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 2, 0, 0]
    objects.add(mesh_geometry(11, "WideGeo", verts, [0, 1, 4 ^ -1, 0, 1, 2, 3 ^ -1], [], compress=False))
    conns.add(OO(11, 10))
    return [header(7500), global_settings(), objects, conns]

def ascii_nodes():
    objects = Node("Objects")
    conns = Node("Connections")
    objects.add(model(20, "Parent", "Null", [vec("Lcl Translation", 0, 0, 3)]))
    conns.add(OO(20, 0))
    objects.add(model(21, "Plane", "Mesh", [
        vec("Lcl Translation", 1, 0, 0),
        vec("Lcl Scaling", 2, 2, 2),
    ]))
    conns.add(OO(21, 20))
    verts = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 2, 0, 0]
    objects.add(mesh_geometry(22, "PlaneGeo", verts, [0, 1, 2, 3 ^ -1, 1, 4, 2 ^ -1], [
        layer_element("LayerElementNormal", "ByPolygon", "Direct", [("Normals", darr([0, 0, 1, 0, 0, 1]))]),
        layer_element("LayerElementUV", "ByVertice", "Direct", [("UV", darr([0, 0, 1, 0, 1, 1, 0, 1, 1, 0]))]),
    ]))
    conns.add(OO(22, 21))
    objects.add(Node("Material", [L(23), S("Matte\x00\x01Material"), S("")], [
        leaf("Version", I(102)), leaf("ShadingModel", S("lambert")),
        props70(P("DiffuseColor", "Color", "", "A", D(0.5), D(0.5), D(0.5))),
    ]))
    conns.add(OO(23, 21))
    objects.add(Node("Video", [L(24), S("dots\x00\x01Video"), S("Clip")], [
        leaf("Type", S("Clip")),
        leaf("Filename", S("dots.png")),
        leaf("RelativeFilename", S("dots.png")),
        leaf("Content", R(png(4, 4, checker))),
    ]))
    objects.add(Node("Texture", [L(25), S("Dots\x00\x01Texture"), S("")], [
        leaf("Type", S("TextureVideoClip")),
        leaf("FileName", S("dots.png")),
        leaf("RelativeFilename", S("dots.png")),
    ]))
    conns.add(OO(24, 25))
    conns.add(OP(25, 23, "DiffuseColor"))
    return [header(7400), global_settings(), objects, conns]

def main():
    os.makedirs(ASSETS, exist_ok=True)
    n = write_binary(os.path.join(ASSETS, "fbx_scene.fbx"), scene_nodes(), 7400)
    print("fbx_scene.fbx", n, "bytes")
    n = write_binary(os.path.join(ASSETS, "fbx_v7500.fbx"), v7500_nodes(), 7500)
    print("fbx_v7500.fbx", n, "bytes")
    write_ascii(os.path.join(ASSETS, "fbx_ascii.fbx"), ascii_nodes())
    print("fbx_ascii.fbx", os.path.getsize(os.path.join(ASSETS, "fbx_ascii.fbx")), "bytes")
    for folder in sample_paths.PLACES["fbx_scene.fbx"]:
        if folder != ASSETS:
            shutil.copyfile(os.path.join(ASSETS, "fbx_scene.fbx"), os.path.join(folder, "fbx_scene.fbx"))
    print("wrote", sample_paths.rel("fbx_scene.fbx"))

if __name__ == "__main__":
    main()
