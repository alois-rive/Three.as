"""Writes the Water example's artboards into examples/water/water.rml
(between the WATER markers): a scene picker and a panel of settings, a Rive
layout of buttons over the 3D scene (examples/water/water.as).

    python3 tools/make_water_ui.py

Water is what the gallery nests. It holds WaterStage as a *stateful* nested
artboard, so the stage keeps its own WaterControls view model instance
wherever Water is placed (as Effects does). The stage is a ScriptedLayout
under a panel and a caption. Clicks write view model properties
(ListenerViewModelChange); the script reads them each frame:

- four tabs write their index to `scene`; a tab's amber dot shows when
  `scene` is its index (opacity max(0, 1 - (scene - k)^2));
- six setting rows, each a label (`label<r>`), a value (`value<r>`) and two
  buttons that write a command to `command`: 2r + 1 for "-", 2r + 2 for "+";
- the settings header's button (its text `toggle`) writes command 99, which
  shows or hides the rows (`collapsed`).

The script applies a command at its next frame and writes `command` back to
0 (so the same button works twice in a row), then the labels and values. It
writes `rows` (rows from there on are out of the layout: their style's
displayValue is min(1, max(0, r + 1 - rows)), 1 being none), `collapsed`
(the rows' box is out of the layout when 1), `compact` (1 on a short stage:
the caption is out of the layout, and the panel starts collapsed),
`tabsHidden` (1 while a compact stage shows the settings: the tabs are out
of the layout, so the rows fit), the header's title (`heading`) and the
caption, `info`. The panel writes its laid-out size back to `panelWidth` and
`panelHeight` (computedWidth / computedHeight, direction="true"): the script
does not orbit for presses on it, and claims them so a drag there does not
scroll the page.

Ids: 0:45xx Water, 0:46xx WaterStage, 0:47xx the view model, 0:160100 and
up generated. Text uses the gallery's IoskeleyMono and Inter font assets
(106:3, 106:2), compiled into the same document.
"""
import os
from xml.sax.saxutils import quoteattr

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
RML = os.path.join(ROOT, "examples", "water", "water.rml")
BEGIN = "    <!-- BEGIN Water (tools/make_water_ui.py) -->"
END = "    <!-- END Water -->"

# The scenes, in the order examples/water/water.as numbers them.
SCENES = ["Ocean", "Pool", "Flow map", "Mirrors"]
ROWS = 6
TOGGLE_COMMAND = 99  # water.as's TOGGLE_COMMAND

MONO, INTER = "106:3", "106:2"
AMBER, WHITE, DIM, PANEL, BUTTON = "FFFFA41C", "FFFFFFFF", "B3FFFFFF", "B30B0D12", "1FFFFFFF"
K_OPACITY, K_TEXT, K_NUMBER_WRITE, K_DISPLAY = 18, 268, 636, 596
K_COMPUTED_WIDTH, K_COMPUTED_HEIGHT = 810, 811

VM, VM_INST = "0:4700", "0:4705"
P_SCENE, P_COMMAND, P_ROWS, P_INFO = "0:4701", "0:4702", "0:4703", "0:4704"
P_COLLAPSED, P_COMPACT, P_TOGGLE, P_PANEL_W, P_PANEL_H = "0:4706", "0:4707", "0:4708", "0:4730", "0:4731"
P_TABS_HIDDEN, P_HEADING = "0:4732", "0:4733"
P_LABEL = [f"0:{4710 + r}" for r in range(ROWS)]
P_VALUE = [f"0:{4720 + r}" for r in range(ROWS)]
NUMBERS = [("scene", P_SCENE), ("command", P_COMMAND), ("rows", P_ROWS), ("collapsed", P_COLLAPSED),
           ("compact", P_COMPACT), ("tabsHidden", P_TABS_HIDDEN), ("panelWidth", P_PANEL_W),
           ("panelHeight", P_PANEL_H)]
STRINGS = ([("info", P_INFO), ("toggle", P_TOGGLE), ("heading", P_HEADING)] + [(f"label{r}", P_LABEL[r]) for r in range(ROWS)]
           + [(f"value{r}", P_VALUE[r]) for r in range(ROWS)])

# Panel geometry: small enough for a phone-width gallery stage.
PANEL_W, PAD = 224, 8
INNER = PANEL_W - 2 * PAD
TAB_W, TAB_H = (INNER - 4) // 2, 20
LABEL_W, VALUE_W, STEP_W, ROW_H, ROW_GAP = 84, 68, 22, 20, 3

_next = [160100]


def nid():
    _next[0] += 1
    return f"0:{_next[0]}"


def a(v):
    return quoteattr(str(v))


