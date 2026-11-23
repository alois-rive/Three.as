// Water: three.js's water addons in four setups, picked and tuned from a
// Rive panel (water.rml's WaterStage, made by tools/make_water_ui.py).
//
// - Ocean (webgl_shaders_ocean): Water under a Preetham Sky, which also
//   lights the scene through a PMREM, and a floating cube.
// - Pool (webgl_water): Water2 with its two normal maps, flowing along a
//   direction, over a wooden floor with a torus knot.
// - Flow map (webgl_water_flowmap): Water2 flowing along a flow map, which
//   a plane over the water can show.
// - Mirrors (webgl_mirror, webgl_refraction): Reflector mirrors on the
//   floor and the back wall, which reflect each other, and a rippled glass
//   pane (Refractor + WaterRefractionShader).
// - Tropical (no three.js example): a clear lagoon over sand, rocks and
//   coral, an island with palms, fish; the camera dives under the surface.
//   The surface is a Water2 with a shader of its own (lagoon.wgsl: world
//   space ripples, a sun highlight); everything under it is seabed.wgsl,
//   which lights it through the water with caustics and absorbs the light
//   on its way to the eye (red first, Beer-Lambert), over the path below
//   the surface from above, over the whole distance from below. Under the
//   water Water2 (which faces up; its Reflector and Refractor render
//   nothing from behind their plane) is hidden and a plane facing down
//   shows the surface from below (undersurface.wgsl: Snell's window,
//   total internal reflection past it), the sky is the water's colour and
//   the view sways. The camera orbits as elsewhere, can go below the
//   surface (never within DEAD_BAND of it, where the near plane would cut
//   the surface, nor into the sand), and the VIEW row moves it to a pose
//   (ABOVE, LOW, UNDER, LOOK UP) smoothly.
//
// Each setup is a Scene of its own, built the first time it is picked;
// only the picked one is rendered (the others' mirrors render nothing).
// The panel writes the WaterControls view model: a tab writes `scene`, a
// "-" / "+" button writes `command` (2 row + 1 / 2 row + 2, 99 for the
// settings' HIDE / SHOW), which this script applies and writes back to 0;
// it writes each row's `label<r>` and `value<r>`, `rows` (rows past it are
// out of the layout), `collapsed`, `toggle` (the button's text), `compact`
// (a short stage: no caption, settings hidden at first), `tabsHidden` (a
// compact stage showing the settings hides the tabs), `heading` (the
// settings' title) and the caption, `info`. The panel writes its size to `panelWidth` / `panelHeight`.
// `--arg waterScene=N` starts on setup N (for --bench and screenshots), and
// `--arg waterView=N` Tropical at VIEW's pose N (0 ABOVE ... 3 LOOK UP).

import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";
import { Water } from "lib:threeas/three/addons/objects/Water";
import { Water as Water2 } from "lib:threeas/three/addons/objects/Water2";
import { Sky } from "lib:threeas/three/addons/objects/Sky";
import { Reflector } from "lib:threeas/three/addons/objects/Reflector";
import { Refractor } from "lib:threeas/three/addons/objects/Refractor";
import { WaterRefractionShader } from "lib:threeas/three/addons/shaders/WaterRefractionShader";
import { ShaderDefinition } from "lib:threeas/three/addons/shaders/PostShaders";
import { mergeGeometries } from "lib:threeas/three/addons/utils/BufferGeometryUtils";
import { Context } from "rive/host";
import { PropertyNumber, PropertyString } from "rive/data";
import { PointerEvent } from "rive/events";

// The setups, in the panel's tab order.
const OCEAN = 0;
const POOL = 1;
const FLOW_MAP = 2;
const MIRRORS = 3;
const TROPICAL = 4;
const SCENE_COUNT = 5;
// The panel's rows (make_water_ui.py's ROWS).
const ROW_COUNT = 6;
// The panel's offset in the layout (make_water_ui.py's absolute left / top).
const PANEL_INSET: f64 = 12;
// The settings' HIDE / SHOW button's command.
const TOGGLE_COMMAND = 99;
// Stages shorter than this are compact (the gallery's on a phone).
const COMPACT_HEIGHT: f64 = 360;
// Layer 1: seen by the main camera only (the mirrors' and the glass's
// virtual cameras see layer 0), so the mirrors do not render the glass.
const MAIN_ONLY_LAYER = 1;

const NAMES: StaticArray<string> = ["OCEAN", "POOL", "FLOW MAP", "MIRRORS", "TROPICAL"];
const INFO: StaticArray<string> = [
    "Water (webgl_shaders_ocean): a rippled mirror under a Preetham Sky, which also lights the cube.",
    "Water2 (webgl_water): reflection and refraction mixed by Fresnel, two normal maps flowing one way.",
    "Water2 with a flow map (webgl_water_flowmap): the water follows the map's red and green.",
    "Reflector mirrors reflecting each other (webgl_mirror), and rippled glass: a Refractor (webgl_refraction).",
    "A lagoon: Water2 with its own shader over sand with caustics. Dive: fog, absorption and Snell's window.",
];

/// `v` with `decimals` digits after the point.
function fmt(v: f64, decimals: i32): string {
    if (decimals <= 0) return (<i64>Math.round(v)).toString();
    const scale = <i64>Math.round(Math.pow(10, <f64>decimals));
    const n = <i64>Math.round(Math.abs(v) * <f64>scale);
    let frac = (n % scale).toString();
    while (frac.length < decimals) frac = "0" + frac;
    return (v < 0 && n != 0 ? "-" : "") + (n / scale).toString() + "." + frac;
}

/// One row of the panel: a value picked from a list, stepped by "-" / "+".
class Setting {
    label: string;
    values: Array<f64>;
    /// Shown in place of the values when not empty.
    names: Array<string> = [];
    index: i32;
    decimals: i32 = 1;
    suffix: string = "";
    /// Steps past either end wrap around (a bearing, presets).
    wrap: bool = false;

    constructor(label: string, values: Array<f64>, start: f64) {
        this.label = label;
        this.values = values;
        this.index = 0;
        for (let i = 0; i < values.length; i++) if (values[i] == start) this.index = i;
    }

    static named(label: string, values: Array<f64>, names: Array<string>, start: f64): Setting {
        const s = new Setting(label, values, start);
        s.names = names;
        s.wrap = true;
        return s;
    }

    static toggle(label: string, on: bool): Setting {
        return Setting.named(label, [0, 1], ["OFF", "ON"], on ? 1 : 0);
    }

    get value(): f64 { return this.values[this.index]; }
    get on(): bool { return this.values[this.index] != 0; }

    /// Steps by `delta`; false when it was already at that end.
    step(delta: i32): bool {
        const n = this.values.length;
        let i = this.index + delta;
        if (this.wrap) i = ((i % n) + n) % n;
        else if (i < 0 || i >= n) return false;
        this.index = i;
        return true;
    }

    text(): string {
        if (this.names.length > 0) return this.names[this.index];
        return fmt(this.value, this.decimals) + this.suffix;
    }
}

/// A camera pose and OrbitControls limits per setup.
class View {
    position: THREE.Vector3;
    target: THREE.Vector3;
    fov: f64;
    near: f64;
    far: f64;
    minDistance: f64;
    maxDistance: f64;
    maxPolarAngle: f64;

    constructor(position: THREE.Vector3, target: THREE.Vector3, fov: f64, near: f64, far: f64, minDistance: f64,
                maxDistance: f64, maxPolarAngle: f64) {
        this.position = position;
        this.target = target;
        this.fov = fov;
        this.near = near;
        this.far = far;
        this.minDistance = minDistance;
        this.maxDistance = maxDistance;
        this.maxPolarAngle = maxPolarAngle;
    }
}

