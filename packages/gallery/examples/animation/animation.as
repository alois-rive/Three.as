// Animation: the M13 animation features side by side.
//   - A tentacle playing a subclip of a longer clip, with a second subclip
//     made additive (AnimationUtils.subclip / makeClipAdditive) curling it
//     on top, its weight swelling and fading.
//   - A blob with 48 morph targets blended on the GPU (a morph target
//     texture), a wave of bumps running over it.
//   - 64 instances of a morphing gem, each with its own weights
//     (InstancedMesh.setMorphAt and morphTexture).
//   - A serpent skinned to a 320-bone skeleton (a bone texture: over the
//     256 bones a uniform block holds).
//   - A row of buoys bobbing from one action on an AnimationObjectGroup.

import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";
import { Context } from "rive/host";

const TENTACLE_BONES: i32 = 6;
const TENTACLE_SEGMENT: f64 = 0.55;
const BUMPS: i32 = 48;
const BUMP_HEIGHT: f64 = 0.32;
const GEMS_SIDE: i32 = 8;
const SERPENT_BONES: i32 = 320;
const SERPENT_LENGTH: f64 = 16;

export class Animation extends THREE.ThreeLayout {
    mixer: THREE.AnimationMixer = new THREE.AnimationMixer(new THREE.Object3D());
    groupMixer: THREE.AnimationMixer = new THREE.AnimationMixer(new THREE.Object3D());
    curl: THREE.AnimationAction? = null;
    blob: THREE.Mesh = new THREE.Mesh();
    bumpDirections: Array<THREE.Vector3> = [];
    gems: THREE.InstancedMesh? = null;
    gemWeights: THREE.Mesh = new THREE.Mesh();
    serpentBones: Array<THREE.Bone> = [];
    time: f64 = 0;
    built: i32 = 0;

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = new THREE.Color(0x111419);
        scene.add(new THREE.HemisphereLight(0xdde6ff, 0x2a2420, 1.6));
        const sun = new THREE.DirectionalLight(0xffffff, 2.4);
        sun.position.set(3, 6, 5);
        scene.add(sun);
        const floor = new THREE.Mesh(new THREE.CircleGeometry(9, 64),
            new THREE.MeshStandardMaterial({ color: 0x1c2029, roughness: 0.95 }));
        floor.rotation.x = -Math.PI / 2;
        scene.add(floor);

        // The exhibits are built one a frame (a script call has a time
        // budget, and the blob's 48 targets take a while).

