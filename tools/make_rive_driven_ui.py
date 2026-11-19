"""Writes the RiveDriven example's artboards into examples/examples.rml
(between the RIVEDRIVEN markers): Rive driving a three.js scene
(examples/rive_driven.as).

    python3 tools/make_rive_driven_ui.py

- RiveDriven, what the gallery nests: RiveDrivenStage as a *stateful*
  nested artboard (its own RiveDrivenScene view model instance, as
  Effects does).
- RiveDrivenStage: the script's ScriptedLayout under a panel of Rive
  controls. Its state machine drives the scene through the view model:
  the Sky layer's Day and Night states key a hidden node whose x is bound
  back (direction="true") into `daylight`, so the 1.2 s transition fades
  the sun; the Turn layer loops a timeline keying another node into
  `spin` (degrees). Buttons write `night` (negated), `tint` and fire
  `jump`. `height` comes back from the scene and fills a meter; `info` is
  the script's caption. `threeBindings` lists the bindings the script's
  ThreeLayout makes (SceneBindings): edit it in the editor to rewire.
- RiveDrivenLabel: the 2D label drawn over the 3D objects
  (Artboard2DObject), its own SceneLabel view model (`text`, `active`);
  a click toggles `active` and the dot lights up.
- RiveDrivenRig: a four-bone Rive arm with a Wave timeline, played by the
  script and retargeted onto a three.js skeleton (RiveRig); it is also
  drawn as a HUD in the corner.

Ids: 0:37xx RiveDriven, 0:38xx RiveDrivenStage, 0:39xx view models and
the label and rig artboards, 0:140000 and up generated. Text uses the
gallery's IoskeleyMono and Inter fonts (106:3, 106:2).
"""
import os
from xml.sax.saxutils import quoteattr

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
RML = os.path.join(ROOT, "examples", "examples.rml")
BEGIN = "    <!-- BEGIN RiveDriven (tools/make_rive_driven_ui.py) -->"
END = "    <!-- END RiveDriven -->"

MONO, INTER = "106:3", "106:2"
AMBER, WHITE, DIM, PANEL = "FFFFA41C", "FFFFFFFF", "99FFFFFF", "B30B0D12"
K_OPACITY, K_TEXT, K_X, K_WIDTH = 18, 268, 13, 20
K_BOOL, K_NUMBER, K_COLOR, K_TRIGGER = 634, 636, 638, 686

# The stage's view model.
VM, VM_INST = "0:3900", "0:3901"
P = {"night": "0:3902", "daylight": "0:3903", "spin": "0:3904", "jump": "0:3905", "height": "0:3906",
     "tint": "0:3907", "info": "0:3908", "threeBindings": "0:3909"}
# The label's view model.
LVM, LVM_INST, LP_TEXT, LP_ACTIVE = "0:3920", "0:3921", "0:3922", "0:3923"

BINDINGS = "; ".join([
    "daylight -> Sun.intensity * 0.03",
    "daylight -> Sky.intensity * 0.012 + 0.25",
    "daylight -> Bulb.material.emissiveIntensity * -0.04 + 4",
    "night -> Lamp.visible",
    "spin -> Turntable.rotation[y] * 0.0174533",
    "tint <-> Globe.material.color",
    "height <- Crate.position[y]",
    "jump -> @jump.play",
])
TINTS = [("FF2B8CBE", "BLUE"), ("FFE0B44C", "GOLD"), ("FFC4553D", "RED")]

_next = [140000]


def nid():
    _next[0] += 1
    return f"0:{_next[0]}"


def a(v):
    return quoteattr(str(v))


def paint(kind, color, extra=""):
    return f'<{kind}{extra} name="{kind}"><SolidColor colorValue="{color}" name="Color"/></{kind}>'