/// A size x size wooden floor: planks of varying tone with dark seams.
function planks(size: i32): THREE.DataTexture {
    const data = new Uint8Array(size * size * 4);
    const plank = size / 8;
    for (let y = 0; y < size; y++) {
        const row = y / plank;
        // Each row of planks is offset, and planks are size / 2 long.
        const offset = (row * 37) % size;
        for (let x = 0; x < size; x++) {
            const p = ((x + offset) % size) / (size / 2);
            const k = <f64>((row * 7 + p * 3) % 5) / 4;
            const grain = Math.sin(<f64>x * 0.21 + <f64>row * 1.7) * 0.06 + Math.sin(<f64>x * 0.047 + <f64>y) * 0.03;
            const seam = y % plank == 0 || (x + offset) % (size / 2) == 0;
            const t = seam ? 0.35 : 0.82 + k * 0.18 + grain;
            const o = (y * size + x) * 4;
            data[o] = <u8>Math.min(255, 168 * t);
            data[o + 1] = <u8>Math.min(255, 118 * t);
            data[o + 2] = <u8>Math.min(255, 74 * t);
            data[o + 3] = 255;
        }
    }
    const texture = new THREE.DataTexture(data, size, size);
    texture.colorSpace = THREE.SRGBColorSpace;
    texture.wrapS = texture.wrapT = THREE.RepeatWrapping;
    texture.repeat.set(4, 4);
    texture.needsUpdate = true;
    return texture;
}

/// three.js's FloorsCheckerboard: a size x size checkerboard of grey tiles.
function checker(size: i32, cells: i32): THREE.DataTexture {
    const data = new Uint8Array(size * size * 4);
    const cell = size / cells;
    for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
            const edge = x % cell == 0 || y % cell == 0;
            const c: i32 = edge ? 70 : (((x / cell + y / cell) & 1) == 0 ? 210 : 120);
            const o = (y * size + x) * 4;
            data[o] = <u8>c;
            data[o + 1] = <u8>c;
            data[o + 2] = <u8>c;
            data[o + 3] = 255;
        }
    }
    const texture = new THREE.DataTexture(data, size, size);
    texture.colorSpace = THREE.SRGBColorSpace;
    texture.wrapS = texture.wrapT = THREE.RepeatWrapping;
    texture.repeat.set(4, 4);
    texture.needsUpdate = true;
    return texture;
}

// Water2's colour presets (the water's tint), and the others'.
const TINTS: Array<f64> = [0xffffff, 0xa6e3ff, 0x8ff0d0, 0xc8e08f, 0xffd58a, 0xffb8c8];
const TINT_NAMES: Array<string> = ["WHITE", "SKY", "LAGOON", "MOSS", "AMBER", "ROSE"];
const OCEANS: Array<f64> = [0x001e0f, 0x002a4a, 0x00525e, 0x1a2328, 0x0d3d4f, 0x2b2410];
const OCEAN_NAMES: Array<string> = ["ATLANTIC", "PACIFIC", "TROPICAL", "STORM", "ARCTIC", "SILT"];
const METALS: Array<f64> = [0xc1cbcb, 0x8494a3, 0xe3c374, 0xe8b0b6, 0xa2d6b5];
const METAL_NAMES: Array<string> = ["SILVER", "STEEL", "GOLD", "ROSE", "JADE"];
const GLASSES: Array<f64> = [0xcbcbcb, 0x9ec5ff, 0xa8e6b4, 0xffcf8a, 0xffb3c6];
const GLASS_NAMES: Array<string> = ["CLEAR", "BLUE", "GREEN", "AMBER", "ROSE"];
const SPEEDS: Array<f64> = [0, 0.25, 0.5, 1, 2, 4];
const REFLECTIVITIES: Array<f64> = [0, 0.02, 0.05, 0.1, 0.2, 0.35, 0.5, 0.75, 1];

// Tropical: the water presets (the colour the water fades to, sRGB, and
// its absorption's ratios per channel), the views (target height, polar
// angle in degrees, distance), the water's height and the band around it
// the camera skips.
const LAGOON_NAMES: Array<string> = ["TEAL", "LAGOON", "AQUA", "EMERALD", "DEEP"];
const LAGOON_SCATTER: StaticArray<u32> = [0x1b8a96, 0x2fb0a8, 0x2a93cc, 0x1f8c6c, 0x0b3e6a];
const LAGOON_ABSORB: StaticArray<f64> = [1, 0.30, 0.24, 1, 0.22, 0.27, 1, 0.34, 0.16, 1, 0.24, 0.40, 1, 0.5, 0.3];
const VIEW_NAMES: Array<string> = ["ABOVE", "LOW", "UNDER", "LOOK UP"];
const VIEW_POSES: StaticArray<f64> = [-2, 62, 26, 0.6, 86, 16, -2.4, 96, 10, -1.2, 150, 4];
const WATER_LEVEL: f64 = 0;
const DEAD_BAND: f64 = 0.12;
// The camera stays this far above the sand.
const FLOOR_CLEARANCE: f64 = 0.5;

function smooth(edge0: f64, edge1: f64, x: f64): f64 {
    const t = Math.min(1, Math.max(0, (x - edge0) / (edge1 - edge0)));
    return t * t * (3 - 2 * t);
}

/// The lagoon floor's height at x, z: a basin about 6 m deep, a reef
/// around it 64 m out and the open sea past it, and an island.
function lagoonHeight(x: f64, z: f64): f64 {
    const r = Math.sqrt(x * x + z * z);
    let h = -6.4 + 1.0 * Math.sin(x * 0.07 + 1.3) * Math.cos(z * 0.06 - 0.4);
    h += Math.exp(-Math.pow((r - 64) / 9, 2)) * 4.6;
    const open = smooth(68, 100, r);
    h = h * (1 - open) - 30 * open;
    const ix = x - 16, iz = z + 30;
    h = Math.max(h, -6 + 8.6 * Math.exp(-(ix * ix + iz * iz * 1.4) / 260));
    return h + 0.08 * Math.sin(x * 1.3 + z * 0.4) + 0.05 * Math.sin(z * 1.7 - x * 0.3);
}

/// A small deterministic random sequence (the scene is the same each run).
class Rng {
    seed: u32;
    constructor(seed: u32) { this.seed = seed; }
    next(): f64 {
        this.seed = this.seed * 1664525 + 1013904223;
        return <f64>(this.seed >> 8) / 16777216.0;
    }
    range(a: f64, b: f64): f64 { return a + (b - a) * this.next(); }
}

/// Water2's shader for the lagoon (lagoon.wgsl): Water2's uniforms, then
/// the sun, the ripples' time and size, shared with the other materials.
class LagoonShader extends ShaderDefinition {
    sunDirection: THREE.Uniform<THREE.Vector3>;
    time: THREE.Uniform<f64>;
    sunColor: THREE.Uniform<THREE.Color>;
    waveSize: THREE.Uniform<f64>;

    constructor(sunDirection: THREE.Uniform<THREE.Vector3>, time: THREE.Uniform<f64>, sunColor: THREE.Uniform<THREE.Color>,
                waveSize: THREE.Uniform<f64>) {
        super("LagoonShader", "examples/water/lagoon");
        this.sunDirection = sunDirection;
        this.time = time;
        this.sunColor = sunColor;
        this.waveSize = waveSize;
    }

    override uniforms(): Map<string, THREE.UniformBase> {
        const m = Water2.WaterShader.uniforms();
        // Water2's are all there; these follow them (insertion order).
        m.set("sunDirection", this.sunDirection);
        m.set("time", this.time);
        m.set("sunColor", this.sunColor);
        m.set("waveSize", this.waveSize);
        return m;
    }
}

export class WaterExample extends THREE.ThreeLayout {
    scenes: Array<THREE.Scene> = [];
    built: Array<bool> = [];
    settings: Array<Array<Setting>> = [];
    views: Array<View> = [];
    current: i32 = -1;
    loader: THREE.TextureLoader? = null;
    sceneProperty: PropertyNumber? = null;
    commandProperty: PropertyNumber? = null;
    rowsProperty: PropertyNumber? = null;
    collapsedProperty: PropertyNumber? = null;
    compactProperty: PropertyNumber? = null;
    panelWidthProperty: PropertyNumber? = null;
    panelHeightProperty: PropertyNumber? = null;
    toggleProperty: PropertyString? = null;
    tabsHiddenProperty: PropertyNumber? = null;
    headingProperty: PropertyString? = null;
    collapsed: bool = false;
    /// A short stage (no caption; the settings start hidden).
    compact: bool = false;
    /// Whether HIDE / SHOW was pressed (then resizes leave it alone).
    toggled: bool = false;
    infoProperty: PropertyString? = null;
    labelProperties: Array<PropertyString?> = [];
    valueProperties: Array<PropertyString?> = [];
    time: f64 = 0;

