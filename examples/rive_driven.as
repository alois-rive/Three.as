// RiveDriven: Rive driving a three.js scene (M13b-d).
//   - 2D labels (RiveDrivenLabel artboards) over the 3D objects, fading
//     when something hides them; click one to toggle it.
//   - The stage's state machine drives the scene through its view model:
//     Day/Night fades the sun (a timeline bound back into `daylight`), a
//     looping timeline turns the turntable (`spin`), the swatches tint the
//     globe, JUMP plays a three.js action, and the crate's height comes
//     back into the meter. The wiring is the view model's `threeBindings`
//     string (SceneBindings), editable in the Rive editor.
//   - A four-bone Rive rig (RiveDrivenRig, drawn in the corner) poses a
//     three.js skeleton live (RiveRig), and a second arm plays the same
//     timeline baked into an AnimationClip.

import * as THREE from "../three/Three";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { Context } from "rive/host";
import { Artboard } from "rive/artboard";
import { ViewModel, PropertyBoolean, PropertyString } from "rive/data";

const ARM_BONES: i32 = 4;
const ARM_SEGMENT: f64 = 0.52;   // the Rive bones' 52 units at 0.01
const DAY_SKY: u32 = 0x3a5068;
const NIGHT_SKY: u32 = 0x080b12;

export class RiveDriven extends THREE.ThreeLayout {
    @input label: Artboard? = null;
    @input rig: Artboard? = null;

    mixer: THREE.AnimationMixer = new THREE.AnimationMixer(new THREE.Object3D());
    bakedMixer: THREE.AnimationMixer? = null;
    riveRig: THREE.RiveRig? = null;
    sun: THREE.DirectionalLight = new THREE.DirectionalLight(0xffffff, 3);
    labels: Array<THREE.Artboard2DObject> = [];
    labelActive: Array<PropertyBoolean?> = [];
    labelTargets: Array<THREE.Mesh> = [];
    hud: THREE.Artboard2DObject? = null;
    info: PropertyString? = null;
    background: THREE.Color = new THREE.Color(DAY_SKY);
    day: THREE.Color = new THREE.Color(DAY_SKY);
    night: THREE.Color = new THREE.Color(NIGHT_SKY);
    time: f64 = 0;
    built: bool = false;

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = this.background;
        const sky = new THREE.HemisphereLight(0xdde6ff, 0x2a2420, 1.4);
        sky.name = "Sky";
        scene.add(sky);
        this.sun.name = "Sun";
        this.sun.position.set(4, 7, 5);
        scene.add(this.sun);
        const ground = new THREE.Mesh(new THREE.CircleGeometry(8, 64),
            new THREE.MeshStandardMaterial({ color: 0x2a2f38, roughness: 0.9 }));
        ground.rotation.x = -Math.PI / 2;
        scene.add(ground);

        this.camera.position.set(0, 3.4, 8.5);
        scene.add(this.camera);   // the HUD rides on it
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.target.set(0, 1.1, 0);
        controls.update();
        this.controls = controls;
        this.overlay = new THREE.ArtboardOverlayRenderer();