        this.camera.position.set(0, 4.2, 10.5);
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.target.set(0, 1.3, 0);
        controls.update();
        this.controls = controls;
        return true;
    }

    /// A skinned tentacle: a 6 s clip holds a sway (frames 0-89 at 30 fps)
    /// and a curl (frames 90-179); subclip splits them, the curl becomes
    /// additive and plays over the sway.
    private tentacle(): THREE.Object3D {
        const height = TENTACLE_SEGMENT * <f64>TENTACLE_BONES;
        const geometry = new THREE.CylinderGeometry(0.08, 0.28, height, 20, TENTACLE_BONES * 6, false);
        geometry.translate(0, height / 2, 0);
        skinAlongY(geometry, TENTACLE_SEGMENT, TENTACLE_BONES);
        const bones = boneChain(TENTACLE_BONES + 1, TENTACLE_SEGMENT, "t");
        const mesh = new THREE.SkinnedMesh(geometry,
            new THREE.MeshStandardMaterial({ color: 0xe0b44c, roughness: 0.45 }));
        const root = new THREE.Group();
        root.position.set(-5.2, 0, 0.5);
        root.add(bones[0]);
        root.add(mesh);
        root.updateMatrixWorld(true);
        mesh.bind(new THREE.Skeleton(bones));

        // The long clip: sway on z for 3 s, then curl on x for 3 s.
        const tracks: Array<THREE.KeyframeTrack> = [];
        const z = new THREE.Vector3(0, 0, 1), x = new THREE.Vector3(1, 0, 0);
        const q = new THREE.Quaternion();
        for (let b = 1; b <= TENTACLE_BONES; b++) {
            const times: Array<f64> = [];
            const values: Array<f64> = [];
            for (let k = 0; k <= 12; k++) {
                const t = <f64>k * 0.5;   // 0 .. 6 s
                if (t < 3) q.setFromAxisAngle(z, 0.28 * Math.sin(t / 3 * Math.PI * 2 + <f64>b * 0.5));
                else q.setFromAxisAngle(x, 0.5 * Math.sin((t - 3) / 3 * Math.PI) * <f64>b / <f64>TENTACLE_BONES);
                times.push(t);
                values.push(q.x); values.push(q.y); values.push(q.z); values.push(q.w);
            }
            tracks.push(new THREE.QuaternionKeyframeTrack("t" + b.toString() + ".quaternion", times, values));
        }
        const performance = new THREE.AnimationClip("performance", -1, tracks);
        const sway = THREE.AnimationUtils.subclip(performance, "sway", 0, 90, 30);
        const curl = THREE.AnimationUtils.subclip(performance, "curl", 90, 181, 30);
        THREE.AnimationUtils.makeClipAdditive(curl);   // relative to its first frame
        this.mixer = new THREE.AnimationMixer(root);
        this.mixer.clipAction(sway).play();
        const action = this.mixer.clipAction(curl);
        action.setLoop(THREE.LoopPingPong, Infinity);
        action.play();
        this.curl = action;
        return root;
    }

    /// A sphere with BUMPS morph targets, each a bump towards one direction
    /// (positions and normals), blended on the GPU.
    private morphBlob(): THREE.Mesh {
        const radius = 0.9;
        const geometry = new THREE.SphereGeometry(radius, 72, 36);
        const position = geometry.getAttribute("position")!;
        const normal = geometry.getAttribute("normal")!;
        const n = position.count;
        // Unit directions of the vertices, once.
        const unit = new Float64Array(n * 3);
        for (let i = 0; i < n; i++) {
            const x = position.getX(i), y = position.getY(i), z = position.getZ(i);
            const l = Math.sqrt(x * x + y * y + z * z);
            unit[i * 3] = x / l; unit[i * 3 + 1] = y / l; unit[i * 3 + 2] = z / l;
        }
        const positionTargets: Array<THREE.BufferAttribute> = [];
        const normalTargets: Array<THREE.BufferAttribute> = [];
        for (let b = 0; b < BUMPS; b++) {
            // Directions on a Fibonacci sphere.
            const dy = 1 - 2 * (<f64>b + 0.5) / <f64>BUMPS;
            const r = Math.sqrt(1 - dy * dy);
            const phi = <f64>b * 2.399963229728653;
            const dx = Math.cos(phi) * r, dz = Math.sin(phi) * r;
            this.bumpDirections.push(new THREE.Vector3(dx, dy, dz));
            const deltas = new Float32Array(n * 3);
            const normals = new Float32Array(n * 3);
            for (let i = 0; i < n; i++) {
                const px = unit[i * 3], py = unit[i * 3 + 1], pz = unit[i * 3 + 2];
                const d = px * dx + py * dy + pz * dz;
                if (d < 0.4) continue;   // d^24 is nothing there
                // The bump h = BUMP_HEIGHT x d^24 along the sphere's normal; the
                // bumped surface's normal tilts by its slope (the gradient
                // of h along the sphere, over the radius there).
                const d23 = Math.pow(d, 23);
                const h = BUMP_HEIGHT * d23 * d;
                deltas[i * 3] = <f32>(px * h); deltas[i * 3 + 1] = <f32>(py * h); deltas[i * 3 + 2] = <f32>(pz * h);
                const k = BUMP_HEIGHT * 24 * d23 / (radius + h);
                let gx = px - (dx - d * px) * k, gy = py - (dy - d * py) * k, gz = pz - (dz - d * pz) * k;
                const gl = Math.sqrt(gx * gx + gy * gy + gz * gz);
                gx /= gl; gy /= gl; gz /= gl;
                normals[i * 3] = <f32>(gx - normal.getX(i));
                normals[i * 3 + 1] = <f32>(gy - normal.getY(i));
                normals[i * 3 + 2] = <f32>(gz - normal.getZ(i));
            }
            const pt = new THREE.BufferAttribute(deltas, 3);
            pt.name = "bump" + b.toString();
            positionTargets.push(pt);
            normalTargets.push(new THREE.BufferAttribute(normals, 3));
        }
        geometry.morphAttributes.set("position", positionTargets);
        geometry.morphAttributes.set("normal", normalTargets);
        geometry.morphTargetsRelative = true;
        const blob = new THREE.Mesh(geometry,
            new THREE.MeshStandardMaterial({ color: 0xff6b6b, roughness: 0.35, metalness: 0.05 }));
        blob.updateMorphTargets();
        blob.position.set(-2.4, 1.3, 0);
        // Its bounds grow with the bumps: never culled.
        blob.frustumCulled = false;
        this.blob = blob;
        return blob;
    }

    /// 64 gems, one InstancedMesh, each instance its own morph weights.
    private instancedGems(): THREE.InstancedMesh {
        const geometry = new THREE.OctahedronGeometry(0.22, 1);
        const position = geometry.getAttribute("position")!;
        const n = position.count;
        const stretch: Array<f64> = new Array<f64>(n * 3);
        const twist: Array<f64> = new Array<f64>(n * 3);
        const flat: Array<f64> = new Array<f64>(n * 3);
        for (let i = 0; i < n; i++) {
            const x = position.getX(i), y = position.getY(i), z = position.getZ(i);
            stretch[i * 3] = -x * 0.4; stretch[i * 3 + 1] = y * 1.6; stretch[i * 3 + 2] = -z * 0.4;
            const a = y * 6;
            twist[i * 3] = x * Math.cos(a) - z * Math.sin(a) - x;
            twist[i * 3 + 1] = 0;
            twist[i * 3 + 2] = x * Math.sin(a) + z * Math.cos(a) - z;
            flat[i * 3] = x * 0.6; flat[i * 3 + 1] = -y * 0.7; flat[i * 3 + 2] = z * 0.6;
        }
        geometry.morphAttributes.set("position", [new THREE.Float32BufferAttribute(stretch, 3),
            new THREE.Float32BufferAttribute(twist, 3), new THREE.Float32BufferAttribute(flat, 3)]);
        geometry.morphTargetsRelative = true;
        const count = GEMS_SIDE * GEMS_SIDE;
        const gems = new THREE.InstancedMesh(geometry,
            new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.25, metalness: 0.3, flatShading: true }),
            count);
        const m = new THREE.Matrix4();
        const color = new THREE.Color();
        for (let i = 0; i < count; i++) {
            const gx = i % GEMS_SIDE, gz = i / GEMS_SIDE;
            m.makeTranslation(<f64>gx * 0.42 - 1.47, 0.35, <f64>gz * 0.42 - 1.47);
            gems.setMatrixAt(i, m);
            color.setHSL(0.5 + <f64>i / <f64>count * 0.35, 0.7, 0.55);
            gems.setColorAt(i, color);
        }
        gems.position.set(1.0, 0, 0.4);
        gems.computeBoundingSphere();
        // A mesh holding the weights each instance gets (setMorphAt reads
        // its morphTargetInfluences).
        this.gemWeights = new THREE.Mesh(geometry);
        this.gemWeights.updateMorphTargets();
        this.gems = gems;
        this.updateGems(0);
        return gems;
    }

    /// A serpent of SERPENT_BONES bones: more than a uniform block holds,
    /// so its bones go to a bone texture.
    private serpent(): THREE.Object3D {
        const segment = SERPENT_LENGTH / <f64>SERPENT_BONES;
        const geometry = new THREE.CylinderGeometry(0.06, 0.16, SERPENT_LENGTH, 10, SERPENT_BONES, false);
        geometry.translate(0, SERPENT_LENGTH / 2, 0);
        skinAlongY(geometry, segment, SERPENT_BONES);
        const bones = boneChain(SERPENT_BONES + 1, segment, "s");
        const mesh = new THREE.SkinnedMesh(geometry,
            new THREE.MeshStandardMaterial({ color: 0x2ec4b6, roughness: 0.4 }));
        mesh.frustumCulled = false;
        const root = new THREE.Group();
        root.position.set(4.6, 0.25, 0.6);
        root.rotation.x = -Math.PI / 2;   // lies along -z, then coils up
        root.add(bones[0]);
        root.add(mesh);
        root.updateMatrixWorld(true);
        mesh.bind(new THREE.Skeleton(bones));
        this.serpentBones = bones;
        return root;
    }

    /// Five buoys bobbing from one action through an AnimationObjectGroup.
    private buoys(): THREE.Object3D {
        const row = new THREE.Group();
        const group = new THREE.AnimationObjectGroup();
        const geometry = new THREE.SphereGeometry(0.16, 24, 12);
        for (let i = 0; i < 5; i++) {
            const buoy = new THREE.Mesh(geometry,
                new THREE.MeshStandardMaterial({ color: i % 2 == 0 ? 0xf2f2f2 : 0xc4553d, roughness: 0.5 }));
            buoy.position.set(-2.6 + <f64>i * 1.3, 0.2, 3.2);
            row.add(buoy);
            group.add(buoy);
        }
        const bob = new THREE.AnimationClip("bob", -1, [
            new THREE.NumberKeyframeTrack(".position[y]", [0, 0.75, 1.5], [0.2, 0.55, 0.2], THREE.InterpolateSmooth),
            new THREE.NumberKeyframeTrack(".rotation[z]", [0, 0.75, 1.5], [-0.3, 0.3, -0.3], THREE.InterpolateSmooth),
        ]);
        this.groupMixer = new THREE.AnimationMixer(group);
        this.groupMixer.clipAction(bob).play();
        return row;
    }

    private updateGems(t: f64): void {
        const gems = this.gems;
        if (gems == null) return;
        const w = this.gemWeights.morphTargetInfluences;
        for (let i = 0; i < gems.count; i++) {
            const gx = <f64>(i % GEMS_SIDE), gz = <f64>(i / GEMS_SIDE);
            const phase = t * 2.2 - (gx + gz) * 0.45;
            w[0] = Math.max(0, Math.sin(phase)) * 0.9;
            w[1] = Math.max(0, Math.sin(phase * 0.5 + gx)) * 0.8;
            w[2] = Math.max(0, -Math.sin(phase)) * 0.8;
            gems.setMorphAt(i, this.gemWeights);
        }
        gems.morphTexture!.needsUpdate = true;
    }

    override animate(seconds: f64): void {
        if (this.built < 5) {
            const scene = this.scene;
            const k = this.built++;
            if (k == 0) scene.add(this.tentacle());
            else if (k == 1) scene.add(this.morphBlob());
            else if (k == 2) scene.add(this.instancedGems());
            else if (k == 3) scene.add(this.serpent());
            else scene.add(this.buoys());
            return;
        }
        const t = (this.time += seconds);
        this.mixer.update(seconds);
        this.groupMixer.update(seconds);
        const curl = this.curl;
        if (curl != null) curl.setEffectiveWeight(0.5 + 0.5 * Math.sin(t * 0.8));

        // A wave of bumps running down the blob.
        const infl = this.blob.morphTargetInfluences;
        for (let b = 0; b < BUMPS; b++) {
            const y = this.bumpDirections[b].y;
            infl[b] = Math.max(0, Math.sin(t * 2.5 + y * 4)) * 0.9;
        }
        this.blob.rotation.y = t * 0.3;

        this.updateGems(t);

        // The serpent: a travelling wave in two planes, rising into a coil.
        const bones = this.serpentBones;
        for (let i = 1; i < bones.length; i++) {
            const s = <f64>i / <f64>bones.length;
            const bone = bones[i];
            bone.rotation.x = 0.045 * Math.sin(t * 2.2 - s * 18) - (s > 0.35 ? 0.018 : 0);
            bone.rotation.z = 0.05 * Math.cos(t * 1.6 - s * 14);
        }
    }
}