    // Ocean.
    ocean: Water? = null;
    sky: Sky = new Sky();
    envSky: Sky = new Sky();
    envScene: THREE.Scene = new THREE.Scene();
    pmrem: THREE.PMREMGenerator = new THREE.PMREMGenerator();
    environment: THREE.PMREMResult? = null;
    sun: THREE.Vector3 = new THREE.Vector3();
    sunElevation: f64 = -1000;
    sunAzimuth: f64 = -1000;
    cube: THREE.Mesh = new THREE.Mesh();
    // Pool.
    pool: Water2? = null;
    knot: THREE.Mesh = new THREE.Mesh();
    // Flow map.
    stream: Water2? = null;
    flowHelper: THREE.Mesh = new THREE.Mesh();
    // Mirrors.
    groundMirror: Reflector? = null;
    wallMirror: Reflector? = null;
    glass: Refractor? = null;
    glassTime: f64 = 0;
    sphereGroup: THREE.Object3D = new THREE.Object3D();
    smallSphere: THREE.Mesh = new THREE.Mesh();
    // Tropical. Its materials share these uniforms (one write updates all).
    lagoon: Water2? = null;
    underside: THREE.Mesh = new THREE.Mesh();
    dome: THREE.Mesh = new THREE.Mesh();
    above: THREE.Object3D = new THREE.Object3D();
    shafts: THREE.Object3D = new THREE.Object3D();
    /// Up along the light shafts (towards the sun, refracted).
    shaftAxis: THREE.Vector3 = new THREE.Vector3();
    basis: THREE.Matrix4 = new THREE.Matrix4();
    axisX: THREE.Vector3 = new THREE.Vector3();
    axisZ: THREE.Vector3 = new THREE.Vector3();
    fish: Array<THREE.Mesh> = [];
    /// Per fish: radius, height, phase, speed.
    fishPaths: Array<f64> = [];
    sunDirection: THREE.Uniform<THREE.Vector3> = new THREE.Uniform<THREE.Vector3>(
        new THREE.Vector3(0.45, 0.64, -0.62).normalize());
    sunColor: THREE.Uniform<THREE.Color> = new THREE.Uniform<THREE.Color>(new THREE.Color(1, 0.96, 0.88));
    ambient: THREE.Uniform<THREE.Color> = new THREE.Uniform<THREE.Color>(new THREE.Color(0.30, 0.42, 0.52));
    seaTime: THREE.Uniform<f64> = new THREE.Uniform<f64>(0);
    flowTime: THREE.Uniform<f64> = new THREE.Uniform<f64>(0);
    waveSize: THREE.Uniform<f64> = new THREE.Uniform<f64>(2);
    flowDirection: THREE.Uniform<THREE.Vector2> = new THREE.Uniform<THREE.Vector2>(new THREE.Vector2(0.8, 0.6));
    absorption: THREE.Uniform<THREE.Vector3> = new THREE.Uniform<THREE.Vector3>(new THREE.Vector3());
    caustics: THREE.Uniform<f64> = new THREE.Uniform<f64>(1);
    scatter: THREE.Uniform<THREE.Color> = new THREE.Uniform<THREE.Color>(new THREE.Color());
    waterLevel: THREE.Uniform<f64> = new THREE.Uniform<f64>(WATER_LEVEL);
    wobble: THREE.Uniform<f64> = new THREE.Uniform<f64>(0);
    /// The water's colour, the background under the water.
    waterColor: THREE.Color = new THREE.Color();
    /// Whether the camera was under the water at the last render.
    under: bool = false;
    lastCameraY: f64 = 0;
    /// The VIEW row's pose being eased to.
    diving: bool = false;
    diveTarget: f64 = 0;
    divePolar: f64 = 0;
    diveDistance: f64 = 0;
    spherical: THREE.Spherical = new THREE.Spherical();
    offset: THREE.Vector3 = new THREE.Vector3();

    override setup(context: Context): bool {
        this.loader = new THREE.TextureLoader(context);
        this.pmrem = new THREE.PMREMGenerator(this.renderer!);
        this.camera.layers.enable(MAIN_ONLY_LAYER);

        // Ocean: as webgl_shaders_ocean's GUI.
        this.settings.push([
            new Setting("SUN HEIGHT", [0, 1, 2, 4, 7, 10, 15, 20, 30, 45, 60, 90], 2),
            new Setting("SUN BEARING", [-165, -150, -135, -120, -105, -90, -75, -60, -45, -30, -15, 0, 15, 30, 45,
                60, 75, 90, 105, 120, 135, 150, 165, 180], 180),
            new Setting("DISTORTION", [0, 0.5, 1, 2, 3.7, 5, 6.5, 8], 3.7),
            new Setting("WAVE SIZE", [0.1, 0.25, 0.5, 1, 2, 4, 7, 10], 1),
            Setting.named("WATER", OCEANS, OCEAN_NAMES, 0x001e0f),
            new Setting("EXPOSURE", [0.1, 0.2, 0.3, 0.4, 0.5, 0.65, 0.8, 1], 0.5),
        ]);
        const ocean = this.settings[OCEAN];
        ocean[0].decimals = 0;
        ocean[0].suffix = " DEG";
        ocean[1].decimals = 0;
        ocean[1].suffix = " DEG";
        ocean[1].wrap = true;
        ocean[5].decimals = 2;
        // Pool: as webgl_water's GUI (colour, scale, flowX, flowY), and
        // Water2's reflectivity and flow speed.
        this.settings.push([
            Setting.named("COLOUR", TINTS, TINT_NAMES, 0xffffff),
            new Setting("SCALE", [1, 2, 3, 4, 5, 6, 8, 10], 4),
            new Setting("FLOW X", [-1, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75, 1], 1),
            new Setting("FLOW Y", [-1, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75, 1], 1),
            new Setting("REFLECTIVITY", REFLECTIVITIES, 0.02),
            new Setting("FLOW SPEED", SPEEDS, 1),
        ]);
        const pool = this.settings[POOL];
        pool[1].decimals = 0;
        pool[2].decimals = 2;
        pool[3].decimals = 2;
        pool[4].decimals = 2;
        pool[5].decimals = 2;
        pool[5].suffix = "x";
        // Flow map: webgl_water_flowmap's "Show Flow Map", and the same.
        this.settings.push([
            Setting.toggle("FLOW MAP", false),
            Setting.named("COLOUR", TINTS, TINT_NAMES, 0xffffff),
            new Setting("SCALE", [1, 2, 3, 4, 6, 8], 2),
            new Setting("REFLECTIVITY", REFLECTIVITIES, 0.02),
            new Setting("FLOW SPEED", SPEEDS, 1),
        ]);
        const flow = this.settings[FLOW_MAP];
        flow[2].decimals = 0;
        flow[3].decimals = 2;
        flow[4].decimals = 2;
        flow[4].suffix = "x";
        // Mirrors: the reflectors' and the refractor's `color`, the glass's
        // ripples (its `time`).
        this.settings.push([
            Setting.named("MIRROR TINT", METALS, METAL_NAMES, 0xc1cbcb),
            Setting.toggle("GLASS", true),
            Setting.named("GLASS TINT", GLASSES, GLASS_NAMES, 0xcbcbcb),
            new Setting("RIPPLES", SPEEDS, 1),
        ]);
        this.settings[MIRRORS][3].decimals = 2;
        this.settings[MIRRORS][3].suffix = "x";
        // Tropical: the camera's pose, the water's colour and clarity (how
        // far one sees under it), the caustics, the ripples.
        this.settings.push([
            Setting.named("VIEW", [0, 1, 2, 3], VIEW_NAMES, 0),
            Setting.named("WATER", [0, 1, 2, 3, 4], LAGOON_NAMES, 0),
            new Setting("VISIBILITY", [4, 6, 9, 12, 16, 24, 36], 16),
            new Setting("CAUSTICS", [0, 0.5, 1, 1.5, 2, 3], 1.5),
            new Setting("WAVE SIZE", [0.5, 1, 2, 3, 5, 8], 2),
            new Setting("FLOW SPEED", SPEEDS, 1),
        ]);
        const tropical = this.settings[TROPICAL];
        tropical[2].decimals = 0;
        tropical[2].suffix = " M";
        tropical[3].decimals = 1;
        tropical[4].decimals = 1;
        tropical[4].suffix = " M";
        tropical[5].decimals = 2;
        tropical[5].suffix = "x";

        this.views.push(new View(new THREE.Vector3(30, 30, 100), new THREE.Vector3(0, 10, 0), 55, 1, 20000, 40, 200,
            Math.PI * 0.495));
        this.views.push(new View(new THREE.Vector3(-15, 7, 15), new THREE.Vector3(0, 0, 0), 45, 0.1, 200, 5, 50,
            Math.PI * 0.48));
        this.views.push(new View(new THREE.Vector3(0, 25, 0.01), new THREE.Vector3(0, 0, 0), 45, 0.1, 200, 5, 50,
            Math.PI * 0.48));
        this.views.push(new View(new THREE.Vector3(0, 75, 160), new THREE.Vector3(0, 40, 0), 45, 1, 500, 10, 400,
            Math.PI));
        // Tropical: VIEW's ABOVE; the camera can look up from under the water.
        const pose = new THREE.Vector3().setFromSphericalCoords(VIEW_POSES[2], THREE.MathUtils.degToRad(VIEW_POSES[1]), 0);
        this.views.push(new View(pose.add(new THREE.Vector3(0, VIEW_POSES[0], 0)), new THREE.Vector3(0, VIEW_POSES[0], 0),
            55, 0.1, 4000, 2, 70, Math.PI * 0.97));
        for (let i = 0; i < SCENE_COUNT; i++) {
            this.scenes.push(new THREE.Scene());
            this.built.push(false);
        }

        const controls = new OrbitControls(this.camera, this.renderer);
        this.controls = controls;

        const dc = context.dataContext();
        const vm = dc != null ? dc.viewModel() : null;
        if (vm != null) {
            this.sceneProperty = vm.getNumber("scene");
            this.commandProperty = vm.getNumber("command");
            this.rowsProperty = vm.getNumber("rows");
            this.collapsedProperty = vm.getNumber("collapsed");
            this.compactProperty = vm.getNumber("compact");
            this.panelWidthProperty = vm.getNumber("panelWidth");
            this.panelHeightProperty = vm.getNumber("panelHeight");
            this.toggleProperty = vm.getString("toggle");
            this.tabsHiddenProperty = vm.getNumber("tabsHidden");
            this.headingProperty = vm.getString("heading");
            this.infoProperty = vm.getString("info");
            for (let r = 0; r < ROW_COUNT; r++) {
                this.labelProperties.push(vm.getString("label" + r.toString()));
                this.valueProperties.push(vm.getString("value" + r.toString()));
            }
        }
        let start = OCEAN;
        const arg = context.arg("waterScene");
        if (arg != null) start = <i32>parseFloat(arg!);
        if (start < 0 || start >= SCENE_COUNT) start = OCEAN;
        const sp = this.sceneProperty;
        if (sp != null) sp.value = <f64>start;
        this.show(start);
        // `--arg waterView=N` starts Tropical at VIEW's pose N.
        const viewArg = context.arg("waterView");
        if (viewArg != null && start == TROPICAL) {
            const i = <i32>Math.min(VIEW_NAMES.length - 1, Math.max(0, parseFloat(viewArg!)));
            this.settings[TROPICAL][0].index = i;
            this.startView(i);
            this.ease(1000);
            this.writeValues();
        }
        this.setCollapsed(this.compact);
        return true;
    }