def style(name, sid, *, d="column", w="fill", h="hug", gap=0, pad=0, radius=0, absolute=None, align=None):
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
    if absolute:
        st.append('positionTypeValue="absolute"')
        for k, v in absolute.items():
            st.append(f'position{k.capitalize()}="{v}" position{k.capitalize()}UnitsValue="points"')
    return f'<LayoutComponentStyle {" ".join(st)} name={a(name + " Style")} id="{sid}"/>'


def box(name, children="", *, bid=None, fill=None, width=0, height=0, binds="", **kw):
    bid = bid or nid()
    sid = nid()
    return (f'<LayoutComponent clip="false" width="{width}" height="{height}" styleId="{sid}" name={a(name)} '
            f'id="{bid}">{style(name, sid, **kw)}{binds}{children}{paint("Fill", fill) if fill else ""}'
            f'</LayoutComponent>')


def text(name, s, font, size, color, bind=None, width=None):
    sid = nid()
    fam = "IoskeleyMono" if font == MONO else "Inter"
    b = f'<DataBindContext sourcePathIds="{bind}" propertyKey="{K_TEXT}"/>' if bind else ""
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


def layer(name, lid, entry_to, states):
    """A layer: Any/Exit/Entry, then `states` (xml strings)."""
    return (f'<StateMachineLayer name={a(name)} id="{lid}"><AnyState x="0" y="-120" id="{nid()}"/>'
            f'<ExitState x="120" y="-120" id="{nid()}"/><EntryState id="{nid()}">'
            f'<StateTransition stateToId="{entry_to}" id="{nid()}"/></EntryState>{"".join(states)}'
            f'</StateMachineLayer>')


def bool_transition(to, path, value, duration):
    return (f'<StateTransition stateToId="{to}" duration="{duration}" id="{nid()}">'
            f'<TransitionViewModelCondition id="{nid()}"><TransitionPropertyViewModelComparator id="{nid()}">'
            f'<BindablePropertyBoolean id="{nid()}"><DataBindContext sourcePathIds="{path}" propertyKey="{K_BOOL}" '
            f'id="{nid()}"/></BindablePropertyBoolean></TransitionPropertyViewModelComparator>'
            f'<TransitionValueBooleanComparator value="{"true" if value else "false"}" id="{nid()}"/>'
            f'</TransitionViewModelCondition></StateTransition>')


def keyed(object_id, prop, frames, interp="hold"):
    """frames: [(frame, value)]"""
    keys = "".join(f'<KeyFrameDouble frame="{f}" value="{v}" interpolationType="{interp}" id="{nid()}"/>'
                   for f, v in frames)
    return (f'<KeyedObject objectId="{object_id}" id="{nid()}"><KeyedProperty property="{prop}" id="{nid()}">'
            f'{keys}</KeyedProperty></KeyedObject>')


def keyed_color(object_id, color):
    return (f'<KeyedObject objectId="{object_id}" id="{nid()}"><KeyedProperty property="colorValue" id="{nid()}">'
            f'<KeyFrameColor value="{color}" interpolationType="hold" id="{nid()}"/></KeyedProperty></KeyedObject>')


def negate_listener(target, path, conv):
    rid = nid()
    return (f'<StateMachineListenerSingle targetId="{target}" listenerTypeValue="click" name="Toggle" id="{nid()}">'
            f'<ListenerViewModelChange fromViewModelProperty="true" fromDataBindId="{rid}" id="{nid()}">'
            f'<BindablePropertyBoolean id="{nid()}">'
            f'<DataBindContext sourcePathIds="{path}" propertyKey="{K_BOOL}" converterId="{conv}" id="{rid}"/>'
            f'<DataBindContext sourcePathIds="{path}" propertyKey="{K_BOOL}" direction="true" id="{nid()}"/>'
            f'</BindablePropertyBoolean></ListenerViewModelChange></StateMachineListenerSingle>')


