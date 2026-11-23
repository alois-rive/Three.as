// Audio: three.js's spatial audio (src/audio), mixed on Rive's audio thread.
// You stand at the centre (the AudioListener rides on the camera); four
// PositionalAudio emitters orbit you: a humming orb (inverse distance), a
// chime (linear), a knock (exponential) and a radio box whose directional
// cone (PositionalAudioHelper: green inner, yellow outer) sweeps past you
// as it turns. A non-positional Audio plays wind; an AudioAnalyser draws
// the radio's spectrum as bars. The top-right inset shows the room from
// above. Drag to look around; the round button plays and stops (a browser
// starts audio only after a click, tap or key press on the page).
//
// The sounds are original (tools/make_audio_samples.py) and loaded with
// AudioLoader from the file's audio assets.

import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";
import { PositionalAudioHelper } from "lib:threeas/three/addons/helpers/PositionalAudioHelper";
import { Context } from "rive/host";
import { PointerEvent } from "rive/events";

const HUD_LAYER: i32 = 2;
const MAP_LAYER: i32 = 1;
const BARS: i32 = 32;

class Emitter {
    mesh: THREE.Mesh;
    sound: THREE.PositionalAudio;
    radius: f64;
    height: f64;
    speed: f64;
    phase: f64;
    spin: f64 = 0;

    constructor(mesh: THREE.Mesh, sound: THREE.PositionalAudio, radius: f64, height: f64, speed: f64, phase: f64) {
        this.mesh = mesh;
        this.sound = sound;
        this.radius = radius;
        this.height = height;
        this.speed = speed;
        this.phase = phase;
    }
}

export class AudioExample extends THREE.ThreeLayout {
    listener: THREE.AudioListener = new THREE.AudioListener();
    emitters: Array<Emitter> = [];
    ambience: THREE.Audio? = null;
    radio: THREE.PositionalAudio? = null;
    analyser: THREE.AudioAnalyser? = null;
    bars: Array<THREE.Mesh> = [];
    hud: THREE.Group = new THREE.Group();
    button: THREE.Mesh = new THREE.Mesh();
    playIcon: THREE.Mesh = new THREE.Mesh();
    stopIcon: THREE.Mesh = new THREE.Mesh();
    buttonMaterial: THREE.MeshBasicMaterial = new THREE.MeshBasicMaterial({ color: 0x2b3240 });
    top: THREE.OrthographicCamera = new THREE.OrthographicCamera(-8, 8, 6, -6, 0.1, 50);
    mapBackground: THREE.Color = new THREE.Color(0x1c2431);
    playing: bool = false;
    time: f64 = 0;

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = new THREE.Color(0x101419);
        scene.fog = new THREE.Fog(0x101419, 8, 22);
        scene.add(new THREE.HemisphereLight(0xbfd4ff, 0x20242c, 1.2));
        const sun = new THREE.DirectionalLight(0xffffff, 1.5);
        sun.position.set(3, 8, 2);
        scene.add(sun);
        const grid = new THREE.GridHelper(40, 40, 0x3a4250, 0x262b34);
        scene.add(grid);
        const floor = new THREE.Mesh(new THREE.CircleGeometry(20, 48),
            new THREE.MeshStandardMaterial({ color: 0x181c22, roughness: 0.95 }));
        floor.rotation.x = -Math.PI / 2;
        floor.position.y = -0.01;
        scene.add(floor);

        // The listener stands at the centre, on the camera. Dragging turns
        // the head (OrbitControls around a target just ahead).
        const camera = this.camera as THREE.PerspectiveCamera;
        camera.fov = 60;
        camera.position.set(0, 1.6, 0.01);
        camera.updateProjectionMatrix();
        camera.add(this.listener);
        camera.layers.enable(HUD_LAYER);
        // The button is on the HUD layer: the raycaster tests layers too.
        this.raycaster.layers.enable(HUD_LAYER);
        scene.add(camera);
        const controls = new OrbitControls(camera, this.renderer);
        controls.target.set(0, 1.6, 0);
        controls.enableZoom = false;
        controls.enablePan = false;
        controls.rotateSpeed = -0.35;
        controls.enableDamping = true;
        this.controls = controls;

        // The top view (inset), with a marker for the listener's head.
        this.top.position.set(0, 20, 0);
        this.top.up.set(0, 0, -1);
        this.top.lookAt(0, 0, 0);
        this.top.layers.enable(MAP_LAYER);
        const head = new THREE.Mesh(new THREE.ConeGeometry(0.35, 0.9, 3),
            new THREE.MeshBasicMaterial({ color: 0xf2f2f2 }));
        head.rotation.x = -Math.PI / 2;
        head.layers.set(MAP_LAYER);
        camera.add(head);

