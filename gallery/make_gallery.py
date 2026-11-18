#!/usr/bin/env python3
"""Writes gallery/gallery.rml: the ThreeAS landing page, in the Rive brand.

    python3 gallery/make_gallery.py           # then: rive . --artboard=Gallery
    python3 gallery/make_gallery.py --thumbs  # also re-render the card thumbnails

Thumbnails are screenshots of each example (rive --screenshot), centre-cropped
to 16:9 and scaled to twice the card size with macOS `sips`.

The page is one artboard, `Gallery`, bound to the `Gallery` view model. Its
stage is a NestedArtboardLayout whose `artboardId` is bound to the view
model's `demo` artboard property; each example card's click listener writes
that property (and the caption strings), so the chosen example artboard from
examples/examples.rml runs live, full size and interactive, in place.

Cards are one component, `ExampleCard`, placed 18 times as stateful nested
artboards (title, number and thumbnail per placement). A card's hover and
active looks are its own state machine; "active" is `selected == index`,
with `selected` bound from the page.

The examples' scripts see every pointer event in their artboard, and
OrbitControls claims each press, so the stage is drawn under everything and
an opaque clear shield covers the page around it: presses on the cards reach
the page first, and presses elsewhere never reach the example.

Ids: 2:* and 4:* are the Rive brand kit's theme and Logo (gallery/brand.rml,
kept as the kit has them), 100:* the page, 101:* the card, 102:* card
placements, 103:* thumbnails, 104:* component assets, 105:* generated page
elements, 106:* fonts. Colours bind to the kit's global RiveTheme (dark
first). The fonts are the brand's open ones; the brand's PragmataPro is
commercial, so the decorative labels use IoskeleyMono instead.
"""

import os
import subprocess
import sys
from xml.sax.saxutils import quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "gallery.rml")

# ----------------------------------------------------------------- content

# (artboard name, artboard id, state machine id, blurb, interactive?)
EXAMPLES = [
    ("FirstScene", "0:100", "0:107", "A lit cube wearing a live Rive artboard as its texture.", False),
    ("HelloCube", "0:300", "0:307", "three.js's “Creating a scene” tutorial, ported call for call.", False),
    ("Geometries", "0:400", "0:407", "Every built-in geometry, wearing a UV grid.", False),
    ("Materials", "0:500", "0:507", "Every mesh material under hemisphere, spot and point lights, fog and a sky.", False),
    ("Primitives", "0:600", "0:607", "Instancing, a points galaxy, lines, sprites and LODs.", False),
    ("Shapes", "0:700", "0:707", "Extruded curves and tubes, and a star drawn in Rive, extruded.", False),
    ("Interactive", "0:800", "0:807", "Orbit, click a Rive switch in 3D, hover the cubes, a render target TV.", True),
    ("Deform", "0:900", "0:907", "GPU skinning and morph targets, driven by an AnimationMixer.", True),
    ("Model", "0:1000", "0:1007", "A glTF binary loaded with GLTFLoader, its clips playing.", True),
    ("CustomShader", "0:1100", "0:1107", "A WGSL ShaderMaterial waving a live Rive artboard.", True),
    ("Environment", "0:1200", "0:1207", "Image-based lighting: metalness against roughness.", True),
    ("Environments", "0:1600", "0:1607", "Cube map, .hdr and .exr environments, and a CubeCamera mirror.", True),
    ("Textures", "0:1700", "0:1707", "UV transforms, a second UV set, KTX2 compressed textures.", True),
    ("MaterialsPlus", "0:1800", "0:1807", "Bump, displacement and light maps, glass, iridescence, anisotropy.", True),
    ("Clipping", "0:1900", "0:1907", "Clipping planes, stencil caps and clipped shadows.", True),
    ("Shadows", "0:1300", "0:1307", "Directional, spot and point light shadow maps, cut-outs included.", True),
    ("PostProcessing", "0:1400", "0:1407", "EffectComposer: bloom, ACES tone mapping and FXAA.", True),
    ("Lights", "0:2000", "0:2007", "Area lights, a street of lamps, a light probe and cascaded moonlight.", True),
    ("Editor", "0:2100", "0:2107", "Helpers for grids, axes, lights, cameras, boxes, planes and normals.", True),
    ("Batched", "0:2200", "0:2207", "A BatchedMesh: four geometries, 600 instances, one draw each.", True),
    ("Benchmark", "0:1500", "0:1507", "1000 meshes and 10000 instances, all moving.", False),
]
DEFAULT = 0  # FirstScene plays on load