/// Skin weights for a geometry along +y: each vertex between bones
/// floor(y / segment) and the next, weighted by where it falls.
function skinAlongY(geometry: THREE.BufferGeometry, segment: f64, segments: i32): void {
    const position = geometry.getAttribute("position")!;
    const indices: Array<f64> = [];
    const weights: Array<f64> = [];
    for (let i = 0; i < position.count; i++) {
        const y = position.getY(i);
        const index = Math.min(<f64>segments - 1, Math.max(0, Math.floor(y / segment)));
        const w = Math.min(1, Math.max(0, y / segment - index));
        indices.push(index); indices.push(index + 1); indices.push(0); indices.push(0);
        weights.push(1 - w); weights.push(w); weights.push(0); weights.push(0);
    }
    geometry.setAttribute("skinIndex", new THREE.Float32BufferAttribute(indices, 4));
    geometry.setAttribute("skinWeight", new THREE.Float32BufferAttribute(weights, 4));
}

/// `count` bones in a chain along +y, `segment` apart, named prefix + index.
function boneChain(count: i32, segment: f64, prefix: string): Array<THREE.Bone> {
    const bones: Array<THREE.Bone> = [];
    let prev: THREE.Bone? = null;
    for (let i = 0; i < count; i++) {
        const bone = new THREE.Bone();
        bone.name = prefix + i.toString();
        if (prev != null) {
            bone.position.y = segment;
            prev.add(bone);
        }
        bones.push(bone);
        prev = bone;
    }
    return bones;
}
