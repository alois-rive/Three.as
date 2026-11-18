#!/usr/bin/env python3
"""Writes gallery/gallery.rml: the ThreeAS landing page, built in Rive.

    python3 gallery/make_gallery.py           # then: rive . --artboard=Gallery
    python3 gallery/make_gallery.py --thumbs  # also re-render the card thumbnails

The page is built from Rive layouts, styled after rive.app: one `Gallery`
artboard whose root is a vertical scroll view (a clipped viewport, a `hug`
content column with a ScrollConstraint). Sections are centred columns capped
at 1280pt; rows that should become columns on narrow screens are wrapping
rows of `fill` boxes with a minimum width (the hero puts its stage first in
a `rowReverse`, so it sits right when wide and on top when narrow), and the
card grids wrap. The previewer's default `layout` fit resizes the artboard
to the window, so the page reflows at any width.

The stage is a NestedArtboardLayout whose `artboardId` is bound to the
`Gallery` view model's `demo` artboard property. A click on an example card
writes it (and the caption), so the chosen example artboard from
examples/examples.rml runs live in the stage, at the stage's size, with its
own pointer input; the click also scrolls the page back to the stage. The
nav and hero buttons scroll to their sections through the ScrollConstraint's
`scrollIndex`, bound to the view model's `section`.

Cards are one component, `ExampleCard`, placed as stateful nested artboards
(name, blurb, number and thumbnail per placement), with its own hover and
active ("PLAYING") states; active is `selected == index`.

Ids: 2:* and 4:* are the Rive brand kit's theme and Logo (gallery/brand.rml),
100:* the page's fixed ids and view model, 101:* the card, 102:* card slots
and placements, 103:* thumbnails, 104:* component assets, 105:* generated
page elements, 106:* fonts. rive.app's PragmataPro is commercial, so its
mono labels and buttons use IoskeleyMono here.

Thumbnails are screenshots of each example (rive --screenshot), centre-cropped
to 16:9 and scaled with macOS `sips`.
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


def hint(name, interactive):
    if name == "Interactive":
        return "DRAG TO ORBIT · CLICK THE SWITCH"
    return "DRAG TO ORBIT · SCROLL TO ZOOM" if interactive else "AUTOPLAY"


EYEBROW = "THREEAS · THREE.JS FOR RIVE"
HEADLINE = "THREE.JS, RUNNING IN RIVE."
ONE_LINER = ("The three.js API, ported to AnimaScript. Scenes render with Rive's "
             "GPU Canvas and WGSL shaders, right inside your artboards.")

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

STEPS = [
    ("01", "Install", "Copy three/ into your project, or add ThreeAS as a Rive library."),
    ("02", "Write a scene", "Extend ThreeLayout: setup() builds the scene with three.js's API, animate() moves it."),
    ("03", "Run it", "Attach the script to a ScriptedLayout, then open the project in the Rive CLI's previewer. "
                     "It is a Rive file like any other."),
]

FEATURES = [
    ("three.js API", "Same names and signatures: Object3D, Scene, cameras, BufferGeometry, events, clone and copy."),
    ("Geometry", "Every built-in geometry, curves, shapes, extrusion, text, and Rive paths turned into 3D."),
    ("Materials", "Basic to Physical: transmission, iridescence, sheen, clearcoat, and WGSL ShaderMaterials."),
    ("Lights and shadows", "Directional, spot, point, hemisphere and area lights, probes, cascaded shadow maps."),
    ("Environments", "PMREM image-based lighting from cube maps, .hdr and .exr files; KTX2 textures."),
    ("Animation", "glTF and OBJ loaders, AnimationMixer, GPU skinning and morph targets."),
    ("Primitives", "Instancing, points, lines, sprites, LOD, clipping planes and helpers."),
    ("Post-processing", "EffectComposer with bloom, FXAA and tone mapping passes."),
    ("Made for Rive", "ThreeLayout, orbit controls on Rive pointer events, live artboards as textures."),
]

# Section order inside the scroll content (their index is `scrollIndex`).
SEC_NAV, SEC_HERO, SEC_EXAMPLES, SEC_START, SEC_FEATURES, SEC_FOOTER = range(6)

# ------------------------------------------------------------------ styling
# rive.app's language: black ground, white Orbitron 900 caps headlines with
# tight tracking, Inter 500 caps eyebrows and nav (+0.08em), Inter body at
# 80% white, hairline borders at 10% white that brighten on hover, faint
# card fills, white 4px-radius buttons with mono caps labels.

BG = "FF000000"
WHITE = "FFFFFFFF"
TEXT = "CCFFFFFF"        # body, 80%
NAV = "D9FFFFFF"         # nav links, 85%
DIM = "99FFFFFF"         # secondary, 60%
FAINT = "66FFFFFF"       # labels, 40%
CARD = "06FFFFFF"        # card fill, 2.5%
PANEL = "0DFFFFFF"       # code panel, 5%
LINE = "1AFFFFFF"        # hairline, 10%
LINE_SOFT = "14FFFFFF"   # nav rule, 8%
LINE_HOVER = "4DFFFFFF"  # hover border, 30%
AMBER = "FFFFA41C"       # Rive Amber, the one accent
STAGE_BG = "FF0C0C0C"

MAX_W = 1280             # content width cap
PAD_X = 24               # page side padding
ORBITRON, INTER, MONO = "106:1", "106:2", "106:3"
WGHT = "2003265652"      # 'wght'


def a(v):
    return quoteattr(str(v))


class Ids:
    def __init__(self, ns, start=1):
        self.ns, self.n = ns, start

    def __call__(self):
        i = f"{self.ns}:{self.n}"
        self.n += 1
        return i


ids = Ids(105)
PHYSICS = []  # one ElasticScrollPhysics per code panel


def paint(kind, color, extra=""):
    return f'<{kind}{extra} name="{kind}"><SolidColor colorValue="{color}" name="Color"/></{kind}>'


def solid_id(kind, color, cid, extra=""):
    """A Fill/Stroke whose SolidColor has an id (to key its colour)."""
    return f'<{kind}{extra} name="{kind}"><SolidColor colorValue="{color}" name="Color" id="{cid}"/></{kind}>'


# ------------------------------------------------------------ layout boxes

def box(name, children="", *, d="column", w="fill", h="hug", width=0, height=0,
        gap=0, gapx=None, gapy=None, pad=0, wrap=False, align=None, minw=None, maxw=None,
        aspect=None, fill=None, stroke=None, radius=0, clip=False, frac=None,
        absolute=None, opacity=None, basis=None, pct=None, bid=None, style="", extra=""):
    """A LayoutComponent and its style. `pad` is one number or (t, r, b, l);
    `absolute` is a dict of insets (left/right/top/bottom) for an overlay."""
    bid = bid or ids()
    sid = ids()
    t, r, b, l = (pad, pad, pad, pad) if isinstance(pad, (int, float)) else pad
    gx = gap if gapx is None else gapx
    gy = gap if gapy is None else gapy
    st = [f'flexDirectionValue="{d}"', f'layoutWidthScaleType="{w}"', f'layoutHeightScaleType="{h}"']
    if gx: st.append(f'gapHorizontal="{gx}"')
    if gy: st.append(f'gapVertical="{gy}"')
    for k, v in (("Top", t), ("Right", r), ("Bottom", b), ("Left", l)):
        if v: st.append(f'padding{k}="{v}"')
    if wrap: st.append('flexWrapValue="wrap"')
    if basis is not None:
        # A number is points, a string like "18%" a percentage of the row.
        unit = "percent" if isinstance(basis, str) else "points"
        st.append(f'flexBasis="{str(basis).rstrip("%")}" flexBasisUnitsValue="{unit}"')
    if pct is not None:
        # A percentage width, so a centring parent can centre it (a `fill`
        # child is stretched, and a max width then clamps it at the start).
        w, width = "fixed", pct
        st[1] = 'layoutWidthScaleType="fixed" widthUnitsValue="percent"'
    if align: st.append(f'layoutAlignmentType="{align}"')
    if minw is not None: st.append(f'minWidth="{minw}" minWidthUnitsValue="points"')
    if maxw is not None: st.append(f'maxWidth="{maxw}" maxWidthUnitsValue="points"')
    if aspect: st.append(f'aspectRatio="{aspect}" aspectRatioAxisValue="width"')
    if radius:
        st.append(f'linkCornerRadius="true" cornerRadiusTL="{radius}" cornerRadiusTR="{radius}" '
                  f'cornerRadiusBL="{radius}" cornerRadiusBR="{radius}"')
    if absolute:
        st.append('positionTypeValue="absolute"')
        for k, v in absolute.items():
            st.append(f'position{k.capitalize()}="{v}" position{k.capitalize()}UnitsValue="points"')
    attrs = f' clip="{"true" if clip else "false"}" width="{width}" height="{height}"'
    if frac is not None: attrs += f' fractionalWidth="{frac}"'
    if opacity is not None: attrs += f' opacity="{opacity}"'
    paints = (paint("Fill", fill) if fill else "") + (paint("Stroke", stroke, ' thickness="1"') if stroke else "")
    return (f'<LayoutComponent{attrs}{extra} styleId="{sid}" name={a(name)} id="{bid}">'
            f'<LayoutComponentStyle {" ".join(st)}{style} name={a(name + " Style")} id="{sid}"/>'
            f'{children}{paints}</LayoutComponent>')


def tstyle(font, size, color, weight=None, ls=0, lh=-1, name="Style", fill_id=None):
    sid = ids()
    fam = {ORBITRON: "Orbitron", INTER: "Inter", MONO: "IoskeleyMono"}[font]
    axis = f'<TextStyleAxis tag="{WGHT}" axisValue="{weight}" name="Weight"/>' if weight else ""
    extra = (f' letterSpacing="{ls}"' if ls else "") + (f' lineHeight="{lh}"' if lh != -1 else "")
    f = solid_id("Fill", color, fill_id) if fill_id else paint("Fill", color)
    return sid, (f'<TextStylePaint fontSize="{size}"{extra} fontAssetId="{font}" familyName="{fam}" '
                 f'name="{name}" id="{sid}">{f}{axis}</TextStylePaint>')


def run(sid, s, name="Run", bind=None):
    b = f'<DataBindContext sourcePathIds="{bind}" propertyKey="268"/>' if bind else ""
    return f'<TextValueRun styleId="{sid}" text={a(s)} name="{name}">{b}</TextValueRun>'


def text(name, runs, *, w="fill", align=None, wrap=True, tid=None, extra=""):
    """A Text in the layout flow. `runs` is a list of (style, string[, bind])
    where style is a tstyle() result; equal styles are declared once."""
    styles, body, seen = [], [], {}
    for k, r in enumerate(runs):
        (sid, sxml), s = r[0], r[1]
        if sid not in seen:
            seen[sid] = True
            styles.append(sxml)
        body.append(run(sid, s, f"Run{k + 1}", r[2] if len(r) > 2 else None))
    h = "hug"
    attrs = f' wrapValue="{"wrap" if wrap else "noWrap"}"'
    if w == "hug":
        attrs += ' sizingValue="autoWidth"'
    if align:
        attrs += f' alignValue="{align}"'
    return (f'<Text{attrs}{extra} name={a(name)} id="{tid or ids()}">'
            f'<LayoutParticipant layoutWidthScaleType="{w}" layoutHeightScaleType="{h}" name="Layout"/>'
            f'{"".join(styles)}{"".join(body)}</Text>')


# Type scale (rive.app).
def T_eyebrow(color=TEXT): return tstyle(INTER, 12, color, 500, ls=0.96, lh=16)
def T_h1(): return tstyle(ORBITRON, 48, WHITE, 900, ls=-1.44, lh=49)
def T_h2(): return tstyle(ORBITRON, 34, WHITE, 900, ls=-0.34, lh=37)
def T_body(color=TEXT): return tstyle(INTER, 16, color, 400, lh=24)
def T_small(color=DIM): return tstyle(INTER, 14, color, 400, lh=21)
def T_title(): return tstyle(INTER, 15, WHITE, 500, lh=20)
def T_nav(): return tstyle(INTER, 12, NAV, 500, ls=0.96)
def T_mono(color=DIM, size=12): return tstyle(MONO, size, color, ls=size * 0.1)


def button(name, label, primary, bid):
    """rive.app's buttons: white with black mono caps, or a hairline ghost."""
    t = text(name + "Label", [(T_mono(BG if primary else WHITE, 12), label)], w="hug", wrap=False)
    return box(name, t, d="row", w="hug", pad=(9, 14, 10, 14), radius=4, bid=bid,
               fill=WHITE if primary else "00000000", stroke=None if primary else LINE_HOVER)