HINT_ORBIT = "DRAG TO ORBIT  //  SCROLL TO ZOOM"
HINT_INTERACTIVE = "DRAG TO ORBIT  //  CLICK THE SWITCH"
HINT_AUTO = "AUTOPLAY  //  NO INPUT"


def hint(name, interactive):
    if name == "Interactive":
        return HINT_INTERACTIVE
    return HINT_ORBIT if interactive else HINT_AUTO


ONE_LINER = ("three.js ported to AnimaScript: the same API, rendered with "
             "Rive's GPU Canvas and WGSL shaders, inside your artboards.")

INSTALL = [
    ("c", "# copy three/ into your project, or add it as a library"),
    ("t", "rive library search"),
    ("t", "rive library add --library=<id>"),
]

QUICKSTART = [
    ("t", 'import * as THREE from "../three/Three";'),
    ("t", 'import { OrbitControls } from "../three/addons/controls/OrbitControls";'),
    ("t", 'import { Context } from "rive/host";'),
    ("t", ""),
    ("c", "// attach it to a ScriptedLayout in your artboard"),
    ("t", "export class Demo extends THREE.ThreeLayout {"),
    ("t", "    cube: THREE.Mesh = new THREE.Mesh("),
    ("t", "        new THREE.BoxGeometry(), new THREE.MeshNormalMaterial());"),
    ("t", "    override setup(context: Context): bool {"),
    ("t", "        this.scene.add(this.cube);"),
    ("t", "        this.camera.position.z = 3;"),
    ("t", "        this.controls = new OrbitControls(this.camera, this.renderer);"),
    ("t", "        return true;"),
    ("t", "    }"),
    ("t", "    override animate(seconds: f64): void {"),
    ("t", "        this.cube.rotation.y += seconds;"),
    ("t", "    }"),
    ("t", "}"),
]

FEATURES = [
    ("three.js API", "same names and signatures: Object3D, Scene, cameras"),
    ("Geometry", "20 built-ins, curves, shapes, extrusion, Rive paths"),
    ("Materials", "Basic to Physical, transmission, iridescence, WGSL"),
    ("Lights", "directional, spot, point, hemisphere, shadow maps"),
    ("Environments", "PMREM, cube maps, .hdr, .exr, KTX2 textures"),
    ("Animation", "glTF and OBJ loaders, AnimationMixer, skinning, morphs"),
    ("Primitives", "instancing, points, lines, sprites, LOD, clipping"),
    ("Post", "EffectComposer, bloom, FXAA, tone mapping"),
    ("Rive", "ThreeLayout, pointer controls, artboards as textures"),
]

# ------------------------------------------------------------------ layout

W = 1920
M = 120                      # page margin
LX, LW = M, 600              # left column
RX, RW = 800, 1000           # right column
ROW1 = 200
STAGE_H = 640
ROW2 = 960
CARD_W, THUMB_H, CARD_H, GAP = 155, 87, 117, 14
COLS = 6
# Tall enough for every row of cards, with the footer below them.
_rows = (len(EXAMPLES) + COLS - 1) // COLS
H = max(1480, ROW2 + 30 + _rows * (CARD_H + GAP) + 110)

# Theme properties on the kit's global RiveTheme view model (2:1).
BG, FG, SURFACE, MUTED, FAINT, ACCENT = "2:2", "2:3", "2:4", "2:5", "2:6", "2:7"
LITERAL = {BG: "FF000000", FG: "FFFFFFFF", SURFACE: "FF141414",
           MUTED: "FFA0A0A0", FAINT: "FF5C5C5C", ACCENT: "FFFFA41C"}

ORBITRON, INTER, MONO = "106:1", "106:2", "106:3"
WGHT = "2003265652"  # 'wght'


class Ids:
    def __init__(self, ns, start=1):
        self.ns, self.n = ns, start

    def __call__(self):
        i = f"{self.ns}:{self.n}"
        self.n += 1
        return i


def a(v):
    return quoteattr(str(v))


def color(prop, name="Color"):
    return (f'<SolidColor colorValue="{LITERAL[prop]}" name="{name}">'
            f'<DataBindContext sourcePathIds="2:1-{prop}" propertyKey="37"/></SolidColor>')


