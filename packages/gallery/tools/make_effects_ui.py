"""Writes the Effects example's artboards into examples/effects/effects.rml
(between the EFFECTS markers): the pass picker, a Rive layout of buttons over
the 3D scene (examples/effects/effects.as).

    python3 tools/make_effects_ui.py

Effects is what the gallery nests. It holds EffectsStage as a *stateful*
nested artboard, so the stage keeps its own EffectsPicker view model
instance wherever Effects is placed (a plain nested artboard reads its
parent's data context, and the gallery's is the Gallery view model). The
stage is a ScriptedLayout under a panel of buttons: a click writes the
button's index to the view model's `pass` (a ListenerViewModelChange); each
button's amber dot shows when `pass` is its index (opacity bound through a
formula, max(0, 1 - (pass - k)^2)); the script reads `pass` and writes
`info`, the caption under the panel.

Ids: 0:31xx Effects, 0:32xx EffectsStage, 0:33xx the view model, 0:34xx and
up generated. Text uses the gallery's IoskeleyMono and Inter font assets
(106:3, 106:2), compiled into the same document.
"""
import os
from xml.sax.saxutils import quoteattr

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
RML = os.path.join(ROOT, "examples", "effects", "effects.rml")
BEGIN = "    <!-- BEGIN Effects (tools/make_effects_ui.py) -->"
END = "    <!-- END Effects -->"

# The passes, in the order examples/effects/effects.as numbers them.
PASSES = ["None", "SMAA", "SSAA", "TAA", "SSAO", "SAO", "GTAO", "Outline", "Bokeh", "Afterimage", "Film",
          "Glitch", "Dot screen", "Halftone", "LUT", "Pixelated", "Mask", "Selective bloom"]

MONO, INTER = "106:3", "106:2"
AMBER, WHITE, DIM = "FFFFA41C", "FFFFFFFF", "B3FFFFFF"
VM, P_PASS, P_INFO, VM_INST = "0:3300", "0:3301", "0:3302", "0:3303"
K_OPACITY, K_TEXT, K_NUMBER_WRITE = 18, 268, 636

_next = [3400]


def nid():
    _next[0] += 1
    return f"0:{_next[0]}"


def a(v):
    return quoteattr(str(v))


def paint(kind, color, extra=""):
    return f'<{kind}{extra} name="{kind}"><SolidColor colorValue="{color}" name="Color"/></{kind}>'


def style(name, sid, *, d="column", w="fill", h="hug", gap=0, pad=0, radius=0, absolute=None, align=None,
          width_pct=None, height_pct=None, wrap=False):
    t, r, b, l = (pad, pad, pad, pad) if isinstance(pad, (int, float)) else pad
    st = [f'flexDirectionValue="{d}"', f'layoutWidthScaleType="{w}"', f'layoutHeightScaleType="{h}"']
    if width_pct is not None:
        st[1] = 'layoutWidthScaleType="fixed" widthUnitsValue="percent"'
    if height_pct is not None:
        st[2] = 'layoutHeightScaleType="fixed" heightUnitsValue="percent"'
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
    return f'<LayoutComponentStyle {" ".join(st)} name={a(name + " Style")} id="{sid}"/>'


def box(name, children="", *, bid=None, fill=None, width=0, height=0, extra="", binds="", **kw):
    bid = bid or nid()
    sid = nid()
    w = kw.get("width_pct", width)
    h = kw.get("height_pct", height)
    return (f'<LayoutComponent clip="false" width="{w}" height="{h}"{extra} styleId="{sid}" name={a(name)} '
            f'id="{bid}">{style(name, sid, **kw)}{binds}{children}{paint("Fill", fill) if fill else ""}'
            f'</LayoutComponent>')


