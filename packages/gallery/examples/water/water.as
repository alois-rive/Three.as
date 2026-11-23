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
// `--arg waterScene=N` starts on setup N (for --bench and screenshots).

import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";
import { Water } from "lib:threeas/three/addons/objects/Water";
import { Water as Water2 } from "lib:threeas/three/addons/objects/Water2";
import { Sky } from "lib:threeas/three/addons/objects/Sky";
import { Reflector } from "lib:threeas/three/addons/objects/Reflector";
import { Refractor } from "lib:threeas/three/addons/objects/Refractor";
import { WaterRefractionShader } from "lib:threeas/three/addons/shaders/WaterRefractionShader";
import { Context } from "rive/host";
import { PropertyNumber, PropertyString } from "rive/data";
import { PointerEvent } from "rive/events";

// The setups, in the panel's tab order.
const OCEAN = 0;
const POOL = 1;
const FLOW_MAP = 2;
const MIRRORS = 3;
const SCENE_COUNT = 4;
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

const NAMES: StaticArray<string> = ["OCEAN", "POOL", "FLOW MAP", "MIRRORS"];
const INFO: StaticArray<string> = [
    "Water (webgl_shaders_ocean): a rippled mirror under a Preetham Sky, which also lights the cube.",
    "Water2 (webgl_water): reflection and refraction mixed by Fresnel, two normal maps flowing one way.",
    "Water2 with a flow map (webgl_water_flowmap): the water follows the map's red and green.",
    "Reflector mirrors reflecting each other (webgl_mirror), and rippled glass: a Refractor (webgl_refraction).",
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

        this.views.push(new View(new THREE.Vector3(30, 30, 100), new THREE.Vector3(0, 10, 0), 55, 1, 20000, 40, 200,
            Math.PI * 0.495));
        this.views.push(new View(new THREE.Vector3(-15, 7, 15), new THREE.Vector3(0, 0, 0), 45, 0.1, 200, 5, 50,
            Math.PI * 0.48));
        this.views.push(new View(new THREE.Vector3(0, 25, 0.01), new THREE.Vector3(0, 0, 0), 45, 0.1, 200, 5, 50,
            Math.PI * 0.48));
        this.views.push(new View(new THREE.Vector3(0, 75, 160), new THREE.Vector3(0, 40, 0), 45, 1, 500, 10, 400,
            Math.PI));
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
            else this.buildMirrors(scene);
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