def fill(prop):
    return f'<Fill name="Fill">{color(prop)}</Fill>'


def stroke(prop, thickness=1, extra=""):
    return f'<Stroke thickness="{thickness}" cap="square"{extra} name="Stroke">{color(prop)}</Stroke>'


def style(sid, font, size, prop, weight=None, ls=0, lh=-1, name="Style"):
    axis = f'<TextStyleAxis tag="{WGHT}" axisValue="{weight}" name="Weight"/>' if weight else ""
    fam = {ORBITRON: ' familyName="Orbitron"', INTER: ' familyName="Inter"',
           MONO: ' familyName="IoskeleyMono"'}[font]
    extra = (f' letterSpacing="{ls}"' if ls else "") + (f' lineHeight="{lh}"' if lh != -1 else "")
    return (f'<TextStylePaint fontSize="{size}"{extra} fontAssetId="{font}"{fam} name="{name}" id="{sid}">'
            f'{fill(prop)}{axis}</TextStylePaint>')


def run(sid, text, name="Run", bind=None):
    b = f'<DataBindContext sourcePathIds="{bind}" propertyKey="268"/>' if bind else ""
    if b:
        return f'<TextValueRun styleId="{sid}" text={a(text)} name="{name}">{b}</TextValueRun>'
    return f'<TextValueRun styleId="{sid}" text={a(text)} name="{name}"/>'


def rect(x, y, w, h, name, prop=None, stroke_prop=None, thickness=1, sid=None, extra=""):
    paint = (fill(prop) if prop else "") + (stroke(stroke_prop, thickness) if stroke_prop else "")
    i = f' id="{sid}"' if sid else ""
    return (f'<Shape x="{x}" y="{y}"{extra} name={a(name)}{i}>'
            f'<Rectangle width="{w}" height="{h}" originX="0" originY="0" name="Path"/>{paint}</Shape>')


def bracket(x, y, dx, dy, name, arm=18):
    """An L-shaped FUI corner bracket with its corner at (x, y), arms toward
    (dx, dy)."""
    return (f'<Shape x="{x}" y="{y}" name={a(name)}><PointsPath name="Path">'
            f'<StraightVertex x="0" y="{dy * arm}"/><StraightVertex x="0" y="0"/>'
            f'<StraightVertex x="{dx * arm}" y="0"/></PointsPath>{stroke(FG, 2)}</Shape>')


# --------------------------------------------------------------- the page