        // The sounds.
        const loader = new THREE.AudioLoader(context);
        const hum = this.addEmitter(loader.load("hum"), 0xff9a3c, new THREE.SphereGeometry(0.28, 32, 16), 3.2, 1.2, 0.35, -1.2);
        hum.sound.setRefDistance(1.5);
        const chime = this.addEmitter(loader.load("chime"), 0x56d4ff, new THREE.IcosahedronGeometry(0.25, 0), 5.5, 2.6, -0.5, 1.25);
        chime.sound.setDistanceModel("linear");
        chime.sound.setMaxDistance(14);
        const knock = this.addEmitter(loader.load("knock"), 0xb98cff, new THREE.OctahedronGeometry(0.22, 0), 7, 0.6, 0.22, 3.0);
        knock.sound.setDistanceModel("exponential");
        knock.sound.setRefDistance(2);
        knock.sound.setRolloffFactor(1.2);
        const radio = this.addEmitter(loader.load("radio"), 0x7ce38b, new THREE.BoxGeometry(0.6, 0.38, 0.3), 4.2, 1.0, 0.18, -0.06);
        radio.spin = 0.9;
        radio.sound.setDirectionalCone(70, 160, 0.08);
        radio.sound.setRefDistance(2);
        radio.sound.add(new PositionalAudioHelper(radio.sound, 2.2));
        this.radio = radio.sound;
        // A speaker grille on the radio's front (+Z, where its cone points).
        const grille = new THREE.Mesh(new THREE.CircleGeometry(0.12, 24), new THREE.MeshBasicMaterial({ color: 0x0d2410 }));
        grille.position.z = 0.151;
        radio.mesh.add(grille);

        const ambience = new THREE.Audio(this.listener);
        ambience.setBuffer(loader.load("wind"));
        ambience.setLoop(true);
        ambience.setVolume(0.35);
        this.ambience = ambience;

        // The radio's spectrum.
        this.analyser = new THREE.AudioAnalyser(radio.sound, 128);
        this.buildHud();

