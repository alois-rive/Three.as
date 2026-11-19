// Addons: three.js's examples/jsm/objects in one scene. An ocean (Water)
// under a Preetham Sky, which also lights the scene through a PMREM, with a
// Lensflare on the sun (occlusion by copyFramebufferToTexture); on a stone
// pier, a Reflector mirror, a Refractor glass pane, a Water2 pool flowing
// along a flow map, and MarchingCubes metaballs. After three.js's
// webgl_shaders_ocean, webgl_mirror, webgl_refraction, webgl_water_flowmap,
// webgl_lensflares and webgl_marchingcubes examples.

import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";
import { Water } from "lib:threeas/three/addons/objects/Water";
import { Water as Water2 } from "lib:threeas/three/addons/objects/Water2";
import { Sky } from "lib:threeas/three/addons/objects/Sky";
import { Reflector } from "lib:threeas/three/addons/objects/Reflector";
import { Refractor } from "lib:threeas/three/addons/objects/Refractor";
import { Lensflare, LensflareElement } from "lib:threeas/three/addons/objects/Lensflare";
import { MarchingCubes } from "lib:threeas/three/addons/objects/MarchingCubes";
import { WaterRefractionShader } from "lib:threeas/three/addons/shaders/WaterRefractionShader";
import { Context } from "rive/host";

export class Addons extends THREE.ThreeLayout {
    /// The sun's height above the horizon and its bearing, in degrees.
    @input elevation: f64 = 4;
    @input azimuth: f64 = 180;
    /// Shows the metaballs (they are rebuilt on the CPU every frame).
    @input metaballs: bool = true;

    water: Water? = null;
    pool: Water2? = null;
    glass: Refractor? = null;
    sky: Sky = new Sky();
    envSky: Sky = new Sky();
    envScene: THREE.Scene = new THREE.Scene();
    pmrem: THREE.PMREMGenerator = new THREE.PMREMGenerator();
    environment: THREE.PMREMResult? = null;
    sun: THREE.Vector3 = new THREE.Vector3();
    sunLight: THREE.DirectionalLight = new THREE.DirectionalLight(0xffffff, 2.5);
    flareAnchor: THREE.Object3D = new THREE.Object3D();
    blobs: MarchingCubes? = null;
    time: f64 = 0;
    sunElevation: f64 = -1;
    sunAzimuth: f64 = -1;

    override setup(context: Context): bool {
        const renderer = this.renderer!;
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        renderer.toneMappingExposure = 0.5;
        const scene = this.scene;
        const camera = this.camera as THREE.PerspectiveCamera;
        camera.fov = 55;
        camera.near = 1;
        camera.far = 20000;
        camera.position.set(70, 32, 120);
        camera.updateProjectionMatrix();

        const loader = new THREE.TextureLoader(context);

        // The ocean.
        const waterNormals = loader.load("waternormals");
        waterNormals.wrapS = waterNormals.wrapT = THREE.RepeatWrapping;
        const water = new Water(new THREE.PlaneGeometry(10000, 10000), {
            textureWidth: 512, textureHeight: 512, waterNormals: waterNormals,
            sunDirection: new THREE.Vector3(), sunColor: 0xffffff, waterColor: 0x001e0f, distortionScale: 3.7,
        });
        water.rotation.x = -Math.PI / 2;
        scene.add(water);
        this.water = water;

        // The sky, and a copy of it for the environment (PMREMGenerator's
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
        this.pmrem = new THREE.PMREMGenerator(renderer);

        // The sun's light and its lens flare.
        scene.add(this.sunLight);
        const flare = new Lensflare();
        flare.addElement(new LensflareElement(loader.load("lensflare0"), 700, 0, new THREE.Color(0xffeedd)));
        const ring = loader.load("lensflare3");
        flare.addElement(new LensflareElement(ring, 60, 0.6));
        flare.addElement(new LensflareElement(ring, 70, 0.7));
        flare.addElement(new LensflareElement(ring, 120, 0.9));
        flare.addElement(new LensflareElement(ring, 70, 1));
        // Layer 1, which only the main camera sees: no flares in the
        // reflections (and far fewer passes).
        flare.layers.set(1);
        camera.layers.enable(1);
        this.flareAnchor.add(flare);
        scene.add(this.flareAnchor);

        // The pier.
        const stone = new THREE.MeshStandardMaterial({ color: 0x8a8378, roughness: 0.85 });
        const pier = new THREE.Mesh(new THREE.BoxGeometry(110, 6, 56), stone);
        pier.position.set(0, 1, 0);
        scene.add(pier);
        const frame = new THREE.MeshStandardMaterial({ color: 0x23262b, roughness: 0.4, metalness: 0.6 });

        // A mirror (webgl_mirror's tint).
        const mirror = new Reflector(new THREE.PlaneGeometry(26, 34), {
            textureWidth: 1024, textureHeight: 1024, color: 0xc1cbcb,
        });
        mirror.position.set(-34, 21, -14);
        mirror.rotation.y = 0.45;
        scene.add(mirror);
        const mirrorFrame = new THREE.Mesh(new THREE.BoxGeometry(28, 36, 1.2), frame);
        mirrorFrame.position.set(0, 0, -0.7);
        mirror.add(mirrorFrame);

        // A rippled glass pane (webgl_refraction: WaterRefractionShader).
        const glass = new Refractor(new THREE.PlaneGeometry(22, 28), {
            textureWidth: 512, textureHeight: 512, color: 0xcbcbcb, shader: WaterRefractionShader,
        });
        const dudv = loader.load("waterdudv");
        dudv.wrapS = dudv.wrapT = THREE.RepeatWrapping;
        (glass.material as THREE.ShaderMaterial).uniform<THREE.Texture>("tDudv").value = dudv;
        this.glass = glass;
        glass.position.set(16, 18, 14);
        glass.rotation.y = 0.48;
        scene.add(glass);
        const glassFrame = new THREE.Mesh(new THREE.BoxGeometry(24, 1.2, 1.2), frame);
        glassFrame.position.set(0, -14.6, 0);
        glass.add(glassFrame);

        // A pool flowing along a flow map (webgl_water_flowmap).
        const basin = new THREE.Mesh(new THREE.BoxGeometry(36, 2, 18),
            new THREE.MeshStandardMaterial({ color: 0x2f5560, roughness: 0.9 }));
        basin.position.set(-24, 3.2, 14);
        scene.add(basin);
        const pool = new Water2(new THREE.PlaneGeometry(34, 16), {
            scale: 2, flowMap: loader.load("Water_1_M_Flow"), textureWidth: 512, textureHeight: 512,
            normalMap0: loader.load("Water_1_M_Normal"), normalMap1: loader.load("Water_2_M_Normal"),
            color: 0xbfd6e0,
        });
        pool.rotation.x = -Math.PI / 2;
        pool.position.set(-24, 4.4, 14);
        scene.add(pool);
        this.pool = pool;

        // Metaballs (webgl_marchingcubes), coloured per ball.
        const blobs = new MarchingCubes(28, new THREE.MeshStandardMaterial({
            vertexColors: true, roughness: 0.25, metalness: 0.1,
        }), false, true, 20000);
        blobs.position.set(0, 20, -8);
        blobs.scale.setScalar(11);
        scene.add(blobs);
        this.blobs = blobs;

        const controls = new OrbitControls(camera, renderer);
        controls.maxPolarAngle = Math.PI * 0.495;
        controls.target.set(0, 12, 0);
        controls.minDistance = 40;
        controls.maxDistance = 300;
        controls.update();
        this.controls = controls;
        this.updateSun();
        return true;
    }