def stage():
    vmp = lambda k: f"{VM}-{P[k]}"
    # Controls: a Day/Night switch, three tint swatches, a Jump button, the
    # crate height meter. The first declared paints on top.
    knob_id = "0:3810"
    switch = box("Switch", box("Knob", fill=AMBER, w="fixed", h="fixed", width=12, height=12, radius=6,
                               bid=knob_id, absolute={"left": 2, "top": 2}),
                 w="fixed", h="fixed", width=34, height=16, radius=8, fill="33FFFFFF")
    night_button = box("NightButton", switch + text("NightLabel", "DAY / NIGHT", MONO, 10, WHITE),
                       bid="0:3811", d="row", w="hug", gap=8, pad=(5, 8, 5, 8), radius=3, align="centerLeft",
                       fill="14FFFFFF")
    swatches, listeners = [], []
    for k, (color, label) in enumerate(TINTS):
        sid = nid()
        swatches.append(box(f"Tint{k}", box(f"Swatch{k}", fill=color, w="fixed", h="fixed", width=12, height=12,
                                            radius=6) + text(f"TintLabel{k}", label, MONO, 10, WHITE),
                            bid=sid, d="row", w="hug", gap=6, pad=(5, 8, 5, 8), radius=3, align="centerLeft",
                            fill="14FFFFFF"))
        listeners.append(
            f'<StateMachineListenerSingle targetId="{sid}" listenerTypeValue="click" name="Tint{k}" id="{nid()}">'
            f'<ListenerViewModelChange id="{nid()}"><BindablePropertyColor propertyValue="{color}" id="{nid()}">'
            f'<DataBindContext sourcePathIds="{vmp("tint")}" propertyKey="{K_COLOR}" direction="true" id="{nid()}"/>'
            f'</BindablePropertyColor></ListenerViewModelChange></StateMachineListenerSingle>')
    jump_id = "0:3812"
    jump = box("JumpButton", text("JumpLabel", "JUMP", MONO, 10, WHITE), bid=jump_id, w="hug",
               pad=(5, 10, 5, 10), radius=3, fill="33FFA41C")
    listeners.append(
        f'<StateMachineListenerSingle targetId="{jump_id}" listenerTypeValue="click" name="Jump" id="{nid()}">'
        f'<ListenerViewModelChange id="{nid()}"><BindablePropertyTrigger propertyValue="1" id="{nid()}">'
        f'<DataBindContext sourcePathIds="{vmp("jump")}" propertyKey="{K_TRIGGER}" direction="true" id="{nid()}"/>'
        f'</BindablePropertyTrigger></ListenerViewModelChange></StateMachineListenerSingle>')
    listeners.append(negate_listener("0:3811", vmp("night"), "0:3990"))
    # The crate's height (scene -> view model), as a bar.
    bar = (f'<Shape x="0" y="3" name="Bar" id="{nid()}"><Rectangle width="40" height="6" originX="0" originY="0.5" '
           f'name="BarPath" id="{nid()}"><DataBindContext sourcePathIds="{vmp("height")}" propertyKey="{K_WIDTH}" '
           f'converterId="0:3991" id="{nid()}"/></Rectangle>{paint("Fill", AMBER)}</Shape>')
    track = box("Track", bar, w="fixed", h="fixed", width=120, height=6, radius=3, fill="22FFFFFF")
    meter = box("Meter", text("MeterLabel", "CRATE HEIGHT", MONO, 10, DIM) + track, d="row", w="hug", gap=8,
                pad=(5, 8, 5, 8), align="centerLeft")
    title = text("Title", "RIVE DRIVES THE SCENE", MONO, 10, DIM)
    row1 = box("Row1", night_button + jump, d="row", w="hug", gap=4)
    row2 = box("Row2", "".join(swatches), d="row", w="hug", gap=4)
    panel = box("Panel", title + row1 + row2 + meter, w="hug", gap=6, pad=10, radius=6, fill=PANEL,
                absolute={"left": 12, "top": 12})
    caption = box("Caption", text("Info", "", INTER, 12, WHITE, bind=vmp("info")), w="hug", h="hug",
                  pad=(6, 10, 6, 10), radius=4, fill=PANEL, absolute={"left": 12, "bottom": 12})
    scene = ('<ScriptedLayout scriptAssetId="0:3890" name="Scene" id="0:3804">'
             '<ScriptInputArtboard artboardId="0:3930" name="label" id="0:3805"/>'
             '<ScriptInputArtboard artboardId="0:3960" name="rig" id="0:3806"/></ScriptedLayout>')
    root = box("Root", panel + caption + scene, bid="0:3802", w="fill", h="fill")
    # Hidden drivers, their x written back into the view model.
    drivers = (f'<Node x="100" name="DaylightDriver" id="0:3820"><DataBindContext sourcePathIds="{vmp("daylight")}" '
               f'propertyKey="{K_X}" direction="true" id="{nid()}"/></Node>'
               f'<Node x="0" name="SpinDriver" id="0:3821"><DataBindContext sourcePathIds="{vmp("spin")}" '
               f'propertyKey="{K_X}" direction="true" id="{nid()}"/></Node>')
    day_state, night_state, turn_state = "0:3830", "0:3831", "0:3832"
    sky = layer("Sky", "0:3809", day_state, [
        f'<AnimationState x="200" y="0" animationId="0:3840" id="{day_state}">'
        + bool_transition(night_state, vmp("night"), True, 1200) + '</AnimationState>',
        f'<AnimationState x="400" y="0" animationId="0:3841" id="{night_state}">'
        + bool_transition(day_state, vmp("night"), False, 1200) + '</AnimationState>'])
    turn = layer("Turn", nid(), turn_state, [f'<AnimationState x="200" y="100" animationId="0:3842" id="{turn_state}"/>'])
    sm = (f'<StateMachine name="State Machine 1" id="0:3807">{sky}{turn}{"".join(listeners)}</StateMachine>')
    anims = (
        '<LinearAnimation duration="1" name="Day" id="0:3840">' + keyed("0:3820", "x", [(0, 100)])
        + keyed(knob_id, "x", [(0, 2)]) + '</LinearAnimation>'
        '<LinearAnimation duration="1" name="Night" id="0:3841">' + keyed("0:3820", "x", [(0, 0)])
        + keyed(knob_id, "x", [(0, 20)]) + '</LinearAnimation>'
        '<LinearAnimation loopValue="loop" fps="60" duration="720" name="Turn" id="0:3842">'
        + keyed("0:3821", "x", [(0, 0), (720, 360)], "linear") + '</LinearAnimation>')
    return (f'    <Artboard isComponent="true" defaultStateMachineId="0:3807" viewModelId="{VM}" '
            f'viewModelInstanceId="{VM_INST}" clip="true" x="900" y="7700" width="800" height="600" '
            f'styleId="0:3801" name="RiveDrivenStage" id="0:3800">\n'
            f'        <LayoutComponentStyle name="Artboard Style" id="0:3801"/>\n'
            f'        {drivers}\n        {root}\n        {sm}\n        {anims}\n    </Artboard>')