def text(name, s, font, size, color, bind=None, width=None):
    sid = nid()
    fam = "IoskeleyMono" if font == MONO else "Inter"
    b = f'<DataBindContext sourcePathIds="{VM}-{bind}" propertyKey="{K_TEXT}"/>' if bind else ""
    if width:
        attrs = f' wrapValue="wrap" sizingValue="fixed" width="{width}"'
        layout = '<LayoutParticipant layoutWidthScaleType="fixed" layoutHeightScaleType="hug" name="Layout"/>'
    else:
        attrs = ' wrapValue="noWrap" sizingValue="autoWidth"'
        layout = '<LayoutParticipant layoutWidthScaleType="hug" layoutHeightScaleType="hug" name="Layout"/>'
    return (f'<Text{attrs} name={a(name)} id="{nid()}">{layout}'
            f'<TextStylePaint fontSize="{size}" fontAssetId="{font}" familyName="{fam}" name="Style" id="{sid}">'
            f'{paint("Fill", color)}</TextStylePaint>'
            f'<TextValueRun styleId="{sid}" text={a(s)} name="Run">{b}</TextValueRun></Text>')


def converter(k):
    """max(0, 1 - pow(input - k, 2)): 1 when pass == k, else 0."""
    cid = nid()
    xml = (f'<DataConverterFormula name="Is{k}" id="{cid}">'
           '<FormulaTokenFunction functionType="1"/><FormulaTokenValue operationValue="0"/>'
           '<FormulaTokenArgumentSeparator/>'
           '<FormulaTokenValue operationValue="1"/><FormulaTokenOperation operationType="1"/>'
           '<FormulaTokenFunction functionType="6"/><FormulaTokenInput/><FormulaTokenOperation operationType="1"/>'
           f'<FormulaTokenValue operationValue="{k}"/><FormulaTokenArgumentSeparator/>'
           '<FormulaTokenValue operationValue="2"/><FormulaTokenParenthesisClose/>'
           '<FormulaTokenParenthesisClose/></DataConverterFormula>')
    return cid, xml