    override onResize(width: f64, height: f64): void {
        // A short stage has no caption, and hides the settings until SHOW.
        const compact = height > 0 && height < COMPACT_HEIGHT;
        if (compact == this.compact) return;
        this.compact = compact;
        const p = this.compactProperty;
        if (p != null) p.value = compact ? 1 : 0;
        if (!this.toggled) this.setCollapsed(compact);
        else this.writeHeading();
    }

    setCollapsed(collapsed: bool): void {
        this.collapsed = collapsed;
        const p = this.collapsedProperty;
        if (p != null) p.value = collapsed ? 1 : 0;
        const t = this.toggleProperty;
        if (t != null) t.value = collapsed ? "SHOW" : "HIDE";
        this.writeHeading();
    }

    /// The settings' title, and the tabs, which a compact stage drops
    /// while it shows the settings (the setup's name then heads them).
    writeHeading(): void {
        const hide = this.compact && !this.collapsed;
        const tabs = this.tabsHiddenProperty;
        if (tabs != null) tabs.value = hide ? 1 : 0;
        const heading = this.headingProperty;
        if (heading != null && this.current >= 0) heading.value = hide ? NAMES[this.current] : "SETTINGS";
    }

    // The panel is not the scene: presses on it do not orbit.
    override contains(x: f64, y: f64): bool {
        if (this.onPanel(x, y)) return false;
        return super.contains(x, y);
    }

    /// Whether `x, y` is on the panel (its laid-out size, which the panel
    /// writes to the view model).
    onPanel(x: f64, y: f64): bool {
        const w = this.panelWidthProperty, h = this.panelHeightProperty;
        if (w == null || h == null) return false;
        return x >= PANEL_INSET && y >= PANEL_INSET && x < PANEL_INSET + w.value && y < PANEL_INSET + h.value;
    }

    // Presses and moves on the panel are claimed too, so a drag there does
    // not scroll the page holding the example (the gallery; hit(true) lets
    // it scroll). The panel is above the script: its buttons still get the
    // clicks. Releases are left alone.
    override pointerDown(event: PointerEvent): void {
        if (this.onPanel(<f64>event.position.x, <f64>event.position.y)) event.hit();
        // A press on the scene takes the camera back from a VIEW move.
        else this.diving = false;
        super.pointerDown(event);
    }

    override pointerMove(event: PointerEvent): void {
        if (this.onPanel(<f64>event.position.x, <f64>event.position.y)) event.hit();
        super.pointerMove(event);
    }

    // ------------------------------------------------------------ setups

    buildOcean(scene: THREE.Scene): void {
        const loader = this.loader!;
        const waterNormals = loader.load("waternormals");
        waterNormals.wrapS = waterNormals.wrapT = THREE.RepeatWrapping;
        const water = new Water(new THREE.PlaneGeometry(10000, 10000), {
            textureWidth: 512, textureHeight: 512, waterNormals: waterNormals,
            sunDirection: new THREE.Vector3(), sunColor: 0xffffff, waterColor: 0x001e0f, distortionScale: 3.7,
        });
        water.rotation.x = -Math.PI / 2;
        scene.add(water);
        this.ocean = water;

        // The sky, and a copy for the environment (PMREMGenerator's
        // fromScene renders it at the start of the next render).
        this.sky.scale.setScalar(10000);
        scene.add(this.sky);
        this.envSky.scale.setScalar(10000);
        this.envScene.add(this.envSky);
        const skies: StaticArray<Sky> = [this.sky, this.envSky];
        for (let i = 0; i < 2; i++) {
            const m = skies[i].shaderMaterial;
            m.uniform<f64>("turbidity").value = 10;
            m.uniform<f64>("rayleigh").value = 2;
            m.uniform<f64>("mieCoefficient").value = 0.005;
            m.uniform<f64>("mieDirectionalG").value = 0.8;
        }

        this.cube = new THREE.Mesh(new THREE.BoxGeometry(30, 30, 30), new THREE.MeshStandardMaterial({ roughness: 0 }));
        scene.add(this.cube);
    }

    buildPool(scene: THREE.Scene): void {
        const loader = this.loader!;
        this.knot = new THREE.Mesh(new THREE.TorusKnotGeometry(3, 1, 256, 32), new THREE.MeshNormalMaterial());
        this.knot.position.y = 4;
        this.knot.scale.set(0.5, 0.5, 0.5);
        scene.add(this.knot);

        // three.js's hardwood floor, drawn here.
        const ground = new THREE.Mesh(new THREE.PlaneGeometry(20, 20),
            new THREE.MeshStandardMaterial({ roughness: 0.8, metalness: 0.4, map: planks(256) }));
        ground.rotation.x = Math.PI * -0.5;
        scene.add(ground);

        const water = new Water2(new THREE.PlaneGeometry(20, 20), {
            color: 0xffffff, scale: 4, flowDirection: new THREE.Vector2(1, 1).normalize(),
            textureWidth: 1024, textureHeight: 1024,
            normalMap0: loader.load("Water_1_M_Normal"), normalMap1: loader.load("Water_2_M_Normal"),
        });
        water.position.y = 1;
        water.rotation.x = Math.PI * -0.5;
        scene.add(water);
        this.pool = water;

        // A Preetham sky in place of three.js's Park2 cube map.
        const sky = new Sky();
        sky.scale.setScalar(150);
        const m = sky.shaderMaterial;
        m.uniform<f64>("turbidity").value = 2;
        m.uniform<f64>("rayleigh").value = 2.5;
        m.uniform<THREE.Vector3>("sunPosition").value.setFromSphericalCoords(1, THREE.MathUtils.degToRad(60),
            THREE.MathUtils.degToRad(-135));
        scene.add(sky);

        scene.add(new THREE.AmbientLight(0xe7e7e7, 1.2));
        const light = new THREE.DirectionalLight(0xffffff, 2);
        light.position.set(-1, 1, 1);
        scene.add(light);
    }