        if (context.arg("audioAutoplay") != null) this.setPlaying(true);
        return true;
    }

    addEmitter(buffer: THREE.AudioBuffer, color: u32, geometry: THREE.BufferGeometry, radius: f64, height: f64,
               speed: f64, phase: f64): Emitter {
        const material = new THREE.MeshStandardMaterial({ color: color, emissive: color, emissiveIntensity: 0.6, roughness: 0.4 });
        const mesh = new THREE.Mesh(geometry, material);
        const sound = new THREE.PositionalAudio(this.listener);
        sound.setBuffer(buffer);
        sound.setLoop(true);
        mesh.add(sound);
        this.scene.add(mesh);
        const e = new Emitter(mesh, sound, radius, height, speed, phase);
        this.emitters.push(e);
        this.place(e);
        // Its orbit on the floor.
        const ring = new THREE.Mesh(new THREE.RingGeometry(radius - 0.02, radius + 0.02, 96),
            new THREE.MeshBasicMaterial({ color: color, transparent: true, opacity: 0.25 }));
        ring.rotation.x = -Math.PI / 2;
        ring.position.y = 0.005;
        this.scene.add(ring);
        return e;
    }

    place(e: Emitter): void {
        const a = e.phase + this.time * e.speed;
        e.mesh.position.set(Math.sin(a) * e.radius, e.height, -Math.cos(a) * e.radius);
        e.mesh.rotation.y = this.time * e.spin;
        if (e.spin == 0) e.mesh.rotation.y = this.time * 0.7;
    }

    buildHud(): void {
        // The HUD rides on the camera, 2 units ahead, seen only by it.
        this.hud.position.z = -2;
        this.camera.add(this.hud);
        this.button = new THREE.Mesh(new THREE.CircleGeometry(0.11, 40), this.buttonMaterial);
        this.hud.add(this.button);
        const tri = new THREE.Shape();
        tri.moveTo(-0.035, -0.045);
        tri.lineTo(0.05, 0);
        tri.lineTo(-0.035, 0.045);
        tri.closePath();
        this.playIcon = new THREE.Mesh(new THREE.ShapeGeometry([tri]), new THREE.MeshBasicMaterial({ color: 0x7ce38b }));
        this.playIcon.position.z = 0.001;
        this.button.add(this.playIcon);
        this.stopIcon = new THREE.Mesh(new THREE.PlaneGeometry(0.08, 0.08), new THREE.MeshBasicMaterial({ color: 0xff7a6b }));
        this.stopIcon.position.z = 0.001;
        this.stopIcon.visible = false;
        this.button.add(this.stopIcon);
        const barGeometry = new THREE.BoxGeometry(0.026, 1, 0.01);
        barGeometry.translate(0, 0.5, 0);
        for (let i = 0; i < BARS; i++) {
            const color = new THREE.Color().setHSL(0.33 - 0.33 * <f64>i / <f64>BARS, 0.75, 0.55);
            const bar = new THREE.Mesh(barGeometry, new THREE.MeshBasicMaterial({ color: color.getHex() }));
            bar.scale.y = 0.002;
            this.hud.add(bar);
            this.bars.push(bar);
        }
        setLayer(this.hud, HUD_LAYER);
        this.layoutHud();
    }

    /// Bottom left: the button; bottom centre: the bars.
    layoutHud(): void {
        const camera = this.camera as THREE.PerspectiveCamera;
        const halfH = Math.tan(camera.fov * Math.PI / 360) * 2;
        const halfW = halfH * Math.max(camera.aspect, 0.3);
        this.button.position.set(-halfW + 0.2, -halfH + 0.2, 0);
        const width = 0.034 * <f64>BARS;
        for (let i = 0; i < BARS; i++) {
            this.bars[i].position.set(-width / 2 + 0.034 * (<f64>i + 0.5), -halfH + 0.08, 0);
        }
    }

    override onResize(width: f64, height: f64): void {
        if (this.bars.length > 0) this.layoutHud();
    }

    setPlaying(on: bool): void {
        this.playing = on;
        for (let i = 0; i < this.emitters.length; i++) {
            const s = this.emitters[i].sound;
            if (on) s.play();
            else s.stop();
        }
        const ambience = this.ambience!;
        if (on) ambience.play();
        else ambience.stop();
        this.playIcon.visible = !on;
        this.stopIcon.visible = on;
    }

    override onPointerDown(event: PointerEvent): void {
        const hits = this.raycaster.intersectObject(this.button, true);
        if (hits.length > 0) {
            this.setPlaying(!this.playing);
            event.hit();
        }
    }

    override animate(seconds: f64): void {
        this.time += seconds;
        for (let i = 0; i < this.emitters.length; i++) {
            const e = this.emitters[i];
            this.place(e);
            // Emitters glow with how loud they are where you stand.
            const material = e.mesh.material as THREE.MeshStandardMaterial;
            const level = this.playing ? e.sound.distanceGain * e.sound.coneGain : 0;
            material.emissiveIntensity = 0.25 + 1.2 * Math.min(1, level);
        }
        // The spectrum (64 bins; the lower half, two per bar).
        const data = this.analyser!.getFrequencyData();
        for (let i = 0; i < BARS; i++) {
            const v = (<f64>data[i * 2] + <f64>data[i * 2 + 1]) / 510;
            const bar = this.bars[i];
            bar.scale.y = Math.max(0.002, bar.scale.y * 0.6 + 0.4 * v * 0.55);
        }
        this.buttonMaterial.color.setHex(this.playing ? 0x3a2a2a : 0x223a2a);
        // Publish the mix now (the render does too; headless runs do not render).
        this.listener.update();
    }

    override renderFrame(): void {
        const r = this.renderer!;
        const w = this.width, h = this.height;
        r.setScissorTest(false);
        r.setViewport(0, 0, w, h);
        // Cleared first, so the inset's partial render keeps this one
        // (docs/DEVIATIONS.md, Views).
        r.clear();
        r.render(this.scene, this.camera);
        // The room from above, top right.
        const size = Math.min(w, h) * 0.3;
        this.top.left = -8;
        this.top.right = 8;
        this.top.top = 8;
        this.top.bottom = -8;
        this.top.updateProjectionMatrix();
        // No fog from up there, and a background of its own.
        const fog = this.scene.fog;
        const background = this.scene.background;
        this.scene.fog = null;
        this.scene.background = this.mapBackground;
        r.setScissorTest(true);
        r.setScissor(w - size - 12, h - size - 12, size, size);
        r.setViewport(w - size - 12, h - size - 12, size, size);
        r.render(this.scene, this.top);
        this.scene.fog = fog;
        this.scene.background = background;
        r.setScissorTest(false);
        r.setViewport(0, 0, w, h);
    }
}

function setLayer(o: THREE.Object3D, layer: i32): void {
    o.layers.set(layer);
    for (let i = 0; i < o.children.length; i++) setLayer(o.children[i], layer);
}