def section(name, children, *, top=96, bottom=0, sid=None):
    """A full-width band with a centred column capped at MAX_W."""
    inner = box(name + "Inner", children, pct=100, maxw=MAX_W, gap=40)
    return box(name, inner, w="fill", pad=(top, PAD_X, bottom, PAD_X), align="topCenter", bid=sid)


def header(eyebrow, title, body=None):
    parts = [text("Eyebrow", [(T_eyebrow(), eyebrow)]), text("Title", [(T_h2(), title)])]
    if body:
        parts.append(box("BodyCap", text("Body", [(T_body(), body)]), w="fill", maxw=640))
    return box("Header", "".join(parts), gap=14)


def code_panel(name, tab, lines):
    """A code panel: a header strip, then the code in a horizontal scroll
    view so long lines stay readable on narrow screens."""
    physics = ids()
    PHYSICS.append(f'<ElasticScrollPhysics friction="2.5" elasticFactor="0.7" name="CodePhysics" id="{physics}"/>')
    code_t, code_c = tstyle(MONO, 13, WHITE, lh=21, name="Code"), tstyle(MONO, 13, DIM, lh=21, name="Comment")
    runs = [((code_c if kind == "c" else code_t), s + ("\n" if k < len(lines) - 1 else ""))
            for k, (kind, s) in enumerate(lines)]
    head = box("Tab", text("TabName", [(T_mono(DIM, 11), tab)], w="hug", wrap=False)
               + text("TabLang", [(T_mono(FAINT, 11), "ANIMASCRIPT" if tab.endswith(".as") else "SHELL")],
                      w="hug", wrap=False),
               d="row", w="fill", align="spaceBetweenCenter", pad=(10, 16, 10, 16))
    rule = box("Rule", w="fill", h="fixed", height=1, fill=LINE)
    scroll = box("CodeContent", text("Code", runs, w="hug", wrap=False)
                 + f'<ScrollConstraint directionValue="horizontal" physicsId="{physics}" name="Scroll"/>',
                 
                 w="hug", pad=(16, 20, 18, 20))
    view = box("CodeView", scroll, d="row", w="fill", clip=True)
    return box(name, head + rule + view, w="fill", fill=PANEL, stroke=LINE, radius=4, clip=True)