def page():
    ids = Ids(105, 1)
    out = []
    o = out.append

    def text(x, y, runs_xml, styles_xml, name, attrs=""):
        o(f'<Text x="{x}" y="{y}"{attrs} name={a(name)} id="{ids()}">{styles_xml}{runs_xml}</Text>')

    def label(x, y, s, name, prop=FAINT, size=12, align="left"):
        sid = ids()
        attrs = ' originX="1" alignValue="right"' if align == "right" else (
            ' originX="0.5"' if align == "center" else "")
        text(x, y, run(sid, s), style(sid, MONO, size, prop, ls=1), name, attrs)

    def section(x, y, num, title, name):
        label(x, y + 2, num, name + "Num", FAINT, 13)
        sid = ids()
        text(x + 34, y, run(sid, title), style(sid, ORBITRON, 15, FG, 700, ls=2), name)

    def code(x, y, w, lines, name, tag):
        sid_t, sid_c, sid_tag = ids(), ids(), ids()
        lh = 20
        h = len(lines) * lh + 36
        runs = []
        for k, (kind, s) in enumerate(lines):
            nl = "\n" if k < len(lines) - 1 else ""
            runs.append(run(sid_c if kind == "c" else sid_t, s + nl, f"L{k + 1}"))
        o(f'<Node x="{x}" y="{y}" name={a(name)}>')
        o(f'<Text x="{w - 16}" y="12" originX="1" alignValue="right" name="Tag" id="{ids()}">'
          f'{style(sid_tag, MONO, 11, FAINT, ls=1)}{run(sid_tag, tag)}</Text>')
        o(f'<Text x="20" y="18" wrapValue="noWrap" name="Code" id="{ids()}">'
          f'{style(sid_t, MONO, 13, FG, lh=lh, name="Code")}'
          f'{style(sid_c, MONO, 13, MUTED, lh=lh, name="Comment")}{"".join(runs)}</Text>')
        o(rect(0, 0, w, h, "Panel", SURFACE))
        o('</Node>')
        return h

    # Content first: the first-declared drawable paints on top.

    # -- corner labels (FUI texture)
    top, bottom = 52, H - 64
    label(M, top, "REALTIME 3D", "LabelTL")
    label(W // 2, top, "// :: renderer = GPUCanvas → present", "LabelTC", align="center")
    label(W - M, top, "THREE.JS API", "LabelTR", align="right")
    label(M, bottom, "ANIMASCRIPT", "LabelBL")
    label(W // 2, bottom, f"// :: examples = {len(EXAMPLES)}  state = LIVE", "LabelBC", align="center")
    label(W - M, bottom, "WGSL", "LabelBR", align="right")

    # -- header: the Rive logo, the name, a readout
    o('<NestedArtboard artboardId="4:9" x="120" y="92" scaleX="0.4" scaleY="0.4" name="Logo">'
      '<NestedStateMachine animationId="4:1" name="SM"/></NestedArtboard>')
    sid = ids()
    text(184, 99, run(sid, "THREEAS"), style(sid, ORBITRON, 24, FG, 900, ls=2), "Brand")
    label(W - M, 106, "THREE.JS  ·  ANIMASCRIPT  ·  GPU CANVAS  ·  WGSL", "Readout", FAINT, 13, "right")
    o(rect(M, 156, W - 2 * M, 1, "Divider", FAINT))

    # -- row 1, left: kicker, title, one-liner, install, features
    sid = ids()
    text(LX, ROW1, run(sid, "THREE.JS FOR RIVE"), style(sid, ORBITRON, 18, ACCENT, 700, ls=3), "Kicker")
    sid = ids()
    text(LX - 4, ROW1 + 28, run(sid, "THREEAS"), style(sid, ORBITRON, 88, FG, 900), "Title")
    sid = ids()
    text(LX, ROW1 + 150, run(sid, ONE_LINER), style(sid, INTER, 21, MUTED, 400, lh=31), "OneLiner",
         f' width="{LW}" sizingValue="autoHeight" wrapValue="wrap"')

    y = ROW1 + 270
    section(LX, y, "01", "INSTALL", "Install")
    code(LX, y + 30, LW, INSTALL, "InstallCode", "SHELL")

    y = ROW1 + 436
    section(LX, y, "02", "FEATURES", "Features")
    for k, (lead, rest) in enumerate(FEATURES):
        fy = y + 34 + k * 26
        sid_lead, sid_rest = ids(), ids()
        o(rect(LX, fy + 8, 6, 6, f"Bullet{k + 1}", FG))
        text(LX + 20, fy, run(sid_lead, lead + "   ", "Lead") + run(sid_rest, rest, "Rest"),
             style(sid_lead, INTER, 16, FG, 600, name="Lead") + style(sid_rest, INTER, 16, MUTED, 400, name="Rest"),
             f"Feature{k + 1}")

    # -- row 1, right: the stage
    o(bracket(RX - 10, ROW1 - 10, 1, 1, "BracketTL"))
    o(bracket(RX + RW + 10, ROW1 - 10, -1, 1, "BracketTR"))
    o(bracket(RX - 10, ROW1 + STAGE_H + 10, 1, -1, "BracketBL"))
    o(bracket(RX + RW + 10, ROW1 + STAGE_H + 10, -1, -1, "BracketBR"))
    first = EXAMPLES[DEFAULT]
    stage = (f'<LayoutComponent width="{RW}" height="{STAGE_H}" styleId="100:6" name="Stage" id="100:5">'
      f'<LayoutComponentStyle positionTypeValue="absolute" positionLeft="{RX}" positionLeftUnitsValue="points" '
      f'positionTop="{ROW1}" positionTopUnitsValue="points" layoutWidthScaleType="fixed" '
      f'layoutHeightScaleType="fixed" name="Stage Style" id="100:6"/>'
      f'<NestedArtboardLayout artboardId="{first[1]}" instanceWidth="100" instanceWidthUnitsValue="percent" '
      f'instanceHeight="100" instanceHeightUnitsValue="percent" name="Player" id="100:7">'
      f'<DataBindContext sourcePathIds="100:50-100:51" propertyKey="197"/>'
      f'<NestedStateMachine animationId="{first[2]}" name="SM"/>'
      f'</NestedArtboardLayout>'
      f'{fill(SURFACE)}</LayoutComponent>')

    cy = ROW1 + STAGE_H + 22
    sid = ids()
    text(RX, cy, run(sid, first[0].upper(), bind="100:50-100:53"), style(sid, ORBITRON, 22, FG, 700, ls=2), "DemoTitle")
    sid = ids()
    text(RX, cy + 34, run(sid, first[3], bind="100:50-100:54"), style(sid, INTER, 16, MUTED, 400), "DemoBlurb")
    sid = ids()
    text(RX + RW, cy + 4, run(sid, hint(first[0], first[4]), bind="100:50-100:55"),
         style(sid, MONO, 12, FAINT, ls=1), "DemoHint", ' originX="1" alignValue="right"')
    o(rect(RX + RW - 8, cy + 38, 8, 8, "LiveDot", FG))
    label(RX + RW - 18, cy + 34, "LIVE", "LiveLabel", FG, 12, "right")

    # -- row 2, left: quickstart
    section(LX, ROW2, "03", "QUICKSTART", "Quickstart")
    code(LX, ROW2 + 30, LW, QUICKSTART, "QuickstartCode", "ANIMASCRIPT")

    # -- row 2, right: the example cards
    section(RX, ROW2, "04", "EXAMPLES", "Examples")
    label(RX + RW, ROW2 + 2, f"{len(EXAMPLES)} LIVE DEMOS  //  CLICK A CARD TO RUN IT", "ExamplesHint", FAINT, 12, "right")
    pid = Ids(102, 1)
    card_ids = []
    for k, (name, ab, sm, blurb, inter) in enumerate(EXAMPLES):
        cx = RX + (k % COLS) * (CARD_W + GAP)
        cyy = ROW2 + 30 + (k // COLS) * (CARD_H + GAP)
        nid, iid, hid = pid(), pid(), pid()
        card_ids.append(hid)
        o(f'<NestedArtboard artboardId="101:1" isStateful="true" x="{cx}" y="{cyy}" name="Card{name}" id="{nid}">'
          f'<ViewModelInstance viewModelId="101:50" exports="true" name="{name} Card" id="{iid}">'
          f'<ViewModelInstanceString propertyValue={a(name.upper())} viewModelPropertyId="101:51"/>'
          f'<ViewModelInstanceString propertyValue="{k + 1:02d}" viewModelPropertyId="101:52"/>'
          f'<ViewModelInstanceAssetImage propertyValue="103:{k + 1}" viewModelPropertyId="101:53"/>'
          f'<ViewModelInstanceNumber propertyValue="{k}" viewModelPropertyId="101:54"/>'
          f'<ViewModelInstanceNumber propertyValue="{DEFAULT}" viewModelPropertyId="101:55">'
          f'<DataBindContext sourcePathIds="100:50-100:52" propertyKey="575"/></ViewModelInstanceNumber>'
          f'<ViewModelInstanceBoolean propertyValue="false" viewModelPropertyId="101:56"/>'
          f'</ViewModelInstance>'
          f'<NestedStateMachine animationId="101:2" name="SM"/></NestedArtboard>')
        # A listener cannot target the nested artboard itself: the page's
        # click lands on this clear shape under the card (declared after
        # it), so the card's own hover listeners see the pointer too.
        o(f'<Shape x="{cx}" y="{cyy}" name="Hit{name}" id="{hid}">'
          f'<Rectangle width="{CARD_W}" height="{CARD_H}" originX="0" originY="0" name="Path"/>'
          f'<Fill name="Fill"><SolidColor colorValue="00000000" name="Clear"/></Fill></Shape>')

    # The stage goes last, under everything else: listeners are hit-tested
    # top-down, and an example's script is handed every pointer event in
    # its artboard (OrbitControls claims each press with event.hit()), so
    # the cards above must see a press first. Between them, an opaque,
    # clear shield over the page around the stage stops presses elsewhere
    # on the page from reaching the example (a drag on the code would orbit
    # its camera).
    sb = ROW1 + STAGE_H
    shield = "".join(
        f'<Rectangle x="{x}" y="{y}" width="{w}" height="{h}" originX="0" originY="0" name="{n}"/>'
        for n, x, y, w, h in [("Top", 0, 0, W, ROW1), ("Bottom", 0, sb, W, H - sb),
                              ("Left", 0, ROW1, RX, STAGE_H), ("Right", RX + RW, ROW1, W - RX - RW, STAGE_H)])
    o(f'<Shape isTargetOpaque="true" name="PointerShield" id="100:8">{shield}'
      f'<Fill name="Fill"><SolidColor colorValue="00000000" name="Clear"/></Fill></Shape>')
    o(stage)

    o(f'<Fill name="Background">{color(BG)}</Fill>')

    # -- the state machine: a click on a card plays its example
    sm = ['<StateMachine name="State Machine 1" id="100:2">',
          '<StateMachineLayer name="Layer 1" id="100:3"><EntryState/></StateMachineLayer>']
    for k, (name, ab, smid, blurb, inter) in enumerate(EXAMPLES):
        def write(kind, key, prop, value):
            return (f'<ListenerViewModelChange><BindableProperty{kind} propertyValue={a(value)}>'
                    f'<DataBindContext sourcePathIds="100:50-{prop}" propertyKey="{key}" direction="true"/>'
                    f'</BindableProperty{kind}></ListenerViewModelChange>')
        sm.append(f'<StateMachineListenerSingle targetId="{card_ids[k]}" listenerTypeValue="click" name="Play{name}">'
                  + write("Artboard", 823, "100:51", ab)
                  + write("Number", 636, "100:52", k)
                  + write("String", 635, "100:53", name.upper())
                  + write("String", 635, "100:54", blurb)
                  + write("String", 635, "100:55", hint(name, inter))
                  + '</StateMachineListenerSingle>')
    # The shield only blocks as a listener target; it does nothing itself.
    sm.append('<StateMachineListenerSingle targetId="100:8" listenerTypeValue="down" name="Shield"/>')
    sm.append('</StateMachine>')

    body = "\n        ".join(out)
    return (f'<Artboard defaultStateMachineId="100:2" viewModelId="100:50" viewModelInstanceId="100:56" '
            f'clip="true" x="0" y="-1700" width="{W}" height="{H}" styleId="100:4" name="Gallery" id="100:1">\n'
            f'        <LayoutComponentStyle name="Artboard Style" id="100:4"/>\n'
            f'        {body}\n        ' + "\n        ".join(sm) + '\n    </Artboard>')


# ---------------------------------------------------------------- the card

def key_opacity(anim_id, name, target, value):
    return (f'<LinearAnimation duration="1" name="{name}" id="{anim_id}"><KeyedObject objectId="{target}">'
            f'<KeyedProperty property="opacity"><KeyFrameDouble value="{value}" interpolationType="hold"/>'
            f'</KeyedProperty></KeyedObject></LinearAnimation>')


def number_cmp(prop):
    return (f'<TransitionPropertyViewModelComparator><BindablePropertyNumber>'
            f'<DataBindContext sourcePathIds="101:50-{prop}" propertyKey="636"/>'
            f'</BindablePropertyNumber></TransitionPropertyViewModelComparator>')


def hover_is(value):
    return (f'<TransitionViewModelCondition><TransitionPropertyViewModelComparator><BindablePropertyBoolean>'
            f'<DataBindContext sourcePathIds="101:50-101:56" propertyKey="634"/></BindablePropertyBoolean>'
            f'</TransitionPropertyViewModelComparator><TransitionValueBooleanComparator value="{value}"/>'
            f'</TransitionViewModelCondition>')


def set_hover(value):
    return (f'<ListenerViewModelChange><BindablePropertyBoolean propertyValue="{value}">'
            f'<DataBindContext sourcePathIds="101:50-101:56" propertyKey="634" direction="true"/>'
            f'</BindablePropertyBoolean></ListenerViewModelChange>')


def card():
    first = EXAMPLES[0][0]
    return f'''<Artboard isComponent="true" defaultStateMachineId="101:2" viewModelId="101:50" viewModelInstanceId="101:57" clip="false" x="2200" y="-1700" width="{CARD_W}" height="{CARD_H}" styleId="101:3" name="ExampleCard" id="101:1">
        <LayoutComponentStyle name="Card Style" id="101:3"/>
        <!-- Hit area for the hover listeners (and the page's click). -->
        <Shape name="Hit" id="101:10"><Rectangle width="{CARD_W}" height="{CARD_H}" originX="0" originY="0" name="Path"/><Fill name="Fill"><SolidColor colorValue="00000000" name="Clear"/></Fill></Shape>
        <!-- Number tag over the thumbnail's corner. -->
        <Text x="5" y="3" name="Number" id="101:14">
            {style("101:15", MONO, 10, FG, ls=1)}
            {run("101:15", "01", bind="101:50-101:52")}
        </Text>
        {rect(0, 0, 24, 16, "Tag", BG)}
        {rect(1, 1, CARD_W - 2, THUMB_H - 2, "ActiveFrame", None, ACCENT, 2, "101:11", ' opacity="0"')}
        {rect(1, 1, CARD_W - 2, THUMB_H - 2, "HoverFrame", None, FG, 2, "101:12", ' opacity="0"')}
        {rect(0, 0, CARD_W, THUMB_H, "Frame", None, FAINT, 1)}
        <Image x="{CARD_W / 2}" y="{THUMB_H / 2}" scaleX="0.5" scaleY="0.5" assetId="103:1" name="Thumb" id="101:13">
            <DataBindContext sourcePathIds="101:50-101:53" propertyKey="206"/>
        </Image>
        <Text x="0" y="{THUMB_H + 11}" name="Name" id="101:16">
            {style("101:17", ORBITRON, 11, FG, 700, ls=1)}
            {run("101:17", first.upper(), bind="101:50-101:51")}
        </Text>
        <StateMachine name="State Machine 1" id="101:2">
            <StateMachineLayer name="Hover" id="101:20">
                <EntryState x="0" y="0"><StateTransition stateToId="101:21"/></EntryState>
                <AnimationState x="200" y="0" animationId="101:30" id="101:21">
                    <StateTransition stateToId="101:22" duration="100">{hover_is("true")}</StateTransition>
                </AnimationState>
                <AnimationState x="400" y="0" animationId="101:31" id="101:22">
                    <StateTransition stateToId="101:21" duration="160">{hover_is("false")}</StateTransition>
                </AnimationState>
            </StateMachineLayer>
            <StateMachineLayer name="Active" id="101:23">
                <EntryState x="0" y="0"><StateTransition stateToId="101:24"/></EntryState>
                <AnimationState x="200" y="0" animationId="101:32" id="101:24">
                    <StateTransition stateToId="101:25"><TransitionViewModelCondition opValue="equal">{number_cmp("101:55")}{number_cmp("101:54")}</TransitionViewModelCondition></StateTransition>
                </AnimationState>
                <AnimationState x="400" y="0" animationId="101:33" id="101:25">
                    <StateTransition stateToId="101:24"><TransitionViewModelCondition opValue="notEqual">{number_cmp("101:55")}{number_cmp("101:54")}</TransitionViewModelCondition></StateTransition>
                </AnimationState>
            </StateMachineLayer>
            <StateMachineListenerSingle targetId="101:10" listenerTypeValue="enter" name="In">{set_hover("true")}</StateMachineListenerSingle>
            <StateMachineListenerSingle targetId="101:10" listenerTypeValue="exit" name="Out">{set_hover("false")}</StateMachineListenerSingle>
        </StateMachine>
        {key_opacity("101:30", "Rest", "101:12", 0)}
        {key_opacity("101:31", "Hover", "101:12", 1)}
        {key_opacity("101:32", "Off", "101:11", 0)}
        {key_opacity("101:33", "On", "101:11", 1)}
    </Artboard>'''


# ------------------------------------------------- view models and assets

def roots():
    first = EXAMPLES[DEFAULT]
    thumbs = "\n    ".join(
        f'<ImageAsset file="gallery/thumbs/{n}.png" name="thumb_{n}" id="103:{k + 1}"/>'
        for k, (n, *_rest) in enumerate(EXAMPLES))
    examples = "\n    ".join(
        f'<ComponentAsset artboardId="{ab}" name="{n}" id="104:{10 + k}"/>'
        for k, (n, ab, *_rest) in enumerate(EXAMPLES))
    return f'''<ViewModel defaultInstanceId="100:56" name="Gallery" id="100:50">
        <ViewModelPropertyArtboard name="demo" id="100:51"/>
        <ViewModelPropertyNumber name="selected" id="100:52"/>
        <ViewModelPropertyString name="title" id="100:53"/>
        <ViewModelPropertyString name="blurb" id="100:54"/>
        <ViewModelPropertyString name="hint" id="100:55"/>
        <ViewModelInstance exports="true" name="Default" id="100:56">
            <ViewModelInstanceArtboard propertyValue="{first[1]}" viewModelPropertyId="100:51"/>
            <ViewModelInstanceNumber propertyValue="{DEFAULT}" viewModelPropertyId="100:52"/>
            <ViewModelInstanceString propertyValue={a(first[0].upper())} viewModelPropertyId="100:53"/>
            <ViewModelInstanceString propertyValue={a(first[3])} viewModelPropertyId="100:54"/>
            <ViewModelInstanceString propertyValue={a(hint(first[0], first[4]))} viewModelPropertyId="100:55"/>
        </ViewModelInstance>
    </ViewModel>

    <ViewModel defaultInstanceId="101:57" name="ExampleCard" id="101:50">
        <ViewModelPropertyString componentProps="1" name="name" id="101:51"/>
        <ViewModelPropertyString componentProps="1" name="number" id="101:52"/>
        <ViewModelPropertyAssetImage componentProps="1" name="thumb" id="101:53"/>
        <ViewModelPropertyNumber componentProps="1" name="index" id="101:54"/>
        <ViewModelPropertyNumber componentProps="1" name="selected" id="101:55"/>
        <ViewModelPropertyBoolean name="hover" id="101:56"/>
        <ViewModelInstance exports="true" name="Default" id="101:57">
            <ViewModelInstanceString propertyValue={a(EXAMPLES[0][0].upper())} viewModelPropertyId="101:51"/>
            <ViewModelInstanceString propertyValue="01" viewModelPropertyId="101:52"/>
            <ViewModelInstanceAssetImage propertyValue="103:1" viewModelPropertyId="101:53"/>
            <ViewModelInstanceNumber propertyValue="0" viewModelPropertyId="101:54"/>
            <ViewModelInstanceNumber propertyValue="-1" viewModelPropertyId="101:55"/>
            <ViewModelInstanceBoolean propertyValue="false" viewModelPropertyId="101:56"/>
        </ViewModelInstance>
    </ViewModel>

    <ComponentAsset artboardId="101:1" name="ExampleCard" id="104:2"/>

    <!-- The example artboards (examples/examples.rml marks them
         isComponent="true"), so the stage can nest them. -->
    {examples}

    <FontAsset file="gallery/fonts/Orbitron.ttf" name="Orbitron" id="{ORBITRON}"/>
    <FontAsset file="gallery/fonts/Inter.ttf" name="Inter" id="{INTER}"/>
    <FontAsset file="gallery/fonts/IoskeleyMono-Regular.ttf" name="IoskeleyMono" id="{MONO}"/>
    {thumbs}'''


HEADER = """<Rive version="1" kind="fragment">
    <!-- GENERATED by gallery/make_gallery.py: edit the script and rerun it.

         Gallery: the ThreeAS landing page (rive . --artboard=Gallery). The
         stage's NestedArtboardLayout has its artboardId bound to the Gallery
         view model's `demo` artboard property; clicking an ExampleCard writes
         that property, so the example artboard from examples/examples.rml
         runs live and takes pointer input in place. -->
"""


def thumbs():
    root = os.path.dirname(HERE)
    shots = os.path.join(root, "build", "thumbs")
    os.makedirs(shots, exist_ok=True)
    for name, *_rest in EXAMPLES:
        shot = os.path.join(shots, name + ".png")
        crop = os.path.join(shots, name + "_crop.png")
        subprocess.run(["rive", root, f"--artboard={name}", f"--screenshot={shot}", "--advance=2s"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["sips", "-c", "450", "800", shot, "--out", crop], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["sips", "-z", str(2 * THUMB_H), str(2 * CARD_W), crop, "--out",
                        os.path.join(HERE, "thumbs", name + ".png")], check=True, stdout=subprocess.DEVNULL)
        print("thumb", name)


def main():
    if "--thumbs" in sys.argv:
        thumbs()
    with open(OUT, "w") as f:
        f.write(HEADER)
        f.write("    " + page() + "\n\n")
        f.write("    " + card() + "\n\n")
        f.write("    " + roots() + "\n</Rive>\n")
    print("wrote", os.path.relpath(OUT))


if __name__ == "__main__":
    main()