    buildFlowMap(scene: THREE.Scene): void {
        const loader = this.loader!;
        scene.background = new THREE.Color(0x0b0d12);
        const ground = new THREE.Mesh(new THREE.PlaneGeometry(20, 20, 10, 10),
            new THREE.MeshBasicMaterial({ color: 0xe7e7e7, map: checker(256, 8) }));
        ground.rotation.x = Math.PI * -0.5;
        scene.add(ground);

        const flowMap = loader.load("Water_1_M_Flow");
        const water = new Water2(new THREE.PlaneGeometry(20, 20), {
            scale: 2, textureWidth: 1024, textureHeight: 1024, flowMap: flowMap,
            normalMap0: loader.load("Water_1_M_Normal"), normalMap1: loader.load("Water_2_M_Normal"),
        });
        water.position.y = 1;
        water.rotation.x = Math.PI * -0.5;
        scene.add(water);
        this.stream = water;

        // The flow map helper.
        this.flowHelper = new THREE.Mesh(new THREE.PlaneGeometry(20, 20), new THREE.MeshBasicMaterial({ map: flowMap }));
        this.flowHelper.position.y = 1.01;
        this.flowHelper.rotation.x = Math.PI * -0.5;
        this.flowHelper.visible = false;
        scene.add(this.flowHelper);
    }

    buildMirrors(scene: THREE.Scene): void {
        const loader = this.loader!;
        // webgl_mirror's room: a round mirror on the floor, a mirror for
        // the back wall, a half sphere and a flying icosahedron.
        const ground = new Reflector(new THREE.CircleGeometry(40, 64), {
            clipBias: 0.003, textureWidth: 1024, textureHeight: 1024, color: 0xc1cbcb,
        });
        ground.position.y = 0.5;
        ground.rotateX(-Math.PI / 2);
        scene.add(ground);
        this.groundMirror = ground;
        const wall = new Reflector(new THREE.PlaneGeometry(100, 100), {
            clipBias: 0.003, textureWidth: 1024, textureHeight: 1024, color: 0xc1cbcb,
        });
        wall.position.y = 50;
        wall.position.z = -50;
        scene.add(wall);
        this.wallMirror = wall;

        const white = new THREE.MeshPhongMaterial({ color: 0xffffff, emissive: 0x8d8d8d });
        const cap = new THREE.Mesh(new THREE.CylinderGeometry(0.1, 15 * Math.cos(Math.PI / 180 * 30), 0.1, 24, 1), white);
        cap.position.y = -15 * Math.sin(Math.PI / 180 * 30) - 0.05;
        cap.rotateX(-Math.PI);
        const half = new THREE.Mesh(new THREE.SphereGeometry(15, 24, 24, Math.PI / 2, Math.PI * 2, 0,
            Math.PI / 180 * 120), white);
        half.add(cap);
        half.rotateX(-Math.PI / 180 * 135);
        half.rotateZ(-Math.PI / 180 * 20);
        half.position.y = 7.5 + 15 * Math.sin(Math.PI / 180 * 30);
        this.sphereGroup.add(half);
        scene.add(this.sphereGroup);
        this.smallSphere = new THREE.Mesh(new THREE.IcosahedronGeometry(5, 0),
            new THREE.MeshPhongMaterial({ color: 0xffffff, emissive: 0x7b7b7b, flatShading: true }));
        scene.add(this.smallSphere);

        // The walls.
        const planeGeo = new THREE.PlaneGeometry(100.1, 100.1);
        const top = new THREE.Mesh(planeGeo, new THREE.MeshPhongMaterial({ color: 0xffffff }));
        top.position.y = 100;
        top.rotateX(Math.PI / 2);
        scene.add(top);
        const bottom = new THREE.Mesh(planeGeo, new THREE.MeshPhongMaterial({ color: 0xffffff }));
        bottom.rotateX(-Math.PI / 2);
        scene.add(bottom);
        const front = new THREE.Mesh(planeGeo, new THREE.MeshPhongMaterial({ color: 0x7f7fff }));
        front.position.z = 50;
        front.position.y = 50;
        front.rotateY(Math.PI);
        scene.add(front);
        const right = new THREE.Mesh(planeGeo, new THREE.MeshPhongMaterial({ color: 0x00ff00 }));
        right.position.x = 50;
        right.position.y = 50;
        right.rotateY(-Math.PI / 2);
        scene.add(right);
        const left = new THREE.Mesh(planeGeo, new THREE.MeshPhongMaterial({ color: 0xff0000 }));
        left.position.x = -50;
        left.position.y = 50;
        left.rotateY(Math.PI / 2);
        scene.add(left);

        // The lights.
        const main = new THREE.PointLight(0xe7e7e7, 2.5, 250, 0);
        main.position.y = 60;
        scene.add(main);
        const green = new THREE.PointLight(0x00ff00, 0.5, 1000, 0);
        green.position.set(550, 50, 0);
        scene.add(green);
        const red = new THREE.PointLight(0xff0000, 0.5, 1000, 0);
        red.position.set(-550, 50, 0);
        scene.add(red);
        const blue = new THREE.PointLight(0xbbbbfe, 0.5, 1000, 0);
        blue.position.set(0, 50, 550);
        scene.add(blue);

        // webgl_refraction's rippled glass, smaller, in front of the half
        // sphere; on the main camera's layer only.
        const glass = new Refractor(new THREE.PlaneGeometry(40, 40), {
            color: 0xcbcbcb, textureWidth: 1024, textureHeight: 1024, shader: WaterRefractionShader,
        });
        const dudv = loader.load("waterdudv");
        dudv.wrapS = dudv.wrapT = THREE.RepeatWrapping;
        (glass.material as THREE.ShaderMaterial).uniform<THREE.Texture>("tDudv").value = dudv;
        glass.position.set(14, 22, 26);
        glass.rotation.y = -0.35;
        glass.layers.set(MAIN_ONLY_LAYER);
        scene.add(glass);
        this.glass = glass;
    }

    /// A seabed.wgsl material: its own colour and kind (0 the floor, 1
    /// smooth, 2 flat shaded, 3 the sky dome), the shared uniforms.
    seabedMaterial(kind: f64, color: u32): THREE.ShaderMaterial {
        return this.seabedUniforms(new THREE.ShaderMaterial({ shader: "examples/water/seabed" }), kind, color);
    }

    seabedUniforms(m: THREE.ShaderMaterial, kind: f64, color: u32): THREE.ShaderMaterial {
        m.uniforms.set("albedo", new THREE.Uniform<THREE.Color>(new THREE.Color(<f64>color)));
        m.uniforms.set("kind", new THREE.Uniform<f64>(kind));
        m.uniforms.set("sunDirection", this.sunDirection);
        m.uniforms.set("time", this.seaTime);
        m.uniforms.set("absorption", this.absorption);
        m.uniforms.set("caustics", this.caustics);
        m.uniforms.set("scatter", this.scatter);
        m.uniforms.set("waterLevel", this.waterLevel);
        m.uniforms.set("sunColor", this.sunColor);
        m.uniforms.set("wobble", this.wobble);
        m.uniforms.set("ambient", this.ambient);
        return m;
    }