# --------------------------------------------------------------- the page

def page():
    first = EXAMPLES[DEFAULT]
    listeners = []  # (target id, [(kind, key, prop, value)])

    def scroll_to(sec):
        # Write -1 first so the same section scrolls again after the user
        # scrolled away (a write of an unchanged value is not a change).
        return [("Number", 636, "100:57", -1), ("Number", 636, "100:57", sec)]

    # -- nav
    logo = ('<LayoutComponent clip="false" width="22" height="22" styleId="100:20" name="LogoSlot" id="100:21">'
            '<LayoutComponentStyle layoutWidthScaleType="fixed" layoutHeightScaleType="fixed" '
            'name="LogoSlot Style" id="100:20"/>'
            '<NestedArtboardLeaf artboardId="4:9" fit="contain" name="Logo">'
            '<NestedStateMachine animationId="4:1" name="SM"/></NestedArtboardLeaf></LayoutComponent>')
    brand = box("Brand", logo + text("Name", [(tstyle(ORBITRON, 16, WHITE, 900, ls=0.5), "THREEAS")], w="hug", wrap=False),
                d="row", w="hug", gap=10, align="centerLeft")
    nav_ids = {"Features": ids(), "Quickstart": ids(), "Examples": ids()}
    # Right to left: the button first, then the links. The box is clipped to
    # the nav's height and wraps, so on a narrow screen the links that do not
    # fit drop to a second, hidden line: a responsive nav with no breakpoint.
    links = button("NavExamples", "EXAMPLES", True, nav_ids["Examples"])
    links += "".join(
        box(f"Nav{n}", text(f"Nav{n}Label", [(T_nav(), n.upper())], w="hug", wrap=False),
            d="row", w="hug", pad=(8, 2, 8, 2), fill="00000000", bid=nav_ids[n])
        for n in ("Quickstart", "Features"))
    listeners += [(nav_ids["Features"], scroll_to(SEC_FEATURES)),
                  (nav_ids["Quickstart"], scroll_to(SEC_START)),
                  (nav_ids["Examples"], scroll_to(SEC_EXAMPLES))]
    nav_row = box("NavRow", brand + box("Links", links, d="rowReverse", w="fill", h="fixed", height=64,
                                        basis=0, wrap=True, gapx=22, gapy=40, pad=(15, 0, 0, 16), clip=True,
                                        align="topLeft"),
                  d="row", pct=100, maxw=MAX_W, h="fixed", height=64, align="spaceBetweenCenter")
    nav = box("Nav", box("NavBand", nav_row, w="fill", pad=(0, PAD_X, 0, PAD_X), align="topCenter")
              + box("NavRule", w="fill", h="fixed", height=1, fill=LINE_SOFT), w="fill")

    # -- hero: the stage (first, so it tops the column when narrow) and the copy
    player = (f'<NestedArtboardLayout artboardId="{first[1]}" instanceWidth="100" instanceWidthUnitsValue="percent" '
              f'instanceHeight="100" instanceHeightUnitsValue="percent" name="Player" id="100:7">'
              f'<DataBindContext sourcePathIds="100:50-100:51" propertyKey="197"/>'
              f'<NestedStateMachine animationId="{first[2]}" name="SM"/></NestedArtboardLayout>')
    stage = box("Stage", player, d="row", w="fill", aspect=1.6, clip=True, fill=STAGE_BG, stroke=LINE,
                bid="100:5")
    live = box("Live", box("LiveDot", w="fixed", h="fixed", width=6, height=6, fill=AMBER, radius=3)
               + text("LiveLabel", [(T_mono(WHITE, 11), "LIVE")], w="hug", wrap=False),
               d="row", w="hug", gap=8, align="centerLeft")
    cap_left = box("CaptionText",
                   box("CaptionTitleRow", live + text("DemoTitle", [(T_title(), first[0], "100:50-100:53")],
                                                      w="hug", wrap=False),
                       d="row", w="hug", gap=14, align="centerLeft")
                   + text("DemoBlurb", [(T_small(), first[3], "100:50-100:54")]),
                   w="fill", gap=6, minw=220, frac=1, basis=0)
    caption = box("Caption", cap_left + text("DemoHint", [(T_mono(FAINT, 11), hint(first[0], first[4]),
                                                            "100:50-100:55")], w="hug", wrap=False),
                  d="row", w="fill", wrap=True, gap=12, align="spaceBetweenStart")
    stage_col = box("StageCol", stage + caption, w="fill", frac=3, minw=340, gap=16, basis=0)

    cta_ex, cta_qs = ids(), ids()
    listeners += [(cta_ex, scroll_to(SEC_EXAMPLES)), (cta_qs, scroll_to(SEC_START))]
    copy = box("Copy",
               text("Eyebrow", [(T_eyebrow(), EYEBROW)])
               + text("Headline", [(T_h1(), HEADLINE)])
               + text("OneLiner", [(T_body(), ONE_LINER)])
               + box("Ctas", button("CtaExamples", "BROWSE THE EXAMPLES", True, cta_ex)
                     + button("CtaQuickstart", "QUICKSTART", False, cta_qs),
                     d="row", w="fill", wrap=True, gap=12, align="topLeft", style=' ')
               , w="fill", frac=2, minw=320, gap=22, basis=0)
    hero_row = box("HeroRow", stage_col + copy, d="rowReverse", w="fill", wrap=True, gapx=56, gapy=40,
                   align="centerLeft")
    hero = box("Hero", box("HeroInner", hero_row, pct=100, maxw=MAX_W),
               w="fill", pad=(56, PAD_X, 24, PAD_X), align="topCenter")

    # -- examples
    pid = Ids(102, 1)
    cards = []
    for k, (name, ab, smid, blurb, inter) in enumerate(EXAMPLES):
        slot, nid, iid = pid(), pid(), pid()
        inst = (f'<ViewModelInstance viewModelId="101:50" exports="true" name="{name} Card" id="{iid}">'
                f'<ViewModelInstanceString propertyValue={a(name)} viewModelPropertyId="101:51"/>'
                f'<ViewModelInstanceString propertyValue="{k + 1:02d}" viewModelPropertyId="101:52"/>'
                f'<ViewModelInstanceAssetImage propertyValue="103:{k + 1}" viewModelPropertyId="101:53"/>'
                f'<ViewModelInstanceNumber propertyValue="{k}" viewModelPropertyId="101:54"/>'
                f'<ViewModelInstanceNumber propertyValue="{DEFAULT}" viewModelPropertyId="101:55">'
                f'<DataBindContext sourcePathIds="100:50-100:52" propertyKey="575"/></ViewModelInstanceNumber>'
                f'<ViewModelInstanceBoolean propertyValue="false" viewModelPropertyId="101:56"/>'
                f'<ViewModelInstanceString propertyValue={a(blurb)} viewModelPropertyId="101:58"/>'
                f'</ViewModelInstance>')
        nested = (f'<NestedArtboardLayout artboardId="101:1" isStateful="true" instanceWidth="100" '
                  f'instanceWidthUnitsValue="percent" instanceHeightScaleType="hug" name="Card" id="{nid}">'
                  f'{inst}<NestedStateMachine animationId="101:2" name="SM"/></NestedArtboardLayout>')
        # The slot is the click target (a listener cannot target the nested
        # artboard itself); the card inside handles its own hover.
        cards.append(box(f"Card{name}", nested, w="fill", frac=1, minw=150, maxw=320, basis="18%", fill="00000000",
                         bid=slot))
        listeners.append((slot, [("Artboard", 823, "100:51", ab), ("Number", 636, "100:52", k),
                                 ("String", 635, "100:53", name), ("String", 635, "100:54", blurb),
                                 ("String", 635, "100:55", hint(name, inter))] + scroll_to(SEC_HERO)))
    # Cards take 18% of the row (five a row from tablet to desktop, 4 rows
    # of 5) with a 150pt floor (two a row on a phone), then grow to fill it.
    grid = box("Cards", "".join(cards), d="row", w="fill", wrap=True, gap=16, align="topCenter")
    examples = section("Examples", header("EXAMPLES", f"{len(EXAMPLES)} LIVE DEMOS",
                                          "Click a card to run it in the stage above: every example is a Rive "
                                          "artboard, and keeps its own pointer input.") + grid, top=72)

    # -- get started: steps and the quickstart code
    steps = []
    for num, title, body in STEPS:
        parts = (text("StepNum", [(T_mono(AMBER, 12), num)], w="hug", wrap=False)
                 + box("StepText", text("StepTitle", [(T_title(), title)]) + text("StepBody", [(T_small(), body)])
                       + (code_panel("InstallCode", "TERMINAL", INSTALL) if num == "01" else ""),
                       w="fill", gap=8, frac=1))
        steps.append(box(f"Step{num}", parts, d="row", w="fill", gap=18, pad=(20, 0, 20, 0)))
        steps.append(box("StepRule", w="fill", h="fixed", height=1, fill=LINE))
    steps_col = box("Steps", box("StepRuleTop", w="fill", h="fixed", height=1, fill=LINE) + "".join(steps),
                    w="fill", frac=2, minw=300, basis=0)
    code_col = box("CodeCol", code_panel("QuickstartCode", "demo.as", QUICKSTART), w="fill", frac=3, minw=340, basis=0)
    start = section("GetStarted", header("GET STARTED", "FROM ZERO TO A SCENE",
                                         "Write three.js, get a Rive file: the scene composites into your "
                                         "artboard like any other drawing.")
                    + box("StartRow", steps_col + code_col, d="row", w="fill", wrap=True, gap=40, align="topLeft"))

    # -- features
    fcards = "".join(
        box(f"Feature{k + 1}", text("FeatureTitle", [(T_title(), t)]) + text("FeatureBody", [(T_small(), b)]),
            w="fill", frac=1, minw=260, basis="30%", gap=10, pad=20, fill=CARD, stroke=LINE)
        for k, (t, b) in enumerate(FEATURES))
    features = section("Features", header("FEATURES", "THE THREE.JS YOU KNOW")
                       + box("FeatureGrid", fcards, d="row", w="fill", wrap=True, gap=16, align="topLeft"))

    # -- footer
    foot_row = box("FootRow",
                   box("FootBrand", text("FootName", [(tstyle(ORBITRON, 14, WHITE, 900, ls=0.5), "THREEAS")],
                                         w="hug", wrap=False)
                       + text("FootTag", [(T_small(DIM), "three.js for Rive")], w="hug", wrap=False),
                       d="row", w="hug", gap=12, align="centerLeft")
                   + text("FootLabels", [(T_mono(FAINT, 11), "ANIMASCRIPT · GPU CANVAS · WGSL")],
                          w="hug", wrap=False),
                   d="row", pct=100, maxw=MAX_W, wrap=True, gap=16, align="spaceBetweenCenter")
    footer = box("Footer", box("FootRule", w="fill", h="fixed", height=1, fill=LINE)
                 + box("FootBand", foot_row, w="fill", pad=(32, PAD_X, 48, PAD_X), align="topCenter"),
                 w="fill", pad=(96, 0, 0, 0))

    content = box("Content", nav + hero + examples + start + features + footer
                  + '<ScrollConstraint directionValue="vertical" physicsId="100:9" name="Scroll" id="100:8">'
                    '<DataBindContext sourcePathIds="100:50-100:57" propertyKey="763"/></ScrollConstraint>',
                  w="fill", h="hug", align="topCenter", bid="100:6")
    viewport = box("Viewport", content, w="fill", h="fill", clip=True, bid="100:10")

    # -- the state machine: clicks write the view model
    def write(kind, key, prop, value):
        return (f'<ListenerViewModelChange><BindableProperty{kind} propertyValue={a(value)}>'
                f'<DataBindContext sourcePathIds="100:50-{prop}" propertyKey="{key}" direction="true"/>'
                f'</BindableProperty{kind}></ListenerViewModelChange>')
    sm = ['<StateMachine name="State Machine 1" id="100:2">',
          '<StateMachineLayer name="Layer 1" id="100:3"><EntryState/></StateMachineLayer>']
    for k, (target, actions) in enumerate(listeners):
        sm.append(f'<StateMachineListenerSingle targetId="{target}" listenerTypeValue="click" name="Click{k + 1}">'
                  + "".join(write(*act) for act in actions) + '</StateMachineListenerSingle>')
    sm.append('</StateMachine>')

    return (f'<Artboard defaultStateMachineId="100:2" viewModelId="100:50" viewModelInstanceId="100:56" '
            f'clip="true" x="0" y="-2800" width="1440" height="900" styleId="100:4" name="Gallery" id="100:1">\n'
            f'        <LayoutComponentStyle flexDirectionValue="column" name="Artboard Style" id="100:4"/>\n'
            f'        <ElasticScrollPhysics friction="2.5" speedMultiplier="1.2" elasticFactor="0.7" '
            f'name="Physics" id="100:9"/>\n'
            f'        {"".join(PHYSICS)}\n'
            f'        {viewport}\n'
            f'        {paint("Fill", BG)}\n        ' + "\n        ".join(sm) + '\n    </Artboard>')