def vm_values(inst_id, name):
    v = {"night": '<ViewModelInstanceBoolean propertyValue="false" viewModelPropertyId="%s"/>',
         "daylight": '<ViewModelInstanceNumber propertyValue="100" viewModelPropertyId="%s"/>',
         "spin": '<ViewModelInstanceNumber propertyValue="0" viewModelPropertyId="%s"/>',
         "jump": '<ViewModelInstanceTrigger viewModelPropertyId="%s"/>',
         "height": '<ViewModelInstanceNumber propertyValue="0" viewModelPropertyId="%s"/>',
         "tint": f'<ViewModelInstanceColor propertyValue="{TINTS[0][0]}" viewModelPropertyId="%s"/>',
         "info": '<ViewModelInstanceString propertyValue="" viewModelPropertyId="%s"/>',
         "threeBindings": f'<ViewModelInstanceString propertyValue={a(BINDINGS)} viewModelPropertyId="%s"/>'}
    return (f'<ViewModelInstance viewModelId="{VM}" exports="true" name="{name}" id="{inst_id}">'
            if name != "Default" else f'<ViewModelInstance exports="true" name="Default" id="{inst_id}">') + \
        "".join(v[k] % P[k] for k in P) + '</ViewModelInstance>'


def view_models():
    kinds = {"night": "Boolean", "daylight": "Number", "spin": "Number", "jump": "Trigger", "height": "Number",
             "tint": "Color", "info": "String", "threeBindings": "String"}
    props = "".join(f'<ViewModelProperty{kinds[k]} name="{k}" id="{P[k]}"/>' for k in P)
    scene_vm = (f'    <ViewModel defaultInstanceId="{VM_INST}" name="RiveDrivenScene" id="{VM}">\n        {props}\n'
                f'        {vm_values(VM_INST, "Default")}\n    </ViewModel>')
    label_vm = (f'    <ViewModel defaultInstanceId="{LVM_INST}" name="SceneLabel" id="{LVM}">\n'
                f'        <ViewModelPropertyString name="text" id="{LP_TEXT}"/>'
                f'<ViewModelPropertyBoolean name="active" id="{LP_ACTIVE}"/>\n'
                f'        <ViewModelInstance exports="true" name="Default" id="{LVM_INST}">'
                f'<ViewModelInstanceString propertyValue="Label" viewModelPropertyId="{LP_TEXT}"/>'
                f'<ViewModelInstanceBoolean propertyValue="false" viewModelPropertyId="{LP_ACTIVE}"/>'
                f'</ViewModelInstance>\n    </ViewModel>')
    return scene_vm + "\n" + label_vm