def paint(kind, color, extra=""):
    return f'<{kind}{extra} name="{kind}"><SolidColor colorValue="{color}" name="Color"/></{kind}>'


def bind(prop, key, converter=None, out=False):
    c = f' converterId="{converter}"' if converter else ""
    d = ' direction="true"' if out else ""
    return f'<DataBindContext sourcePathIds="{VM}-{prop}" propertyKey="{key}"{c}{d}/>'


def style(name, sid, *, d="column", w="fill", h="hug", gap=0, pad=0, radius=0, absolute=None, align=None,
          wrap=False, style_binds=""):
    t, r, b, l = (pad, pad, pad, pad) if isinstance(pad, (int, float)) else pad
    st = [f'flexDirectionValue="{d}"', f'layoutWidthScaleType="{w}"', f'layoutHeightScaleType="{h}"']
    if gap:
        st.append(f'gapVertical="{gap}" gapHorizontal="{gap}"')
    for k, v in (("Top", t), ("Right", r), ("Bottom", b), ("Left", l)):
        if v:
            st.append(f'padding{k}="{v}"')
    if radius:
        st.append(f'linkCornerRadius="true" cornerRadiusTL="{radius}" cornerRadiusTR="{radius}" '
                  f'cornerRadiusBL="{radius}" cornerRadiusBR="{radius}"')
    if align:
        st.append(f'layoutAlignmentType="{align}"')
    if wrap:
        st.append('flexWrapValue="wrap"')
    if absolute:
        st.append('positionTypeValue="absolute"')
        for k, v in absolute.items():
            st.append(f'position{k.capitalize()}="{v}" position{k.capitalize()}UnitsValue="points"')
    if style_binds:
        return f'<LayoutComponentStyle {" ".join(st)} name={a(name + " Style")} id="{sid}">{style_binds}' \
               f'</LayoutComponentStyle>'
    return f'<LayoutComponentStyle {" ".join(st)} name={a(name + " Style")} id="{sid}"/>'


def box(name, children="", *, bid=None, fill=None, width=0, height=0, binds="", **kw):
    bid = bid or nid()
    sid = nid()
    return (f'<LayoutComponent clip="false" width="{width}" height="{height}" styleId="{sid}" name={a(name)} '
            f'id="{bid}">{style(name, sid, **kw)}{binds}{children}{paint("Fill", fill) if fill else ""}'
            f'</LayoutComponent>')


def text(name, s, font, size, color, prop=None, width=None):
    sid = nid()
    fam = "IoskeleyMono" if font == MONO else "Inter"
    b = bind(prop, K_TEXT) if prop else ""
    if width:
        # A hug participant leaves the text's own sizing in charge: wrapped
        # at `width`, as tall as its lines.
        attrs = f' wrapValue="wrap" sizingValue="autoHeight" width="{width}"'
    else:
        attrs = ' wrapValue="noWrap" sizingValue="autoWidth"'
    layout = '<LayoutParticipant layoutWidthScaleType="hug" layoutHeightScaleType="hug" name="Layout"/>'
    return (f'<Text{attrs} name={a(name)} id="{nid()}">{layout}'
            f'<TextStylePaint fontSize="{size}" fontAssetId="{font}" familyName="{fam}" name="Style" id="{sid}">'
            f'{paint("Fill", color)}</TextStylePaint>'
            f'<TextValueRun styleId="{sid}" text={a(s)} name="Run">{b}</TextValueRun></Text>')


def formula(name, tokens):
    cid = nid()
    return cid, f'<DataConverterFormula name={a(name)} id="{cid}">{tokens}</DataConverterFormula>'


def is_k(k):
    """max(0, 1 - pow(input - k, 2)): 1 when scene == k, else 0."""
    return formula(f"IsScene{k}",
                   '<FormulaTokenFunction functionType="1"/><FormulaTokenValue operationValue="0"/>'
                   '<FormulaTokenArgumentSeparator/>'
                   '<FormulaTokenValue operationValue="1"/><FormulaTokenOperation operationType="1"/>'
                   '<FormulaTokenFunction functionType="6"/><FormulaTokenInput/>'
                   f'<FormulaTokenOperation operationType="1"/><FormulaTokenValue operationValue="{k}"/>'
                   '<FormulaTokenArgumentSeparator/><FormulaTokenValue operationValue="2"/>'
                   '<FormulaTokenParenthesisClose/><FormulaTokenParenthesisClose/>')