    buildTropical(scene: THREE.Scene): void {
        const loader = this.loader!;
        const rng = new Rng(7);

        // The floor: a height field 200 m across, the open sea's floor
        // around it, and the sky.
        const floorMaterial = this.seabedMaterial(0, 0xffffff);
        const ground = new THREE.PlaneGeometry(200, 200, 128, 128);
        ground.rotateX(-Math.PI / 2);
        const position = ground.getAttribute("position")!;
        for (let i = 0; i < position.count; i++) position.setY(i, lagoonHeight(position.getX(i), position.getZ(i)));
        ground.computeVertexNormals();
        scene.add(new THREE.Mesh(ground, floorMaterial));
        const sea = new THREE.Mesh(new THREE.PlaneGeometry(4000, 4000), floorMaterial);
        sea.rotation.x = -Math.PI / 2;
        sea.position.y = -30.3;
        scene.add(sea);
        const domeMaterial = this.seabedMaterial(3, 0xffffff);
        domeMaterial.side = THREE.BackSide;
        this.dome = new THREE.Mesh(new THREE.SphereGeometry(1900, 32, 16), domeMaterial);
        scene.add(this.dome);

        // The surface from above: Water2 with lagoon.wgsl, and from below.
        const n0 = loader.load("Water_1_M_Normal");
        const n1 = loader.load("Water_2_M_Normal");
        const water = new Water2(new THREE.PlaneGeometry(3600, 3600), {
            color: 0xffffff, reflectivity: 0.03, textureWidth: 1024, textureHeight: 1024,
            shader: new LagoonShader(this.sunDirection, this.flowTime, this.sunColor, this.waveSize),
            normalMap0: n0, normalMap1: n1, flowDirection: this.flowDirection.value,
        });
        water.rotation.x = -Math.PI / 2;
        water.position.y = WATER_LEVEL;
        scene.add(water);
        this.lagoon = water;
        const below = new THREE.ShaderMaterial({ shader: "examples/water/undersurface" });
        below.uniforms.set("flowDirection", this.flowDirection);
        below.uniforms.set("waveSize", this.waveSize);
        below.uniforms.set("time", this.flowTime);
        below.uniforms.set("sunDirection", this.sunDirection);
        below.uniforms.set("wobble", this.wobble);
        below.uniforms.set("absorption", this.absorption);
        below.uniforms.set("waterLevel", this.waterLevel);
        below.uniforms.set("scatter", this.scatter);
        below.uniforms.set("sunColor", this.sunColor);
        below.uniforms.set("tNormalMap0", new THREE.Uniform<THREE.Texture>(n0));
        below.uniforms.set("tNormalMap1", new THREE.Uniform<THREE.Texture>(n1));
        this.underside = new THREE.Mesh(new THREE.PlaneGeometry(3600, 3600), below);
        this.underside.rotation.x = Math.PI / 2;
        this.underside.position.y = WATER_LEVEL;
        scene.add(this.underside);

        // The props are placed in a holder, then merged into a mesh per
        // material (a few draws, in each of Water2's renders).
        const holder = new THREE.Object3D();

        // Rocks: icosahedra dented by a few waves, flat shaded.
        const rocks: Array<THREE.BufferGeometry> = [];
        for (let i = 0; i < 18; i++) {
            const geometry = new THREE.IcosahedronGeometry(1, 1);
            const p = geometry.getAttribute("position")!;
            const seed = <f64>i * 1.7;
            for (let k = 0; k < p.count; k++) {
                const x = p.getX(k), y = p.getY(k), z = p.getZ(k);
                const f = 1 + 0.22 * Math.sin(x * 3.1 + seed) * Math.cos(y * 2.7 + seed * 1.3)
                    + 0.12 * Math.sin(z * 5 + seed * 2);
                p.setXYZ(k, x * f, y * f, z * f);
            }
            const r = rng.range(0.5, 1.6);
            const a = rng.range(0, Math.PI * 2);
            const d = i < 6 ? rng.range(57, 63) : rng.range(7, 50);
            const x = Math.cos(a) * d, z = Math.sin(a) * d;
            holder.scale.set(r * rng.range(1, 1.5), r * rng.range(0.5, 0.8), r);
            holder.rotation.set(0, rng.range(0, Math.PI), 0);
            holder.position.set(x, lagoonHeight(x, z) - r * 0.2, z);
            holder.updateMatrix();
            rocks.push(geometry.applyMatrix4(holder.matrix));
        }
        const rockGeometry = mergeGeometries(rocks)!;
        rockGeometry.computeVertexNormals();
        scene.add(new THREE.Mesh(rockGeometry, this.seabedMaterial(2, 0x8b8372)));

        // Coral: brain domes, branches and tables, in clumps, one mesh a colour.
        const corals: StaticArray<u32> = [0xff6f7d, 0xff9a3c, 0xa46be0, 0xf2d64b, 0x4fd1c5];
        const coral: Array<Array<THREE.BufferGeometry>> = [];
        for (let i = 0; i < corals.length; i++) coral.push([]);
        const brain = new THREE.SphereGeometry(0.7, 14, 10);
        const branch = new THREE.ConeGeometry(0.08, 1.3, 6);
        branch.translate(0, 0.65, 0);
        const table = new THREE.CylinderGeometry(1, 0.8, 0.12, 18);
        const stem = new THREE.CylinderGeometry(0.1, 0.16, 0.7, 8);
        const part = new THREE.Object3D();
        holder.add(part);
        for (let i = 0; i < 30; i++) {
            const a = rng.range(0, Math.PI * 2);
            const d = i < 12 ? rng.range(54, 62) : rng.range(5, 48);
            const x = Math.cos(a) * d, z = Math.sin(a) * d;
            const into = coral[i % corals.length];
            const kind = i % 3;
            holder.position.set(x, lagoonHeight(x, z), z);
            holder.rotation.set(0, rng.range(0, Math.PI * 2), 0);
            const s = rng.range(0.7, 1.4);
            holder.scale.set(s, s, s);
            if (kind == 0) {
                part.position.set(0, -0.08, 0);
                part.rotation.set(0, 0, 0);
                part.scale.set(1, 0.62, 1);
                holder.updateMatrixWorld(true);
                into.push(brain.clone().applyMatrix4(part.matrixWorld));
            } else if (kind == 1) {
                part.scale.set(1, 1, 1);
                for (let b = 0; b < 7; b++) {
                    part.position.set(rng.range(-0.35, 0.35), 0, rng.range(-0.35, 0.35));
                    part.rotation.set(rng.range(-0.6, 0.6), 0, rng.range(-0.6, 0.6));
                    holder.updateMatrixWorld(true);
                    into.push(branch.clone().applyMatrix4(part.matrixWorld));
                }
            } else {
                part.rotation.set(0, 0, 0);
                part.scale.set(1, 1, 1);
                part.position.set(0, 0.72, 0);
                holder.updateMatrixWorld(true);
                into.push(table.clone().applyMatrix4(part.matrixWorld));
                part.position.set(0, 0.35, 0);
                holder.updateMatrixWorld(true);
                into.push(stem.clone().applyMatrix4(part.matrixWorld));
            }
        }
        for (let i = 0; i < corals.length; i++) {
            if (coral[i].length > 0) scene.add(new THREE.Mesh(mergeGeometries(coral[i])!, this.seabedMaterial(1, corals[i])));
        }

        // Fish: a body and a tail (one geometry), swimming rings around
        // the middle.
        const body = new THREE.SphereGeometry(1, 12, 8);
        body.scale(0.3, 0.13, 0.06);
        const tail = new THREE.ConeGeometry(0.12, 0.18, 4);
        tail.rotateZ(-Math.PI / 2);
        tail.scale(1, 1.3, 0.35);
        tail.translate(-0.36, 0, 0);
        const fishGeometry = mergeGeometries([body, tail])!;
        const fishMaterials: Array<THREE.ShaderMaterial> = [
            this.seabedMaterial(1, 0xffd23f), this.seabedMaterial(1, 0x3f9bff), this.seabedMaterial(1, 0xff7a2f),
        ];
        for (let i = 0; i < 18; i++) {
            const fish = new THREE.Mesh(fishGeometry, fishMaterials[i % 3]);
            // Its ring's radius and height, its phase and speed on it.
            this.fishPaths.push(rng.range(3.5, 7));
            this.fishPaths.push(rng.range(-4.2, -2.2));
            this.fishPaths.push(rng.range(0, Math.PI * 2));
            this.fishPaths.push(rng.range(0.25, 0.45));
            this.fish.push(fish);
            scene.add(fish);
        }

        // Light shafts under the water, from the surface down along the
        // refracted sun (Snell: sin of the angle from vertical / 1.333).
        const sun = this.sunDirection.value;
        const horizontal = Math.sqrt(sun.x * sun.x + sun.z * sun.z);
        const sinT = horizontal / 1.333;
        const cosT = Math.sqrt(1 - sinT * sinT);
        this.shaftAxis.set(sun.x / horizontal * sinT, cosT, sun.z / horizontal * sinT);
        const shaftMaterial = this.seabedUniforms(new THREE.ShaderMaterial({
            shader: "examples/water/seabed", fragmentEntryPoint: "fs_shaft", transparent: true,
            blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide,
        }), 1, 0xffffff);
        const shaft = new THREE.PlaneGeometry(1.6, 14);
        shaft.translate(0, -7, 0);
        for (let i = 0; i < 14; i++) {
            const m = new THREE.Mesh(shaft, shaftMaterial);
            m.position.set(rng.range(-22, 18), WATER_LEVEL, rng.range(-18, 22));
            m.scale.set(rng.range(0.6, 1.6), 1, 1);
            this.shafts.add(m);
        }
        scene.add(this.shafts);

        // Above the water: palms on the island, lit by the sun and the sky.
        const sunLight = new THREE.DirectionalLight(0xfff2dc, 2.4);
        sunLight.position.copy(this.sunDirection.value).multiplyScalar(100);
        scene.add(sunLight);
        scene.add(new THREE.HemisphereLight(0xcfe8ff, 0x9a8a60, 1.1));
        const frond = new THREE.ConeGeometry(0.42, 3.2, 4);
        frond.rotateZ(-Math.PI / 2);
        frond.translate(1.6, 0, 0);
        const coconut = new THREE.SphereGeometry(0.16, 8, 6);
        const trunks: Array<THREE.BufferGeometry> = [];
        const fronds: Array<THREE.BufferGeometry> = [];
        const nuts: Array<THREE.BufferGeometry> = [];
        // x, z, height, lean bearing
        const palms: StaticArray<f64> = [14, -29, 7.5, 0.6, 19, -32, 6, -2.2, 11.5, -33.5, 6.8, 2.6];
        holder.rotation.set(0, 0, 0);
        holder.scale.set(1, 1, 1);
        for (let i = 0; i < palms.length / 4; i++) {
            const x = palms[i * 4], z = palms[i * 4 + 1], height = palms[i * 4 + 2], yaw = palms[i * 4 + 3];
            const base = new THREE.Vector3(x, lagoonHeight(x, z) - 0.2, z);
            const points: Array<THREE.Vector3> = [];
            for (let k = 0; k <= 4; k++) {
                const t = <f64>k / 4;
                points.push(new THREE.Vector3(base.x + Math.cos(yaw) * 2.2 * t * t, base.y + height * t,
                    base.z - Math.sin(yaw) * 2.2 * t * t));
            }
            trunks.push(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(points), 12, 0.17, 7, false));
            const crown = points[4];
            holder.position.copy(crown);
            part.position.set(0, 0, 0);
            part.scale.set(1, 0.16, 1);
            for (let f = 0; f < 8; f++) {
                part.rotation.set(0, <f64>f * Math.PI * 2 / 8 + rng.range(-0.2, 0.2), -0.15 - rng.range(0, 0.5));
                holder.updateMatrixWorld(true);
                fronds.push(frond.clone().applyMatrix4(part.matrixWorld));
            }
            for (let c = 0; c < 3; c++) {
                const a = <f64>c * 2.1 + <f64>i;
                nuts.push(coconut.clone().translate(crown.x + Math.cos(a) * 0.22, crown.y - 0.2, crown.z + Math.sin(a) * 0.22));
            }
        }
        this.above.add(new THREE.Mesh(mergeGeometries(trunks)!,
            new THREE.MeshStandardMaterial({ color: 0x8a6a45, roughness: 0.9 })));
        this.above.add(new THREE.Mesh(mergeGeometries(fronds)!,
            new THREE.MeshStandardMaterial({ color: 0x3f8a2a, roughness: 0.7, side: THREE.DoubleSide })));
        this.above.add(new THREE.Mesh(mergeGeometries(nuts)!,
            new THREE.MeshStandardMaterial({ color: 0x5a3d1e, roughness: 0.6 })));
        scene.add(this.above);
        this.setUnder(false);
    }

    // ------------------------------------------------------------ panel

    /// Shows setup `s`, building it the first time, and its view.
    show(s: i32): void {
        const camera = this.camera as THREE.PerspectiveCamera;
        const controls = this.controls as OrbitControls;
        const old = this.current;
        if (old >= 0) {
            this.views[old].position.copy(camera.position);
            this.views[old].target.copy(controls.target);
        }
        const scene = this.scenes[s];
        if (!this.built[s]) {
            if (s == OCEAN) this.buildOcean(scene);
            else if (s == POOL) this.buildPool(scene);
            else if (s == FLOW_MAP) this.buildFlowMap(scene);
            else if (s == MIRRORS) this.buildMirrors(scene);
            else this.buildTropical(scene);
            this.built[s] = true;
        }
        this.current = s;
        this.scene = scene;
        const view = this.views[s];
        camera.fov = view.fov;
        camera.near = view.near;
        camera.far = view.far;
        camera.position.copy(view.position);
        camera.updateProjectionMatrix();
        controls.target.copy(view.target);
        controls.minDistance = view.minDistance;
        controls.maxDistance = view.maxDistance;
        controls.maxPolarAngle = view.maxPolarAngle;
        controls.update();
        this.diving = false;
        this.lastCameraY = camera.position.y;
        const renderer = this.renderer!;
        renderer.toneMapping = s == OCEAN || s == POOL ? THREE.ACESFilmicToneMapping : THREE.NoToneMapping;
        renderer.toneMappingExposure = s == POOL ? 0.45 : 1;
        this.apply();
        const rows = this.rowsProperty;
        if (rows != null) rows.value = <f64>this.settings[s].length;
        const info = this.infoProperty;
        if (info != null) info.value = INFO[s];
        this.writeHeading();
        for (let r = 0; r < ROW_COUNT; r++) {
            const label = this.labelProperties.length > r ? this.labelProperties[r] : null;
            if (label != null) label.value = r < this.settings[s].length ? this.settings[s][r].label : "";
        }
        this.writeValues();
    }

    writeValues(): void {
        const settings = this.settings[this.current];
        for (let r = 0; r < ROW_COUNT; r++) {
            const value = this.valueProperties.length > r ? this.valueProperties[r] : null;
            if (value != null) value.value = r < settings.length ? settings[r].text() : "";
        }
    }

    /// The current setup's settings, onto its objects.
    apply(): void {
        const s = this.current;
        const v = this.settings[s];
        if (s == OCEAN) {
            const water = this.ocean!.shaderMaterial;
            if (v[0].value != this.sunElevation || v[1].value != this.sunAzimuth) this.updateSun(v[0].value, v[1].value);
            water.uniform<f64>("distortionScale").value = v[2].value;
            water.uniform<f64>("size").value = v[3].value;
            water.uniform<THREE.Color>("waterColor").value.setHex(<u32>v[4].value);
            this.renderer!.toneMappingExposure = v[5].value;
        } else if (s == POOL) {
            const m = this.pool!.shaderMaterial;
            m.uniform<THREE.Color>("color").value.setHex(<u32>v[0].value);
            m.uniform<THREE.Vector4>("config").value.w = v[1].value;
            // webgl_water: the direction is normalized (zero stays still).
            m.uniform<THREE.Vector2>("flowDirection").value.set(v[2].value, v[3].value).normalize();
            m.uniform<f64>("reflectivity").value = v[4].value;
        } else if (s == FLOW_MAP) {
            this.flowHelper.visible = v[0].on;
            const m = this.stream!.shaderMaterial;
            m.uniform<THREE.Color>("color").value.setHex(<u32>v[1].value);
            m.uniform<THREE.Vector4>("config").value.w = v[2].value;
            m.uniform<f64>("reflectivity").value = v[3].value;
        } else if (s == TROPICAL) {
            // VIEW (row 0) is read by readPanel. Absorption: red is down to
            // 5% after VISIBILITY metres, green and blue (the preset's
            // ratios) three to six times farther.
            const w = <i32>v[1].value;
            this.waterColor.setHex(LAGOON_SCATTER[w]);
            this.scatter.value.copy(this.waterColor);
            const k = 3 / v[2].value;
            this.absorption.value.set(LAGOON_ABSORB[w * 3] * k, LAGOON_ABSORB[w * 3 + 1] * k, LAGOON_ABSORB[w * 3 + 2] * k);
            this.caustics.value = v[3].value;
            this.waveSize.value = v[4].value;
        } else {
            const tint = <u32>v[0].value;
            (this.groundMirror!.material as THREE.ShaderMaterial).uniform<THREE.Color>("color").value.setHex(tint);
            (this.wallMirror!.material as THREE.ShaderMaterial).uniform<THREE.Color>("color").value.setHex(tint);
            const glass = this.glass!;
            glass.visible = v[1].on;
            (glass.material as THREE.ShaderMaterial).uniform<THREE.Color>("color").value.setHex(<u32>v[2].value);
        }
    }

    /// The sun from elevation and azimuth: the skies, the water's sun and
    /// a new environment (webgl_shaders_ocean's updateSun).
    updateSun(elevation: f64, azimuth: f64): void {
        this.sunElevation = elevation;
        this.sunAzimuth = azimuth;
        const phi = THREE.MathUtils.degToRad(90 - elevation);
        const theta = THREE.MathUtils.degToRad(azimuth);
        this.sun.setFromSphericalCoords(1, phi, theta);
        this.sky.shaderMaterial.uniform<THREE.Vector3>("sunPosition").value.copy(this.sun);
        this.envSky.shaderMaterial.uniform<THREE.Vector3>("sunPosition").value.copy(this.sun);
        this.ocean!.shaderMaterial.uniform<THREE.Vector3>("sunDirection").value.copy(this.sun).normalize();
        const previous = this.environment;
        if (previous != null) previous.dispose();
        const env = this.pmrem.fromScene(this.envScene);
        this.environment = env;
        this.scenes[OCEAN].environment = env.texture;
    }

    /// The panel's writes: a picked tab, a "-" / "+" press.
    readPanel(): void {
        const sp = this.sceneProperty;
        if (sp != null) {
            let s = <i32>Math.round(sp.value);
            if (s < 0 || s >= SCENE_COUNT) s = OCEAN;
            if (s != this.current) this.show(s);
        }
        const cp = this.commandProperty;
        if (cp == null) return;
        const command = <i32>Math.round(cp.value);
        if (command <= 0) return;
        cp.value = 0;
        if (command == TOGGLE_COMMAND) {
            this.toggled = true;
            this.setCollapsed(!this.collapsed);
            return;
        }
        const row = (command - 1) / 2;
        const delta = (command - 1) % 2 == 0 ? -1 : 1;
        const settings = this.settings[this.current];
        if (row >= settings.length || !settings[row].step(delta)) return;
        this.apply();
        this.writeValues();
        if (this.current == TROPICAL && row == 0) this.startView(<i32>settings[0].value);
    }

    // ------------------------------------------------------------ Tropical camera

    /// Eases the camera to VIEW's pose `i` (target height, polar angle,
    /// distance), keeping its bearing; the target goes back over the middle.
    startView(i: i32): void {
        this.diveTarget = VIEW_POSES[i * 3];
        this.divePolar = THREE.MathUtils.degToRad(VIEW_POSES[i * 3 + 1]);
        this.diveDistance = VIEW_POSES[i * 3 + 2];
        this.diving = true;
    }

    ease(seconds: f64): void {
        const controls = this.controls as OrbitControls;
        const camera = this.camera;
        const target = controls.target;
        const k = 1 - Math.exp(-seconds * 2.5);
        const s = this.spherical.setFromVector3(this.offset.copy(camera.position).sub(target));
        const dy = this.diveTarget - target.y, dphi = this.divePolar - s.phi, dr = this.diveDistance - s.radius;
        target.set(target.x - target.x * k, target.y + dy * k, target.z - target.z * k);
        s.phi += dphi * k;
        s.radius += dr * k;
        s.makeSafe();
        camera.position.copy(target).add(this.offset.setFromSpherical(s));
        if (Math.abs(dy) < 0.002 && Math.abs(dphi) < 0.0005 && Math.abs(dr) < 0.005
            && Math.abs(target.x) + Math.abs(target.z) < 0.005) this.diving = false;
    }

    /// Before each render: keeps the camera out of the sand and out of the
    /// band around the surface (past it, on the side it was heading for),
    /// and shows what that side sees.
    placeCamera(): void {
        const camera = this.camera;
        const p = camera.position;
        const floor = lagoonHeight(p.x, p.z) + FLOOR_CLEARANCE;
        if (p.y < floor) p.y = floor;
        if (Math.abs(p.y - WATER_LEVEL) < DEAD_BAND) {
            let side: f64 = this.under ? -1 : 1;
            if (p.y > this.lastCameraY + 1e-6) side = 1;
            else if (p.y < this.lastCameraY - 1e-6) side = -1;
            p.y = WATER_LEVEL + side * DEAD_BAND;
        }
        camera.lookAt((this.controls as OrbitControls).target);
        this.lastCameraY = p.y;
        const under = p.y < WATER_LEVEL;
        if (under != this.under) this.setUnder(under);
        if (under) this.turnShafts();
    }

    /// Under the water: the surface from below, no sky (the water's colour
    /// instead), a swaying view; above it: Water2, the sky, the palms.
    setUnder(under: bool): void {
        this.under = under;
        this.lagoon!.visible = !under;
        this.underside.visible = under;
        this.dome.visible = !under;
        this.above.visible = !under;
        this.shafts.visible = under;
        this.wobble.value = under ? 1 : 0;
        this.scenes[TROPICAL].background = under ? this.waterColor : null;
    }

    /// Turns each light shaft about its axis to face the camera.
    turnShafts(): void {
        const a = this.shaftAxis;
        const shafts = this.shafts.children;
        for (let i = 0; i < shafts.length; i++) {
            const m = shafts[i];
            const n = this.axisZ.copy(this.camera.position).sub(m.position);
            n.addScaledVector(a, -n.dot(a));
            if (n.lengthSq() < 1e-8) continue;
            n.normalize();
            this.axisX.crossVectors(a, n);
            m.quaternion.setFromRotationMatrix(this.basis.makeBasis(this.axisX, a, n));
        }
    }

    override renderFrame(): void {
        if (this.current == TROPICAL) this.placeCamera();
        super.renderFrame();
    }

    // ------------------------------------------------------------ frames

    override animate(seconds: f64): void {
        this.readPanel();
        const t = (this.time += seconds);
        const s = this.current;
        const v = this.settings[s];
        if (s == OCEAN) {
            // webgl_shaders_ocean's render().
            this.cube.position.y = Math.sin(t) * 20 + 5;
            this.cube.rotation.x = t * 0.5;
            this.cube.rotation.z = t * 0.51;
            this.ocean!.shaderMaterial.uniform<f64>("time").value += seconds;
        } else if (s == POOL) {
            this.knot.rotation.x += seconds;
            this.knot.rotation.y += seconds * 0.5;
            this.pool!.tick(seconds * v[5].value);
        } else if (s == FLOW_MAP) {
            this.stream!.tick(seconds * v[4].value);
        } else if (s == TROPICAL) {
            this.seaTime.value += seconds;
            this.flowTime.value += seconds * v[5].value;
            for (let i = 0; i < this.fish.length; i++) {
                const radius = this.fishPaths[i * 4], height = this.fishPaths[i * 4 + 1];
                const phase = this.fishPaths[i * 4 + 2], speed = this.fishPaths[i * 4 + 3];
                const a = t * speed + phase;
                const fish = this.fish[i];
                fish.position.set(-4 + Math.cos(a) * radius, height + Math.sin(t * 1.7 + phase) * 0.15,
                    4 + Math.sin(a) * radius);
                // Along the ring (counterclockwise from above), the tail wagging.
                fish.rotation.y = -a - Math.PI / 2 + Math.sin(t * 9 + phase) * 0.08;
            }
            if (this.diving) this.ease(seconds);
        } else {
            // webgl_mirror's animate (its timer, Date.now() * 0.01, is
            // 10 t), and webgl_refraction's time.
            const timer = t * 10;
            this.sphereGroup.rotation.y -= 0.12 * seconds;
            this.smallSphere.position.set(Math.cos(timer * 0.1) * 30, Math.abs(Math.cos(timer * 0.2)) * 20 + 5,
                Math.sin(timer * 0.1) * 30);
            this.smallSphere.rotation.y = Math.PI / 2 - timer * 0.1;
            this.smallSphere.rotation.z = timer * 0.8;
            this.glassTime += seconds * v[3].value;
            (this.glass!.material as THREE.ShaderMaterial).uniform<f64>("time").value = this.glassTime;
        }
    }
}
