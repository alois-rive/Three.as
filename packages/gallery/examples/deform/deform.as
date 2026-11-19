// Deform: three.js's SkinnedMesh example (a cylinder bent by a chain of
// bones, skinned on the GPU) and its morph targets example (a box that
// morphs to a sphere and twists), animated with an AnimationMixer.

import * as THREE from "../../three/Three";
import { OrbitControls } from "../../three/addons/controls/OrbitControls";
import { Context } from "rive/host";

const SEGMENT_HEIGHT: f64 = 0.8;
const SEGMENTS: i32 = 4;

export class Deform extends THREE.ThreeLayout {
    mixer: THREE.AnimationMixer = new THREE.AnimationMixer(new THREE.Object3D());
    bones: Array<THREE.Bone> = [];
    morphing: THREE.Mesh = new THREE.Mesh();
    time: f64 = 0;

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = new THREE.Color(0x15171c);
        scene.add(new THREE.HemisphereLight(0xdde6ff, 0x2a2420, 1.8));
        const sun = new THREE.DirectionalLight(0xffffff, 2.5);
        sun.position.set(3, 5, 4);
        scene.add(sun);

        scene.add(this.skinnedCylinder());
        scene.add(this.morphingBox());

        this.camera.position.set(0, 2.2, 7.5);
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.target.set(0, 1.6, 0);
        controls.update();
        this.controls = controls;
        return true;
    }

    /// three.js's SkinnedMesh documentation example.
    private skinnedCylinder(): THREE.Object3D {
        const height = SEGMENT_HEIGHT * <f64>SEGMENTS;
        const geometry = new THREE.CylinderGeometry(0.35, 0.35, height, 24, SEGMENTS * 4, true);
        geometry.translate(0, height / 2, 0);
        const position = geometry.getAttribute("position")!;
        const indices: Array<f64> = [];
        const weights: Array<f64> = [];
        for (let i = 0; i < position.count; i++) {
            const y = position.getY(i);
            const skinIndex = Math.floor(y / SEGMENT_HEIGHT);
            const skinWeight = (y % SEGMENT_HEIGHT) / SEGMENT_HEIGHT;
            indices.push(skinIndex); indices.push(skinIndex + 1); indices.push(0); indices.push(0);
            weights.push(1 - skinWeight); weights.push(skinWeight); weights.push(0); weights.push(0);
        }
        geometry.setAttribute("skinIndex", new THREE.Float32BufferAttribute(indices, 4));
        geometry.setAttribute("skinWeight", new THREE.Float32BufferAttribute(weights, 4));

        let prev: THREE.Bone? = null;
        for (let i = 0; i <= SEGMENTS; i++) {
            const bone = new THREE.Bone();
            bone.name = "bone" + i.toString();
            if (prev != null) {
                bone.position.y = SEGMENT_HEIGHT;
                prev.add(bone);
            }
            this.bones.push(bone);
            prev = bone;
        }
        const mesh = new THREE.SkinnedMesh(geometry,
            new THREE.MeshStandardMaterial({ color: 0x2ec4b6, roughness: 0.5, side: THREE.DoubleSide, flatShading: true }));
        const root = new THREE.Group();
        root.position.x = -1.5;
        root.add(this.bones[0]);
        root.add(mesh);
        root.updateMatrixWorld(true);
        mesh.bind(new THREE.Skeleton(this.bones));

        // A clip swinging every bone (driven by the mixer).
        const tracks: Array<THREE.KeyframeTrack> = [];
        for (let i = 1; i <= SEGMENTS; i++) {
            const q0 = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), 0.45);
            const q1 = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), -0.45);
            tracks.push(new THREE.QuaternionKeyframeTrack("bone" + i.toString() + ".quaternion", [0, 1, 2],
                [q0.x, q0.y, q0.z, q0.w, q1.x, q1.y, q1.z, q1.w, q0.x, q0.y, q0.z, q0.w]));
        }
        this.mixer = new THREE.AnimationMixer(root);
        this.mixer.clipAction(new THREE.AnimationClip("swing", -1, tracks)).play();
        return root;
    }

    /// three.js's webgl_morphtargets: a box with "spherify" and "twist".
    private morphingBox(): THREE.Mesh {
        const geometry = new THREE.BoxGeometry(1.6, 1.6, 1.6, 24, 24, 24);
        const position = geometry.getAttribute("position")!;
        const spherify: Array<f64> = [];
        const twist: Array<f64> = [];
        const v = new THREE.Vector3();
        const axis = new THREE.Vector3(1, 0, 0);
        for (let i = 0; i < position.count; i++) {
            const x = position.getX(i), y = position.getY(i), z = position.getZ(i);
            spherify.push(x * Math.sqrt(1 - (y * y / 2) - (z * z / 2) + (y * y * z * z / 3)));
            spherify.push(y * Math.sqrt(1 - (z * z / 2) - (x * x / 2) + (z * z * x * x / 3)));
            spherify.push(z * Math.sqrt(1 - (x * x / 2) - (y * y / 2) + (x * x * y * y / 3)));
            v.set(x * 2, y, z).applyAxisAngle(axis, Math.PI * x / 2);
            twist.push(v.x); twist.push(v.y); twist.push(v.z);
        }
        const a = new THREE.Float32BufferAttribute(spherify, 3);
        a.name = "spherify";
        const b = new THREE.Float32BufferAttribute(twist, 3);
        b.name = "twist";
        geometry.morphAttributes.set("position", [a, b]);
        this.morphing = new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({ color: 0xff6b6b, roughness: 0.4, flatShading: true }));
        this.morphing.updateMorphTargets();
        this.morphing.position.set(1.6, 1.6, 0);
        return this.morphing;
    }

    override animate(seconds: f64): void {
        const t = (this.time += seconds);
        this.mixer.update(seconds);
        const influences = this.morphing.morphTargetInfluences;
        influences[0] = Math.sin(t * 1.2) * 0.5 + 0.5;
        influences[1] = Math.max(0, Math.sin(t * 0.7)) * 0.5;
        this.morphing.rotation.y = t * 0.4;
    }
}