def hidden_from(r):
    """min(1, max(0, r + 1 - input)): 1 (display none) when rows <= r."""
    return formula(f"RowHidden{r}",
                   '<FormulaTokenFunction functionType="0"/><FormulaTokenValue operationValue="1"/>'
                   '<FormulaTokenArgumentSeparator/>'
                   '<FormulaTokenFunction functionType="1"/><FormulaTokenValue operationValue="0"/>'
                   '<FormulaTokenArgumentSeparator/>'
                   f'<FormulaTokenValue operationValue="{r + 1}"/><FormulaTokenOperation operationType="1"/>'
                   '<FormulaTokenInput/>'
                   '<FormulaTokenParenthesisClose/><FormulaTokenParenthesisClose/>')


def write_number(name, target, prop, value):
    return (f'<StateMachineListenerSingle targetId="{target}" listenerTypeValue="click" name={a(name)}>'
            f'<ListenerViewModelChange><BindablePropertyNumber propertyValue="{value}">'
            f'{bind(prop, K_NUMBER_WRITE, out=True)}'
            f'</BindablePropertyNumber></ListenerViewModelChange></StateMachineListenerSingle>')


def main():
    converters, listeners = [], []
    tabs = []
    for k, label in enumerate(SCENES):
        cid, cxml = is_k(k)
        converters.append(cxml)
        dot = box(f"TabDot{k}", fill=AMBER, w="fixed", h="fixed", width=6, height=6, radius=3,
                  binds=bind(P_SCENE, K_OPACITY, cid))
        bid = nid()
        tabs.append(box(f"Tab{k}", dot + text(f"TabLabel{k}", label.upper(), MONO, 10, WHITE),
                        bid=bid, d="row", w="fixed", h="fixed", width=TAB_W, height=TAB_H, gap=6, pad=(0, 8, 0, 8),
                        radius=3, align="centerLeft", fill=BUTTON))
        listeners.append(write_number(f"Scene{k}", bid, P_SCENE, k))
    rows = []
    for r in range(ROWS):
        cid, cxml = hidden_from(r)
        converters.append(cxml)
        steps = []
        for sign, glyph in ((1, "-"), (2, "+")):
            bid = nid()
            steps.append(box(f"Step{r}{glyph}", text(f"StepLabel{r}{glyph}", glyph, MONO, 12, WHITE),
                             bid=bid, d="row", w="fixed", h="fixed", width=STEP_W, height=ROW_H, radius=3,
                             align="center", fill=BUTTON))
            listeners.append(write_number(f"Row{r}{'Less' if sign == 1 else 'More'}", bid, P_COMMAND,
                                          2 * r + sign))
        label = box(f"LabelBox{r}", text(f"Label{r}", "", MONO, 10, DIM, prop=P_LABEL[r]), w="fixed",
                    width=LABEL_W, d="row", align="centerLeft")
        value = box(f"ValueBox{r}", text(f"Value{r}", "", MONO, 10, AMBER, prop=P_VALUE[r]), w="fixed",
                    width=VALUE_W, d="row", align="centerLeft")
        rows.append(box(f"Row{r}", label + value + "".join(steps), d="row", w="fixed", h="fixed", width=INNER,
                        height=ROW_H, gap=4, align="centerLeft", style_binds=bind(P_ROWS, K_DISPLAY, cid)))
    tab_grid = box("Tabs", "".join(tabs), d="row", wrap=True, w="fixed", width=INNER, gap=4,
                   style_binds=bind(P_TABS_HIDDEN, K_DISPLAY))
    toggle_id = nid()
    toggle = box("Toggle", text("ToggleLabel", "HIDE", MONO, 10, WHITE, prop=P_TOGGLE), bid=toggle_id, d="row",
                 w="hug", h="fixed", height=18, pad=(0, 8, 0, 8), radius=3, align="center", fill=BUTTON)
    listeners.append(write_number("Toggle", toggle_id, P_COMMAND, TOGGLE_COMMAND))
    header = box("SettingsHeader", text("SettingsTitle", "SETTINGS", MONO, 10, DIM, prop=P_HEADING) + toggle, d="row",
                 w="fixed", width=INNER, pad=(0, 0, 0, 2), align="spaceBetweenCenter")
    row_box = box("Rows", "".join(rows), w="fixed", width=INNER, gap=ROW_GAP,
                  style_binds=bind(P_COLLAPSED, K_DISPLAY))
    panel = box("Panel", tab_grid + header + row_box, w="fixed", h="hug", width=PANEL_W, gap=6, pad=PAD, radius=6,
                fill=PANEL, absolute={"left": 12, "top": 12},
                binds=bind(P_PANEL_W, K_COMPUTED_WIDTH, out=True) + bind(P_PANEL_H, K_COMPUTED_HEIGHT, out=True))
    caption = box("Caption", text("Info", "", INTER, 11, WHITE, prop=P_INFO, width=300), w="hug", h="hug",
                  pad=(6, 10, 6, 10), radius=4, fill=PANEL, absolute={"left": 12, "bottom": 12},
                  style_binds=bind(P_COMPACT, K_DISPLAY))
    scene = '<ScriptedLayout scriptAssetId="0:4690" name="Scene" id="0:4604"/>'
    # The first declared paints on top: the panel and caption, then the scene.
    root = box("Root", panel + caption + scene, bid="0:4602", w="fill", h="fill")
    sm = ('<StateMachine name="State Machine 1" id="0:4607"><StateMachineLayer name="Layer 1" id="0:4608">'
          '<AnyState x="0" y="-120" id="0:4609"/><ExitState x="120" y="-120" id="0:4610"/>'
          '<EntryState id="0:4611"/></StateMachineLayer>' + "".join(listeners) + '</StateMachine>')
    stage = (f'    <Artboard isComponent="true" defaultStateMachineId="0:4607" viewModelId="{VM}" '
             f'viewModelInstanceId="{VM_INST}" clip="true" x="900" y="11200" width="800" height="600" '
             f'styleId="0:4601" name="WaterStage" id="0:4600">\n'
             f'        <LayoutComponentStyle name="Artboard Style" id="0:4601"/>\n'
             f'        {root}\n        {sm}\n    </Artboard>')

    def instance_values():
        v = [f'<ViewModelInstanceNumber propertyValue="0" viewModelPropertyId="{p}"/>' for _, p in NUMBERS]
        v += [f'<ViewModelInstanceString propertyValue="" viewModelPropertyId="{p}"/>' for _, p in STRINGS]
        return "".join(v)

    water = (
        '    <Artboard isComponent="true" defaultStateMachineId="0:4507" clip="true" x="0" y="11200" '
        'width="800" height="600" styleId="0:4501" name="Water" id="0:4500">\n'
        '        <LayoutComponentStyle name="Artboard Style" id="0:4501"/>\n'
        '        <LayoutComponent width="800" height="600" styleId="0:4503" name="Root" id="0:4502">'
        '<LayoutComponentStyle layoutWidthScaleType="1" layoutHeightScaleType="1" widthUnitsValue="3" '
        'heightUnitsValue="3" name="Root Style" id="0:4503"/>'
        '<NestedArtboardLayout artboardId="0:4600" isStateful="true" instanceWidth="100" '
        'instanceWidthUnitsValue="percent" instanceHeight="100" instanceHeightUnitsValue="percent" '
        'name="Stage" id="0:4504">'
        f'<ViewModelInstance viewModelId="{VM}" exports="true" name="Stage Instance" id="0:4505">'
        f'{instance_values()}</ViewModelInstance>'
        '<NestedStateMachine animationId="0:4607" name="SM"/></NestedArtboardLayout></LayoutComponent>\n'
        '        <StateMachine name="State Machine 1" id="0:4507"><StateMachineLayer name="Layer 1" id="0:4508">'
        '<AnyState x="0" y="-120" id="0:4509"/><ExitState x="120" y="-120" id="0:4510"/>'
        '<EntryState id="0:4511"/></StateMachineLayer></StateMachine>\n    </Artboard>')
    props = [f'        <ViewModelPropertyNumber name="{n}" id="{p}"/>' for n, p in NUMBERS]
    props += [f'        <ViewModelPropertyString name="{n}" id="{p}"/>' for n, p in STRINGS]
    vm = (f'    <ViewModel defaultInstanceId="{VM_INST}" name="WaterControls" id="{VM}">\n'
          + "\n".join(props) + "\n"
          f'        <ViewModelInstance exports="true" name="Default" id="{VM_INST}">{instance_values()}'
          '</ViewModelInstance>\n    </ViewModel>')
    block = "\n".join([
        BEGIN,
        "    <!-- Water: four water setups, a Rive scene picker and settings panel over them",
        "         (examples/water/water.as). Generated: edit tools/make_water_ui.py, not this block. -->",
        water, stage, vm, "    " + "\n    ".join(converters),
        '    <ComponentAsset artboardId="0:4600" name="WaterStage" id="0:4699"/>', END])
    src = open(RML).read()
    if BEGIN in src:
        start = src.index(BEGIN)
        end = src.index(END) + len(END)
        src = src[:start] + block + src[end:]
    else:
        i = src.index("\n\n    <ScriptAsset ")
        src = src[:i] + "\n\n" + block + src[i:]
    open(RML, "w").write(src)
    print("wrote the Water block of examples/water/water.rml (%d scenes, %d rows)" % (len(SCENES), ROWS))


if __name__ == "__main__":
    main()
