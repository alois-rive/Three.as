// Effects: one scene through every post-processing pass, picked from a Rive
// panel (examples.rml's EffectsStage, made by tools/make_effects_ui.py).
// A click writes the EffectsPicker view model's `pass`; this script reads
// it, builds that pass's EffectComposer the first time (as three.js's
// examples set them up) and writes a caption to `info`.

import * as THREE from "../three/Three";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { EffectComposer } from "../three/addons/postprocessing/EffectComposer";
import { RenderPass } from "../three/addons/postprocessing/RenderPass";
import { ShaderPass } from "../three/addons/postprocessing/ShaderPass";
import { OutputPass } from "../three/addons/postprocessing/OutputPass";
import { UnrealBloomPass } from "../three/addons/postprocessing/UnrealBloomPass";
import { OutlinePass } from "../three/addons/postprocessing/OutlinePass";
import { BokehPass, BokehPassParameters } from "../three/addons/postprocessing/BokehPass";
import { AfterimagePass } from "../three/addons/postprocessing/AfterimagePass";
import { FilmPass } from "../three/addons/postprocessing/FilmPass";
import { GlitchPass } from "../three/addons/postprocessing/GlitchPass";
import { DotScreenPass } from "../three/addons/postprocessing/DotScreenPass";
import { HalftonePass, HalftonePassParameters } from "../three/addons/postprocessing/HalftonePass";
import { LUTPass, LUTPassParameters } from "../three/addons/postprocessing/LUTPass";
import { RenderPixelatedPass } from "../three/addons/postprocessing/RenderPixelatedPass";
import { MaskPass, ClearMaskPass } from "../three/addons/postprocessing/MaskPass";
import { LUTCubeLoader } from "../three/addons/loaders/LUTCubeLoader";
import { CopyShader } from "../three/addons/shaders/PostShaders";
import { SMAAPass } from "../three/addons/postprocessing/SMAAPass";
import { SSAARenderPass } from "../three/addons/postprocessing/SSAARenderPass";
import { TAARenderPass } from "../three/addons/postprocessing/TAARenderPass";
import { SSAOPass } from "../three/addons/postprocessing/SSAOPass";
import { SAOPass } from "../three/addons/postprocessing/SAOPass";
import { GTAOPass, GTAOParameters } from "../three/addons/postprocessing/GTAOPass";
import { Context } from "rive/host";
import { PropertyNumber, PropertyString } from "rive/data";

// The panel's passes, in examples.rml's order.
const NONE = 0;
const SMAA = 1;
const SSAA = 2;
const TAA = 3;
const SSAO = 4;
const SAO = 5;
const GTAO = 6;
const OUTLINE = 7;
const BOKEH = 8;
const AFTERIMAGE = 9;
const FILM = 10;
const GLITCH = 11;
const DOT_SCREEN = 12;
const HALFTONE = 13;
const LUT = 14;
const PIXELATED = 15;
const MASK = 16;
const SELECTIVE_BLOOM = 17;
const PASS_COUNT = 18;

const INFO: StaticArray<string> = [
    "RenderPass and OutputPass only: ACES tone mapping and sRGB.",
    "SMAAPass: morphological anti-aliasing (edges, blend weights, blending).",
    "SSAARenderPass: the scene rendered 8 times with sub-pixel offsets, averaged.",
    "TAARenderPass: jittered renders accumulated while the camera is still.",
    "SSAOPass: screen-space ambient occlusion from a normal and depth prepass.",
    "SAOPass: scalable ambient obscurance, blurred by depth.",
    "GTAOPass: ground-truth ambient occlusion, Poisson denoised.",
    "OutlinePass: the knot and the ring outlined, hidden edges dimmer.",
    "BokehPass: depth of field, focused on the knot.",
    "AfterimagePass: each frame fades into the next.",
    "FilmPass: noise and scanline-free film grain.",
    "GlitchPass: random digital glitches.",
    "DotScreenPass: a rotated dot screen, in grey.",
    "HalftonePass: CMYK halftone dots.",
    "LUTPass: a colour grade from a .cube 3D LUT.",
    "RenderPixelatedPass: pixel art, with depth and normal edges.",
    "MaskPass: the dot screen applies inside a rotating ring only.",
    "Selective bloom: only the bloom layer glows (three.js's layer technique).",
];

const BLOOM_LAYER = 1;
const _black = new THREE.MeshBasicMaterial({ color: 0x000000 });
const _blackColor = new THREE.Color(0x000000);