def main():
    converters, buttons, listeners = [], [], []
    for k, label in enumerate(PASSES):
        cid, cxml = converter(k)
        converters.append(cxml)
        dot = box(f"Dot{k}", fill=AMBER, w="fixed", h="fixed", width=6, height=6, radius=3,
                  binds=f'<DataBindContext sourcePathIds="{VM}-{P_PASS}" propertyKey="{K_OPACITY}" '
                        f'converterId="{cid}"/>')
        bid = nid()
        buttons.append(box(f"Button{k}", dot + text(f"Label{k}", label.upper(), MONO, 10, WHITE),
                           bid=bid, d="row", w="fixed", width=116, gap=6, pad=(4, 8, 4, 8), radius=3,
                           align="centerLeft", fill="14FFFFFF"))
        listeners.append(
            f'<StateMachineListenerSingle targetId="{bid}" listenerTypeValue="click" name="Pick{k}">'
            f'<ListenerViewModelChange><BindablePropertyNumber propertyValue="{k}">'
            f'<DataBindContext sourcePathIds="{VM}-{P_PASS}" propertyKey="{K_NUMBER_WRITE}" direction="true"/>'
            f'</BindablePropertyNumber></ListenerViewModelChange></StateMachineListenerSingle>')
    # Two columns, so the panel fits the gallery's stage (about 420 high).
    title = box("TitleRow", text("Title", "PASS", MONO, 10, DIM), w="fixed", width=235, pad=(0, 0, 2, 2))
    panel = box("Panel", title + "".join(buttons), d="row", wrap=True, w="fixed", h="hug", width=255, gap=3,
                pad=10, radius=6,
                fill="B30B0D12", absolute={"left": 12, "top": 12})
    caption = box("Caption", text("Info", "", INTER, 12, WHITE, bind=P_INFO), w="hug", h="hug",
                  pad=(6, 10, 6, 10), radius=4, fill="B30B0D12", absolute={"left": 12, "bottom": 12})
    scene = '<ScriptedLayout scriptAssetId="0:3290" name="Scene" id="0:3204"/>'
    # The first declared paints on top: the panel and caption, then the scene.
    root = box("Root", panel + caption + scene, bid="0:3202", w="fill", h="fill")
    sm = ('<StateMachine name="State Machine 1" id="0:3207"><StateMachineLayer name="Layer 1" id="0:3208">'
          '<AnyState x="0" y="-120" id="0:3209"/><ExitState x="120" y="-120" id="0:3210"/>'
          '<EntryState id="0:3211"/></StateMachineLayer>' + "".join(listeners) + '</StateMachine>')
    stage = (f'    <Artboard isComponent="true" defaultStateMachineId="0:3207" viewModelId="{VM}" '
             f'viewModelInstanceId="{VM_INST}" clip="true" x="1800" y="5600" width="800" height="600" '
             f'styleId="0:3201" name="EffectsStage" id="0:3200">\n'
             f'        <LayoutComponentStyle name="Artboard Style" id="0:3201"/>\n'
             f'        {root}\n        {sm}\n    </Artboard>')
    effects = (
        '    <Artboard isComponent="true" defaultStateMachineId="0:3107" clip="true" x="1800" y="6300" '
        'width="800" height="600" styleId="0:3101" name="Effects" id="0:3100">\n'
        '        <LayoutComponentStyle name="Artboard Style" id="0:3101"/>\n'
        '        <LayoutComponent width="800" height="600" styleId="0:3103" name="Root" id="0:3102">'
        '<LayoutComponentStyle layoutWidthScaleType="1" layoutHeightScaleType="1" widthUnitsValue="3" '
        'heightUnitsValue="3" name="Root Style" id="0:3103"/>'
        '<NestedArtboardLayout artboardId="0:3200" isStateful="true" instanceWidth="100" '
        'instanceWidthUnitsValue="percent" instanceHeight="100" instanceHeightUnitsValue="percent" '
        'name="Stage" id="0:3104">'
        f'<ViewModelInstance viewModelId="{VM}" exports="true" name="Stage Instance" id="0:3105">'
        f'<ViewModelInstanceNumber propertyValue="0" viewModelPropertyId="{P_PASS}"/>'
        f'<ViewModelInstanceString propertyValue="" viewModelPropertyId="{P_INFO}"/></ViewModelInstance>'
        '<NestedStateMachine animationId="0:3207" name="SM"/></NestedArtboardLayout></LayoutComponent>\n'
        '        <StateMachine name="State Machine 1" id="0:3107"><StateMachineLayer name="Layer 1" id="0:3108">'
        '<AnyState x="0" y="-120" id="0:3109"/><ExitState x="120" y="-120" id="0:3110"/>'
        '<EntryState id="0:3111"/></StateMachineLayer></StateMachine>\n    </Artboard>')
    vm = (f'    <ViewModel defaultInstanceId="{VM_INST}" name="EffectsPicker" id="{VM}">\n'
          f'        <ViewModelPropertyNumber name="pass" id="{P_PASS}"/>\n'
          f'        <ViewModelPropertyString name="info" id="{P_INFO}"/>\n'
          f'        <ViewModelInstance exports="true" name="Default" id="{VM_INST}">'
          f'<ViewModelInstanceNumber propertyValue="0" viewModelPropertyId="{P_PASS}"/>'
          f'<ViewModelInstanceString propertyValue="" viewModelPropertyId="{P_INFO}"/></ViewModelInstance>\n'
          f'    </ViewModel>')
    block = "\n".join([
        BEGIN,
        "    <!-- Effects: one scene, a Rive pass picker over it (examples/effects/effects.as).",
        "         Generated: edit tools/make_effects_ui.py, not this block. -->",
        effects, stage, vm, "    " + "\n    ".join(converters),
        '    <ComponentAsset artboardId="0:3200" name="EffectsStage" id="0:3299"/>', END])
    src = open(RML).read()
    if BEGIN in src:
        start = src.index(BEGIN)
        end = src.index(END) + len(END)
        src = src[:start] + block + src[end:]
    else:
        i = src.index("\n\n    <ScriptAsset ")
        src = src[:i] + "\n\n" + block + src[i:]
    open(RML, "w").write(src)
    print("wrote the Effects block of examples/effects/effects.rml (%d passes)" % len(PASSES))


if __name__ == "__main__":
    main()