def driven():
    return (
        '    <Artboard isComponent="true" defaultStateMachineId="0:3707" clip="true" x="900" y="7000" '
        'width="800" height="600" styleId="0:3701" name="RiveDriven" id="0:3700">\n'
        '        <LayoutComponentStyle name="Artboard Style" id="0:3701"/>\n'
        '        <LayoutComponent width="800" height="600" styleId="0:3703" name="Root" id="0:3702">'
        '<LayoutComponentStyle layoutWidthScaleType="1" layoutHeightScaleType="1" widthUnitsValue="3" '
        'heightUnitsValue="3" name="Root Style" id="0:3703"/>'
        '<NestedArtboardLayout artboardId="0:3800" isStateful="true" instanceWidth="100" '
        'instanceWidthUnitsValue="percent" instanceHeight="100" instanceHeightUnitsValue="percent" '
        'name="Stage" id="0:3704">' + vm_values("0:3705", "Stage Instance")
        + '<NestedStateMachine animationId="0:3807" name="SM"/></NestedArtboardLayout></LayoutComponent>\n'
        '        <StateMachine name="State Machine 1" id="0:3707"><StateMachineLayer name="Layer 1" id="0:3708">'
        '<AnyState x="0" y="-120" id="0:3709"/><ExitState x="120" y="-120" id="0:3710"/>'
        '<EntryState id="0:3711"/></StateMachineLayer></StateMachine>\n    </Artboard>')