# ---------------------------------------------------------------- the card

def key(anim_id, name, keys):
    """A one-frame animation holding values: keys is [(object, property, value)]."""
    objs = "".join(
        f'<KeyedObject objectId="{o}"><KeyedProperty property="{p}">'
        + (f'<KeyFrameColor value="{v}" interpolationType="hold"/>' if p == "colorValue"
           else f'<KeyFrameDouble value="{v}" interpolationType="hold"/>')
        + '</KeyedProperty></KeyedObject>'
        for o, p, v in keys)
    return f'<LinearAnimation duration="1" name="{name}" id="{anim_id}">{objs}</LinearAnimation>'


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
    """rive.app's card: a faint fill and a hairline that brightens on hover;
    the playing card gets an amber ring and a PLAYING tag."""
    first = EXAMPLES[0]
    thumb = (f'<Image assetId="103:1" fit="cover" name="Thumb" id="101:13">'
             f'<LayoutParticipant layoutWidthScaleType="fill" layoutHeightScaleType="fill" name="Layout"/>'
             f'<DataBindContext sourcePathIds="101:50-101:53" propertyKey="206"/></Image>')
    number = box("Number", text("NumberText", [(T_mono(WHITE, 11), "01", "101:50-101:52")], w="hug", wrap=False),
                 d="row", w="hug", pad=(3, 6, 3, 6), fill="B3000000", absolute={"left": 0, "top": 0})
    playing = box("Playing", text("PlayingText", [(T_mono(BG, 11), "PLAYING")], w="hug", wrap=False),
                  d="row", w="hug", pad=(3, 6, 3, 6), fill=AMBER, absolute={"right": 0, "top": 0},
                  opacity=0, bid="101:11")
    # Overlays first: the first-declared drawable paints on top.
    thumb_box = box("ThumbBox", number + playing + thumb, d="row", w="fill", aspect=1.7778, clip=True,
                    fill=STAGE_BG)
    words = (text("CardName", [(T_title(), first[0], "101:50-101:51")])
             + text("CardBlurb", [(tstyle(INTER, 13, DIM, 400, lh=19), first[3], "101:50-101:58")]))
    frame = (f'<LayoutComponent clip="false" width="0" height="0" styleId="101:21" name="Frame" id="101:10">'
             f'<LayoutComponentStyle flexDirectionValue="column" layoutWidthScaleType="fill" '
             f'layoutHeightScaleType="hug" gapVertical="12" paddingTop="12" paddingRight="12" paddingBottom="16" '
             f'paddingLeft="12" name="Frame Style" id="101:21"/>'
             f'{thumb_box}{box("Words", words, w="fill", gap=6, pad=(0, 4, 0, 4))}'
             f'{paint("Fill", CARD)}{solid_id("Stroke", LINE, "101:12", " thickness=\"1\"")}'
             # The active ring: a second stroke, clear until the card plays.
             f'{solid_id("Stroke", "00FFA41C", "101:14", " thickness=\"1.5\"")}</LayoutComponent>')
    return f'''<Artboard isComponent="true" defaultStateMachineId="101:2" viewModelId="101:50" viewModelInstanceId="101:57" clip="false" x="1600" y="-2800" width="240" height="250" styleId="101:3" name="ExampleCard" id="101:1">
        <LayoutComponentStyle flexDirectionValue="column" layoutWidthScaleType="fixed" layoutHeightScaleType="hug" name="Card Style" id="101:3"/>
        {frame}
        <StateMachine name="State Machine 1" id="101:2">
            <StateMachineLayer name="Hover" id="101:20">
                <EntryState x="0" y="0"><StateTransition stateToId="101:22"/></EntryState>
                <AnimationState x="200" y="0" animationId="101:30" id="101:22">
                    <StateTransition stateToId="101:23" duration="150">{hover_is("true")}</StateTransition>
                </AnimationState>
                <AnimationState x="400" y="0" animationId="101:31" id="101:23">
                    <StateTransition stateToId="101:22" duration="200">{hover_is("false")}</StateTransition>
                </AnimationState>
            </StateMachineLayer>
            <StateMachineLayer name="Active" id="101:24">
                <EntryState x="0" y="0"><StateTransition stateToId="101:25"/></EntryState>
                <AnimationState x="200" y="0" animationId="101:32" id="101:25">
                    <StateTransition stateToId="101:26"><TransitionViewModelCondition opValue="equal">{number_cmp("101:55")}{number_cmp("101:54")}</TransitionViewModelCondition></StateTransition>
                </AnimationState>
                <AnimationState x="400" y="0" animationId="101:33" id="101:26">
                    <StateTransition stateToId="101:25"><TransitionViewModelCondition opValue="notEqual">{number_cmp("101:55")}{number_cmp("101:54")}</TransitionViewModelCondition></StateTransition>
                </AnimationState>
            </StateMachineLayer>
            <StateMachineListenerSingle targetId="101:10" listenerTypeValue="enter" name="In">{set_hover("true")}</StateMachineListenerSingle>
            <StateMachineListenerSingle targetId="101:10" listenerTypeValue="exit" name="Out">{set_hover("false")}</StateMachineListenerSingle>
        </StateMachine>
        {key("101:30", "Rest", [("101:12", "colorValue", LINE)])}
        {key("101:31", "Hover", [("101:12", "colorValue", LINE_HOVER)])}
        {key("101:32", "Off", [("101:14", "colorValue", "00FFA41C"), ("101:11", "opacity", 0)])}
        {key("101:33", "On", [("101:14", "colorValue", AMBER), ("101:11", "opacity", 1)])}
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
        <ViewModelPropertyNumber name="section" id="100:57"/>
        <ViewModelInstance exports="true" name="Default" id="100:56">
            <ViewModelInstanceArtboard propertyValue="{first[1]}" viewModelPropertyId="100:51"/>
            <ViewModelInstanceNumber propertyValue="{DEFAULT}" viewModelPropertyId="100:52"/>
            <ViewModelInstanceString propertyValue={a(first[0])} viewModelPropertyId="100:53"/>
            <ViewModelInstanceString propertyValue={a(first[3])} viewModelPropertyId="100:54"/>
            <ViewModelInstanceString propertyValue={a(hint(first[0], first[4]))} viewModelPropertyId="100:55"/>
            <ViewModelInstanceNumber propertyValue="0" viewModelPropertyId="100:57"/>
        </ViewModelInstance>
    </ViewModel>

    <ViewModel defaultInstanceId="101:57" name="ExampleCard" id="101:50">
        <ViewModelPropertyString componentProps="1" name="name" id="101:51"/>
        <ViewModelPropertyString componentProps="1" name="number" id="101:52"/>
        <ViewModelPropertyAssetImage componentProps="1" name="thumb" id="101:53"/>
        <ViewModelPropertyNumber componentProps="1" name="index" id="101:54"/>
        <ViewModelPropertyNumber componentProps="1" name="selected" id="101:55"/>
        <ViewModelPropertyBoolean name="hover" id="101:56"/>
        <ViewModelPropertyString componentProps="1" name="blurb" id="101:58"/>
        <ViewModelInstance exports="true" name="Default" id="101:57">
            <ViewModelInstanceString propertyValue={a(EXAMPLES[0][0])} viewModelPropertyId="101:51"/>
            <ViewModelInstanceString propertyValue="01" viewModelPropertyId="101:52"/>
            <ViewModelInstanceAssetImage propertyValue="103:1" viewModelPropertyId="101:53"/>
            <ViewModelInstanceNumber propertyValue="0" viewModelPropertyId="101:54"/>
            <ViewModelInstanceNumber propertyValue="-1" viewModelPropertyId="101:55"/>
            <ViewModelInstanceBoolean propertyValue="false" viewModelPropertyId="101:56"/>
            <ViewModelInstanceString propertyValue={a(EXAMPLES[0][3])} viewModelPropertyId="101:58"/>
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

         Gallery: the ThreeAS landing page (rive . --artboard=Gallery), built
         from Rive layouts so it reflows at any width and scrolls. The stage's
         NestedArtboardLayout has its artboardId bound to the Gallery view
         model's `demo` artboard property; clicking an ExampleCard writes that
         property, so the example artboard from examples/examples.rml runs
         live and takes pointer input in place. -->
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
        subprocess.run(["sips", "-z", "270", "480", crop, "--out", os.path.join(HERE, "thumbs", name + ".png")],
                       check=True, stdout=subprocess.DEVNULL)
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