export class Effects extends THREE.ThreeLayout {
    composers: Array<EffectComposer?> = [];
    current: i32 = -1;
    passProperty: PropertyNumber? = null;
    infoProperty: PropertyString? = null;
    time: f64 = 0;
    knot: THREE.Mesh = new THREE.Mesh();
    ring: THREE.Mesh = new THREE.Mesh();
    spinners: Array<THREE.Object3D> = [];
    // Selective bloom: the meshes outside the bloom layer, their materials.
    dimmed: Array<THREE.Mesh> = [];
    dimmedMaterials: Array<THREE.Material> = [];
    bloomComposer: EffectComposer? = null;
    bloomLayer: THREE.Layers = new THREE.Layers();
    // The mask pass's scene: a ring facing the camera.
    maskScene: THREE.Scene = new THREE.Scene();
    maskRing: THREE.Mesh = new THREE.Mesh();
    // TAA accumulates while the camera is still (the scene pauses).
    taa: TAARenderPass? = null;
    stillFor: f64 = 0;
    lastView: THREE.Matrix4 = new THREE.Matrix4();

    override setup(context: Context): bool {
        const renderer = this.renderer!;
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        const scene = this.scene;
        scene.background = new THREE.Color(0x14161c);
        scene.add(new THREE.HemisphereLight(0xc8d8ff, 0x3a3028, 1.1));
        const sun = new THREE.DirectionalLight(0xffffff, 2.2);
        sun.position.set(4, 7, 3);
        scene.add(sun);

        const floor = new THREE.Mesh(new THREE.PlaneGeometry(40, 40),
            new THREE.MeshStandardMaterial({ color: 0x8a8f99, roughness: 0.85 }));
        floor.rotation.x = -Math.PI / 2;
        scene.add(floor);

        // A stack of boxes (creases for the AO passes).
        const boxColors: Array<u32> = [0xd9d4cc, 0xc4553d, 0x4a7fb5, 0xe0b44c];
        let y: f64 = 0;
        for (let i = 0; i < 4; i++) {
            const s = 1.2 - <f64>i * 0.2;
            const box = new THREE.Mesh(new THREE.BoxGeometry(s, s, s),
                new THREE.MeshStandardMaterial({ color: boxColors[i], roughness: 0.6 }));
            box.position.set(-2.4 + <f64>i * 0.15, y + s / 2, -0.6);
            y += s;
            box.rotation.y = <f64>i * 0.35;
            scene.add(box);
        }
        // The knot (bloom layer: its emissive glows in selective bloom).
        this.knot = new THREE.Mesh(new THREE.TorusKnotGeometry(0.7, 0.22, 160, 20),
            new THREE.MeshStandardMaterial({ color: 0x2b8cbe, emissive: 0x1a6fff, emissiveIntensity: 0.5,
                roughness: 0.3, metalness: 0.2 }));
        this.knot.position.set(0.6, 1.4, 0.4);
        this.knot.layers.enable(BLOOM_LAYER);
        scene.add(this.knot);
        this.spinners.push(this.knot);
        // A neon ring (bloom layer too).
        this.ring = new THREE.Mesh(new THREE.TorusGeometry(1.1, 0.05, 16, 96),
            new THREE.MeshStandardMaterial({ color: 0x220a00, emissive: 0xff7a1a, emissiveIntensity: 2 }));
        this.ring.position.set(2.6, 1.3, -1.2);
        this.ring.layers.enable(BLOOM_LAYER);
        scene.add(this.ring);
        this.spinners.push(this.ring);
        // Spheres at several depths (bokeh), and a fence of thin poles (the
        // anti-aliasing passes).
        for (let i = 0; i < 5; i++) {
            const sphere = new THREE.Mesh(new THREE.SphereGeometry(0.35, 32, 16),
                new THREE.MeshStandardMaterial({ color: 0xf2f2f2, roughness: 0.15, metalness: 0.5 }));
            sphere.position.set(-3.5 + <f64>i * 1.6, 0.35, 2.4 - <f64>i * 1.4);
            scene.add(sphere);
        }
        for (let i = 0; i < 14; i++) {
            const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.025, 0.025, 1.6, 8),
                new THREE.MeshStandardMaterial({ color: 0x30343c, roughness: 0.5 }));
            pole.position.set(-3.2 + <f64>i * 0.5, 0.8, -2.8);
            pole.rotation.z = 0.08;
            scene.add(pole);
        }
        const rail = new THREE.Mesh(new THREE.BoxGeometry(7, 0.04, 0.04),
            new THREE.MeshStandardMaterial({ color: 0x30343c }));
        rail.position.set(0.1, 1.5, -2.8);
        scene.add(rail);

        this.bloomLayer.set(BLOOM_LAYER);
        const meshes: Array<THREE.Mesh> = [];
        const children = scene.children;
        for (let i = 0; i < children.length; i++) {
            const o = children[i];
            if (o instanceof THREE.Mesh && !o.layers.test(this.bloomLayer)) meshes.push(o as THREE.Mesh);
        }
        this.dimmed = meshes;

        const camera = this.camera as THREE.PerspectiveCamera;
        camera.near = 0.1;
        camera.far = 60;
        camera.position.set(4.2, 4.0, 8.4);
        camera.updateProjectionMatrix();
        const controls = new OrbitControls(camera, renderer);
        controls.target.set(-0.6, 0.8, -0.4);
        controls.update();
        this.controls = controls;

        this.maskRing = new THREE.Mesh(new THREE.TorusGeometry(2.4, 0.9, 24, 96), new THREE.MeshBasicMaterial());
        this.maskRing.position.copy(controls.target);
        this.maskRing.lookAt(camera.position);
        this.maskScene.add(this.maskRing);

        for (let i = 0; i < PASS_COUNT; i++) this.composers.push(null);
        const vm = context.viewModel();
        if (vm != null) {
            this.passProperty = vm.getNumber("pass");
            this.infoProperty = vm.getString("info");
        }
        return true;
    }

    // The panel is not the scene: presses on it do not orbit.
    override contains(x: f64, y: f64): bool {
        if (x < 270 && y < 260) return false;
        return super.contains(x, y);
    }

    override animate(seconds: f64): void {
        // TAA: still camera and scene, or the samples ghost.
        const taaMode = this.current == TAA;
        const view = this.camera.matrixWorld;
        if (view.equals(this.lastView)) this.stillFor += seconds;
        else this.stillFor = 0;
        this.lastView.copy(view);
        const taa = this.taa;
        if (taa != null) taa.accumulate = taaMode && this.stillFor > 0.2;
        const t = taaMode ? this.time : (this.time += seconds);
        this.knot.rotation.y = t * 0.5;
        this.knot.rotation.x = Math.sin(t * 0.3) * 0.4;
        this.ring.rotation.y = t * 0.8;
        const k = 1 + Math.sin(t * 1.3) * 0.15;
        this.maskRing.scale.set(k, k * 0.8, 1);
        const p = this.passProperty;
        let pass = p != null ? <i32>Math.round(p.value) : NONE;
        if (pass < 0 || pass >= PASS_COUNT) pass = NONE;
        if (pass != this.current) {
            this.current = pass;
            const info = this.infoProperty;
            if (info != null) info.value = INFO[pass];
        }
    }

    composer(pass: i32): EffectComposer {
        let c = this.composers[pass];
        if (c == null) {
            c = this.build(pass);
            this.composers[pass] = c;
        }
        return c!;
    }

    build(pass: i32): EffectComposer {
        const renderer = this.renderer!;
        const scene = this.scene;
        const camera = this.camera;
        const composer = new EffectComposer(renderer);
        if (pass == SELECTIVE_BLOOM) {
            // three.js's webgl_postprocessing_unreal_bloom_selective.
            const size = renderer.getDrawingBufferSize(new THREE.Vector2());
            const bloom = new EffectComposer(renderer);
            bloom.renderToScreen = false;
            bloom.addPass(new RenderPass(scene, camera));
            bloom.addPass(new UnrealBloomPass(size, 0.9, 0.3, 0.1));
            this.bloomComposer = bloom;
            const mix = new THREE.ShaderMaterial({ shader: "examples/shaders/bloom_mix" });
            mix.uniforms.set("baseTexture", new THREE.Uniform<THREE.Texture>(new THREE.Texture()));
            mix.uniforms.set("bloomTexture", new THREE.Uniform<THREE.Texture>(bloom.renderTarget2.texture));
            mix.depthTest = false;
            mix.depthWrite = false;
            const mixPass = ShaderPass.fromMaterial(mix, "baseTexture");
            mixPass.needsSwap = true;
            composer.addPass(new RenderPass(scene, camera));
            composer.addPass(mixPass);
            composer.addPass(new OutputPass());
            return composer;
        }
        const size = renderer.getDrawingBufferSize(new THREE.Vector2());
        if (pass == SSAA || pass == TAA) {
            // These render the scene themselves, jittered.
            if (pass == SSAA) {
                const ssaa = new SSAARenderPass(scene, camera);
                ssaa.sampleLevel = 2;
                composer.addPass(ssaa);
            } else {
                const taa = new TAARenderPass(scene, camera);
                taa.sampleLevel = 1;
                this.taa = taa;
                composer.addPass(taa);
            }
            composer.addPass(new OutputPass());
            return composer;
        }
        if (pass == PIXELATED) {
            // three.js's webgl_postprocessing_pixel: the pass renders the scene.
            composer.addPass(new RenderPixelatedPass(5, scene, camera));
            composer.addPass(new OutputPass());
            return composer;
        }
        composer.addPass(new RenderPass(scene, camera));
        if (pass == SMAA) {
            composer.addPass(new SMAAPass(size.x, size.y));
        } else if (pass == SSAO) {
            // Distances are fractions of far - near (here 60).
            const ssao = new SSAOPass(scene, camera, size.x, size.y);
            ssao.kernelRadius = 0.8;
            ssao.minDistance = 0.0005;
            ssao.maxDistance = 0.03;
            composer.addPass(ssao);
        } else if (pass == SAO) {
            const sao = new SAOPass(scene, camera, size);
            sao.params.saoKernelRadius = 40;
            sao.params.saoScale = 6;
            sao.params.saoIntensity = 0.25;
            composer.addPass(sao);
        } else if (pass == GTAO) {
            const gtao = new GTAOPass(scene, camera, size.x, size.y);
            const params = new GTAOParameters();
            params.radius = 0.8;
            params.thickness = 1;
            gtao.updateGtaoMaterial(params);
            composer.addPass(gtao);
        } else if (pass == OUTLINE) {
            const selected: Array<THREE.Object3D> = [this.knot, this.ring];
            const outline = new OutlinePass(size, scene, camera, selected);
            outline.visibleEdgeColor.set<u32>(0xffd27a);
            outline.hiddenEdgeColor.set<u32>(0x5a3a10);
            outline.edgeStrength = 4;
            outline.edgeThickness = 1.5;
            outline.edgeGlow = 0.6;
            outline.pulsePeriod = 2;
            composer.addPass(outline);
        } else if (pass == BOKEH) {
            const params = new BokehPassParameters();
            params.focus = 8.6;
            params.aperture = 0.008;
            params.maxblur = 0.015;
            composer.addPass(new BokehPass(scene, camera, params));
        } else if (pass == AFTERIMAGE) {
            composer.addPass(new AfterimagePass(0.92));
        } else if (pass == FILM) {
            composer.addPass(new FilmPass(0.6, false));
        } else if (pass == GLITCH) {
            composer.addPass(new GlitchPass());
        } else if (pass == HALFTONE) {
            const params = new HalftonePassParameters();
            params.radius = 5;
            params.scatter = 0.2;
            composer.addPass(new HalftonePass(size.x, size.y, params));
        }
        composer.addPass(new OutputPass());
        // The dot screen thresholds display colour (after the OutputPass;
        // before it, ACES whitens its out-of-range values).
        if (pass == DOT_SCREEN) composer.addPass(new DotScreenPass(new THREE.Vector2(0, 0), 0.5, 0.8));
        if (pass == MASK) {
            // three.js's masking: the dot screen inside a ring only, then a
            // copy to the screen (a ClearMaskPass draws nothing).
            composer.addPass(new MaskPass(this.maskScene, camera));
            composer.addPass(new DotScreenPass(new THREE.Vector2(0, 0), 0.5, 0.8));
            composer.addPass(new ClearMaskPass());
            composer.addPass(new ShaderPass(CopyShader));
        }
        if (pass == LUT) {
            // After the OutputPass: the grade works on display colour.
            const result = new LUTCubeLoader(this.context).load("warm_grade");
            const params = new LUTPassParameters();
            params.lut = result != null ? result!.texture3D : null;
            params.intensity = 1;
            composer.addPass(new LUTPass(params));
        }
        return composer;
    }

    override renderFrame(): void {
        const pass = this.current < 0 ? NONE : this.current;
        const composer = this.composer(pass);
        if (pass == SELECTIVE_BLOOM) {
            // Everything outside the bloom layer renders black for the bloom.
            const m = this.dimmed;
            this.dimmedMaterials.length = 0;
            for (let i = 0; i < m.length; i++) {
                this.dimmedMaterials.push(m[i].material);
                m[i].material = _black;
            }
            const background = this.scene.background;
            this.scene.background = _blackColor;
            this.bloomComposer!.render(this.delta);
            this.scene.background = background;
            for (let i = 0; i < m.length; i++) m[i].material = this.dimmedMaterials[i];
        }
        composer.render(this.delta);
    }
}