def label():
    """A pill: a dot (amber while `active`) and the bound text."""
    lp = lambda p: f"{LVM}-{p}"
    dot_color = "0:3940"
    dot_style = nid()
    dot = (f'<LayoutComponent clip="false" width="8" height="8" styleId="{dot_style}" name="Dot" id="{nid()}">'
           f'<LayoutComponentStyle layoutWidthScaleType="fixed" layoutHeightScaleType="fixed" linkCornerRadius="true" '
           f'cornerRadiusTL="4" cornerRadiusTR="4" cornerRadiusBL="4" cornerRadiusBR="4" name="Dot Style" id="{dot_style}"/>'
           f'<Fill name="Fill"><SolidColor colorValue="66FFFFFF" name="DotColor" id="{dot_color}"/></Fill>'
           f'</LayoutComponent>')
    pill = box("Pill", dot + text("Text", "Label", INTER, 13, WHITE, bind=lp(LP_TEXT)), bid="0:3935", d="row",
               w="hug", gap=7, pad=(5, 10, 5, 10), radius=12, align="centerLeft", fill="CC0B0D12")
    root = box("Root", pill, bid="0:3934", w="fill", h="fill", align="center")
    off, on = "0:3941", "0:3942"
    sm = ('<StateMachine name="State Machine 1" id="0:3937">'
          + layer("Layer 1", "0:3938", off, [
              f'<AnimationState x="200" y="0" animationId="0:3945" id="{off}">'
              + bool_transition(on, lp(LP_ACTIVE), True, 150) + '</AnimationState>',
              f'<AnimationState x="400" y="0" animationId="0:3946" id="{on}">'
              + bool_transition(off, lp(LP_ACTIVE), False, 150) + '</AnimationState>'])
          + negate_listener("0:3935", lp(LP_ACTIVE), "0:3990") + '</StateMachine>')
    anims = ('<LinearAnimation duration="1" name="Off" id="0:3945">' + keyed_color(dot_color, "66FFFFFF")
             + '</LinearAnimation><LinearAnimation duration="1" name="On" id="0:3946">'
             + keyed_color(dot_color, AMBER) + '</LinearAnimation>')
    return (f'    <Artboard defaultStateMachineId="0:3937" viewModelId="{LVM}" viewModelInstanceId="{LVM_INST}" '
            f'x="1800" y="7000" width="140" height="30" styleId="0:3931" name="RiveDrivenLabel" id="0:3930">\n'
            f'        <LayoutComponentStyle name="Artboard Style" id="0:3931"/>\n        {root}\n        {sm}\n        {anims}\n    </Artboard>')