        const vm = context.viewModel();
        if (vm != null) {
            this.info = vm.getString("info");
            const info = this.info;
            if (info != null) {
                info.value = "Click a label. Left arm: the Rive bones, live. Right: baked into a clip.";
            }
        }
        return true;
    }

    /// The scene, built on the first frame (artboard inputs may not be
    /// bound while init runs).
    private build(): void {
        const scene = this.scene;
        const turntable = new THREE.Group();
        turntable.name = "Turntable";
        scene.add(turntable);
        const disc = new THREE.Mesh(new THREE.CylinderGeometry(2.6, 2.6, 0.12, 64),
            new THREE.MeshStandardMaterial({ color: 0x3a404c, roughness: 0.6 }));
        disc.position.y = 0.06;
        turntable.add(disc);

        const globe = new THREE.Mesh(new THREE.SphereGeometry(0.55, 48, 24),
            new THREE.MeshStandardMaterial({ color: 0x2b8cbe, roughness: 0.3, metalness: 0.1 }));
        globe.name = "Globe";
        globe.position.set(-1.6, 0.67, 0.4);
        turntable.add(globe);

        const crate = new THREE.Mesh(new THREE.BoxGeometry(0.6, 0.6, 0.6),
            new THREE.MeshStandardMaterial({ color: 0xc8a27a, roughness: 0.7 }));
        crate.name = "Crate";
        crate.position.set(1.5, 0.42, 0.6);
        turntable.add(crate);

        // A lamp post: a pole, an emissive bulb and a point light (night
        // only, through the bindings).
        const post = new THREE.Group();
        post.position.set(0.2, 0, -1.7);
        turntable.add(post);
        const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.04, 0.05, 1.6, 12),
            new THREE.MeshStandardMaterial({ color: 0x5c6370, roughness: 0.5, metalness: 0.6 }));
        pole.position.y = 0.8;
        post.add(pole);
        const bulb = new THREE.Mesh(new THREE.SphereGeometry(0.14, 24, 12),
            new THREE.MeshStandardMaterial({ color: 0xfff1cc, emissive: 0xffc866, emissiveIntensity: 0 }));
        bulb.name = "Bulb";
        bulb.position.y = 1.68;
        post.add(bulb);
        const lamp = new THREE.PointLight(0xffc866, 6, 7);
        lamp.name = "Lamp";
        lamp.position.y = 1.68;
        lamp.visible = false;
        post.add(lamp);

        // three.js actions: the crate turns, and jumps on the view model's
        // `jump` trigger ("jump -> @jump.play" in threeBindings).
        this.mixer = new THREE.AnimationMixer(scene);
        const turn = new THREE.AnimationClip("turn", -1, [
            new THREE.NumberKeyframeTrack("Crate.rotation[y]", [0, 4], [0, Math.PI * 2]),
        ]);
        this.mixer.clipAction(turn).play();
        const jump = new THREE.AnimationClip("jump", -1, [
            new THREE.NumberKeyframeTrack("Crate.position[y]", [0, 0.35, 0.7], [0.42, 1.5, 0.42], THREE.InterpolateSmooth),
        ]);
        const jumpAction = this.mixer.clipAction(jump).setLoop(THREE.LoopOnce, 1);
        const bindings = this.bindings;
        if (bindings != null) bindings.addAction("jump", jumpAction);

        // The arms: one posed live by the Rive rig, one playing it baked.
        const live = this.arm("LiveArm", -0.55);
        const baked = this.arm("BakedArm", 0.75);
        scene.add(live);
        scene.add(baked);
        const rigArtboard = this.rig;
        if (rigArtboard != null) {
            const rr = new THREE.RiveRig(rigArtboard);
            rr.mapSkeleton((live.children[1] as THREE.SkinnedMesh).skeleton!);
            rr.play("Wave");
            const clip = rr.bake("Wave", 30, "wave");
            if (clip != null) {
                const m = new THREE.AnimationMixer(baked);
                m.clipAction(clip).play();
                this.bakedMixer = m;
            }
            this.riveRig = rr;
            // The rig itself, in the corner: a HUD riding on the camera.
            const hud = new THREE.Artboard2DObject(rr.artboard, false);
            hud.autoAdvance = false;   // the RiveRig advances it
            hud.interactive = false;
            hud.center.set(1, 1);
            hud.screenScale = 0.7;
            this.camera.add(hud);
            this.hud = hud;
            this.placeHud();
        }

        // Labels over the objects, each its own SceneLabel view model.
        this.addLabel("Globe", globe, 0.8);
        this.addLabel("Crate", crate, 0.65);
        this.addLabel("Lamp", bulb, 0.35);
        this.addLabel("Live arm", live.children[1] as THREE.Mesh, 2.45);

        // A label in 3D (CSS3DObject's counterpart): lying on the disc's
        // rim, an artboard unit 1.6 cm.
        const label = this.label;
        if (label != null) {
            const vm = ViewModel.create("SceneLabel");
            const t = vm.getString("text");
            if (t != null) t.value = "Turntable";
            const sign = new THREE.Artboard3DObject(label.instance(vm), false);
            sign.scale.setScalar(0.016);
            sign.rotation.x = -Math.PI / 2;
            sign.position.set(0, 0.125, 2.05);
            turntable.add(sign);
        }
    }

    private addLabel(text: string, target: THREE.Mesh, height: f64): void {
        const artboard = this.label;
        if (artboard == null) return;
        const vm = ViewModel.create("SceneLabel");
        const t = vm.getString("text");
        if (t != null) t.value = text;
        const label = new THREE.Artboard2DObject(artboard.instance(vm), false);
        label.center.set(0.5, 1);
        label.position.set(0, height, 0);
        label.occlude = true;
        label.occludedOpacity = 0.3;
        target.add(label);
        this.labels.push(label);
        this.labelActive.push(vm.getBoolean("active"));
        this.labelTargets.push(target);
    }

    /// A skinned arm of ARM_BONES bones named Arm0... (as the Rive rig's).
    private arm(name: string, x: f64): THREE.Group {
        const height = ARM_SEGMENT * <f64>ARM_BONES;
        const geometry = new THREE.CylinderGeometry(0.07, 0.13, height, 20, ARM_BONES * 6, false);
        geometry.translate(0, height / 2, 0);
        const position = geometry.getAttribute("position")!;
        const indices: Array<f64> = [];
        const weights: Array<f64> = [];
        for (let i = 0; i < position.count; i++) {
            const y = position.getY(i);
            const index = Math.min(<f64>ARM_BONES - 1, Math.floor(y / ARM_SEGMENT));
            const w = Math.min(1, Math.max(0, y / ARM_SEGMENT - index));
            indices.push(index); indices.push(index + 1); indices.push(0); indices.push(0);
            weights.push(1 - w); weights.push(w); weights.push(0); weights.push(0);
        }
        geometry.setAttribute("skinIndex", new THREE.Float32BufferAttribute(indices, 4));
        geometry.setAttribute("skinWeight", new THREE.Float32BufferAttribute(weights, 4));
        const bones: Array<THREE.Bone> = [];
        let prev: THREE.Bone? = null;
        for (let i = 0; i <= ARM_BONES; i++) {
            const bone = new THREE.Bone();
            bone.name = "Arm" + i.toString();
            if (prev != null) {
                bone.position.y = ARM_SEGMENT;
                prev.add(bone);
            }
            bones.push(bone);
            prev = bone;
        }
        const mesh = new THREE.SkinnedMesh(geometry,
            new THREE.MeshStandardMaterial({ color: 0x2ec4b6, roughness: 0.4 }));
        mesh.frustumCulled = false;
        const root = new THREE.Group();
        root.name = name;
        root.position.set(x, 0.12, -0.3);
        root.add(bones[0]);
        root.add(mesh);
        root.updateMatrixWorld(true);
        mesh.bind(new THREE.Skeleton(bones));
        return root;
    }

    /// The HUD at the bottom right, one unit in front of the camera.
    private placeHud(): void {
        const hud = this.hud;
        const camera = this.camera;
        if (hud == null || !(camera instanceof THREE.PerspectiveCamera)) return;
        const pc = camera as THREE.PerspectiveCamera;
        const h = Math.tan(pc.fov * THREE.DEG2RAD / 2);
        const w = h * pc.aspect;
        const marginX = this.width > 0 ? 12 / this.width * 2 : 0;
        const marginY = this.height > 0 ? 12 / this.height * 2 : 0;
        hud.position.set(w * (1 - marginX), -h * (1 - marginY), -1);
    }

    override onResize(width: f64, height: f64): void {
        this.placeHud();
    }

    override animate(seconds: f64): void {
        if (!this.built) {
            this.built = true;
            this.build();
        }
        this.time += seconds;
        this.mixer.update(seconds);
        const baked = this.bakedMixer;
        if (baked != null) baked.update(seconds);
        const rr = this.riveRig;
        if (rr != null) rr.advance(seconds);
        // The sky follows the sun (the bindings set its intensity).
        this.background.lerpColors(this.night, this.day, Math.min(1, this.sun.intensity / 3));
        // A clicked label lights its object.
        for (let i = 0; i < this.labels.length; i++) {
            const active = this.labelActive[i];
            const m = this.labelTargets[i].material;
            if (active != null && m instanceof THREE.MeshStandardMaterial) {
                const sm = m as THREE.MeshStandardMaterial;
                if (this.labelTargets[i].name == "Bulb") continue;
                sm.emissive.setHex(active.value ? 0x6a4a10 : 0x000000);
            }
        }
    }
}