    /// The sun from elevation and azimuth: the skies, the water's sun, the
    /// light, the flare, and a new environment (as webgl_shaders_ocean).
    updateSun(): void {
        this.sunElevation = this.elevation;
        this.sunAzimuth = this.azimuth;
        const phi = THREE.MathUtils.degToRad(90 - this.elevation);
        const theta = THREE.MathUtils.degToRad(this.azimuth);
        this.sun.setFromSphericalCoords(1, phi, theta);
        this.sky.shaderMaterial.uniform<THREE.Vector3>("sunPosition").value.copy(this.sun);
        this.envSky.shaderMaterial.uniform<THREE.Vector3>("sunPosition").value.copy(this.sun);
        this.water!.shaderMaterial.uniform<THREE.Vector3>("sunDirection").value.copy(this.sun).normalize();
        this.sunLight.position.copy(this.sun).multiplyScalar(100);
        this.flareAnchor.position.copy(this.sun).multiplyScalar(4000);
        const previous = this.environment;
        if (previous != null) previous.dispose();
        const env = this.pmrem.fromScene(this.envScene);
        this.environment = env;
        this.scene.environment = env.texture;
    }

    override animate(seconds: f64): void {
        const t = (this.time += seconds);
        if (this.elevation != this.sunElevation || this.azimuth != this.sunAzimuth) this.updateSun();
        this.water!.shaderMaterial.uniform<f64>("time").value += seconds;
        this.pool!.tick(seconds);
        (this.glass!.material as THREE.ShaderMaterial).uniform<f64>("time").value = t;

        const blobs = this.blobs!;
        blobs.visible = this.metaballs;
        if (!this.metaballs) return;
        // webgl_marchingcubes's updateCubes: balls on Lissajous paths.
        blobs.reset();
        const numblobs = 10;
        const subtract = 12;
        const strength = 1.2 / ((Math.sqrt(<f64>numblobs) - 1) / 4 + 1);
        for (let i = 0; i < numblobs; i++) {
            const k = <f64>i;
            const ballx = Math.sin(k + 1.26 * t * (1.03 + 0.5 * Math.cos(0.21 * k))) * 0.27 + 0.5;
            const bally = Math.abs(Math.cos(k + 1.12 * t * Math.cos(1.22 + 0.1424 * k))) * 0.77;
            const ballz = Math.cos(k + 1.32 * t * 0.1 * Math.sin(0.92 + 0.53 * k)) * 0.27 + 0.5;
            const color = new THREE.Color().setHSL(k / <f64>numblobs, 0.8, 0.5);
            blobs.addBall(ballx, bally, ballz, strength, subtract, color);
        }
        blobs.addPlaneY(2, 12);
        blobs.update();
    }
}