def rig():
    """Four bones (Arm0-Arm3) up from the bottom centre, a capsule on each,
    and a Wave timeline. Its state machine is empty, so the script plays
    Wave by hand (and bakes it)."""
    length = 52
    shapes = lambda k, c: (
        f'<Shape x="{length / 2}" y="0" name="Seg{k}" id="{nid()}"><Rectangle width="{length + 10}" height="{22 - 3 * k}" '
        f'originX="0.5" originY="0.5" linkCornerRadius="true" cornerRadiusTL="10" cornerRadiusTR="10" '
        f'cornerRadiusBL="10" cornerRadiusBR="10" name="SegPath" id="{nid()}"/>{paint("Fill", c)}</Shape>')
    colors = ["FF2EC4B6", "FF35D0C1", "FF5ADBCF", "FF8AE6DD"]
    ids = ["0:3970", "0:3971", "0:3972", "0:3973"]
    inner = ""
    for k in range(3, 0, -1):
        inner = f'<Bone length="{length}" rotation="0" name="Arm{k}" id="{ids[k]}">{shapes(k, colors[k])}{inner}</Bone>'
    bones = (f'<RootBone x="110" y="210" length="{length}" rotation="-1.5707964" name="Arm0" id="{ids[0]}">'
             f'{shapes(0, colors[0])}{inner}</RootBone>')
    # The wave: each bone swings, later bones later and wider.
    keys = ""
    for k in range(4):
        amp = 0.18 + 0.1 * k
        frames = [(0, -amp), (60, amp), (120, -amp)]
        keys += (f'<KeyedObject objectId="{ids[k]}" id="{nid()}"><KeyedProperty property="rotation" id="{nid()}">'
                 + "".join(f'<KeyFrameDouble frame="{f + 0}" value="{(-1.5707964 if k == 0 else 0) + v + 0:.5f}" '
                           f'interpolationType="cubic" id="{nid()}"><CubicEaseInterpolator x1="0.42" y1="0" x2="0.58" '
                           f'y2="1"/></KeyFrameDouble>' for f, v in frames)
                 + '</KeyedProperty></KeyedObject>')
    base = (f'<Shape x="110" y="214" name="Base" id="{nid()}"><Rectangle width="60" height="12" originX="0.5" '
            f'originY="0.5" linkCornerRadius="true" cornerRadiusTL="4" cornerRadiusTR="4" cornerRadiusBL="4" '
            f'cornerRadiusBR="4" name="BasePath" id="{nid()}"/>{paint("Fill", "FF5C6370")}</Shape>')
    bg = (f'<Shape x="110" y="115" name="Backdrop" id="{nid()}"><Rectangle width="220" height="230" originX="0.5" '
          f'originY="0.5" linkCornerRadius="true" cornerRadiusTL="8" cornerRadiusTR="8" cornerRadiusBL="8" '
          f'cornerRadiusBR="8" name="BackdropPath" id="{nid()}"/>{paint("Fill", "B30B0D12")}</Shape>')
    caption_style = nid()
    caption = (f'<Text x="12" y="10" wrapValue="noWrap" sizingValue="autoWidth" name="RigCaption" id="{nid()}">'
               f'<TextStylePaint fontSize="10" fontAssetId="{MONO}" familyName="IoskeleyMono" name="Style" '
               f'id="{caption_style}">{paint("Fill", DIM)}</TextStylePaint>'
               f'<TextValueRun styleId="{caption_style}" text="RIVE BONES" name="Run"/></Text>')
    sm = ('<StateMachine name="State Machine 1" id="0:3967"><StateMachineLayer name="Layer 1" id="0:3968">'
          f'<AnyState x="0" y="-120" id="{nid()}"/><ExitState x="120" y="-120" id="{nid()}"/>'
          f'<EntryState id="{nid()}"/></StateMachineLayer></StateMachine>')
    # The first declared paints on top: caption, bones, base, backdrop.
    return (f'    <Artboard defaultStateMachineId="0:3967" x="2000" y="7000" width="220" height="230" '
            f'styleId="0:3961" name="RiveDrivenRig" id="0:3960">\n'
            f'        <LayoutComponentStyle name="Artboard Style" id="0:3961"/>\n'
            f'        {caption}{bones}{base}{bg}\n        {sm}\n'
            f'        <LinearAnimation loopValue="loop" fps="60" duration="120" name="Wave" id="0:3965">{keys}'
            f'</LinearAnimation>\n    </Artboard>')


def main():
    converters = ('    <DataConverterBooleanNegate name="Not" id="0:3990"/>\n'
                  '    <DataConverterRangeMapper minInput="0" maxInput="1.6" minOutput="0" maxOutput="120" '
                  'clampLower="true" clampUpper="true" name="HeightToWidth" id="0:3991"/>')
    block = "\n".join([
        BEGIN,
        "    <!-- RiveDriven: Rive driving a three.js scene (examples/rive_driven.as).",
        "         Generated: edit tools/make_rive_driven_ui.py, not this block. -->",
        driven(), stage(), label(), rig(), view_models(), converters,
        '    <ComponentAsset artboardId="0:3800" name="RiveDrivenStage" id="0:3799"/>', END])
    src = open(RML).read()
    if BEGIN in src:
        start = src.index(BEGIN)
        end = src.index(END) + len(END)
        src = src[:start] + block + src[end:]
    else:
        marker = '\n\n    <ScriptAsset file="examples/first_scene.as"'
        i = src.index(marker)
        src = src[:i] + "\n\n" + block + src[i:]
    asset = '    <ScriptAsset file="examples/rive_driven.as" name="rive_driven" id="0:3890"/>\n'
    if asset not in src:
        anchor = '    <ScriptAsset file="examples/animation.as" name="animation" id="0:3690"/>\n'
        src = src.replace(anchor, anchor + asset)
    open(RML, "w").write(src)
    print("wrote the RiveDriven block of examples/examples.rml")


if __name__ == "__main__":
    main()
