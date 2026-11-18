// three.js's webgl_mesh_batch, smaller: one BatchedMesh holding a box, a
// sphere, a torus knot and a cone, with 600 instances of them tumbling,
// each its own colour. Every geometry draws with one instanced call.

import * as THREE from "../three/Three";
import { Context } from "rive/host";
import { ThreeLayout } from "../three/rive/ThreeLayout";
import { OrbitControls } from "../three/addons/controls/OrbitControls";

const COUNT: i32 = 600;

export class Batched extends ThreeLayout {
    mesh: THREE.BatchedMesh? = null;
    positions: Array<THREE.Vector3> = [];
    spins: Array<THREE.Vector3> = [];
    euler: THREE.Euler = new THREE.Euler();
    matrix: THREE.Matrix4 = new THREE.Matrix4();
    quaternion: THREE.Quaternion = new THREE.Quaternion();
    scale: THREE.Vector3 = new THREE.Vector3(1, 1, 1);
    time: f64 = 0;

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = new THREE.Color(0x101318);
        scene.add(new THREE.HemisphereLight(0xdde8ff, 0x302820, 1.5));
        const sun = new THREE.DirectionalLight(0xffffff, 2);
        sun.position.set(3, 5, 4);
        scene.add(sun);

        const geometries: Array<THREE.BufferGeometry> = [
            new THREE.BoxGeometry(0.5, 0.5, 0.5),
            new THREE.SphereGeometry(0.3, 16, 12),
            new THREE.TorusKnotGeometry(0.22, 0.07, 64, 8),
            new THREE.ConeGeometry(0.3, 0.6, 16),
        ];
        let vertices = 0, indices = 0;
        for (let i = 0; i < geometries.length; i++) {
            vertices += geometries[i].getAttribute("position")!.count;
            indices += geometries[i].index!.count;
        }
        const mesh = new THREE.BatchedMesh(COUNT, vertices, indices,
            new THREE.MeshStandardMaterial({ roughness: 0.45, metalness: 0.1 }));
        const ids: Array<i32> = [];
        for (let i = 0; i < geometries.length; i++) ids.push(mesh.addGeometry(geometries[i]));

        const color = new THREE.Color();
        for (let i = 0; i < COUNT; i++) {
            const id = mesh.addInstance(ids[i % ids.length]);
            // A shell of radius 3 to 6.
            const p = new THREE.Vector3(Math.random() * 2 - 1, Math.random() * 2 - 1, Math.random() * 2 - 1)
                .normalize().multiplyScalar(3 + Math.random() * 3);
            this.positions.push(p);
            this.spins.push(new THREE.Vector3(Math.random() * 2 - 1, Math.random() * 2 - 1, Math.random() * 2 - 1));
            mesh.setColorAt(id, color.setHSL(Math.random(), 0.65, 0.55));
        }
        scene.add(mesh);
        this.mesh = mesh;

        this.camera.position.set(0, 4, 13);
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.autoRotate = true;
        controls.enableDamping = true;
        this.controls = controls;
        return true;
    }

    override animate(seconds: f64): void {
        this.time += seconds;
        const mesh = this.mesh;
        if (mesh == null) return;
        for (let i = 0; i < COUNT; i++) {
            const s = this.spins[i];
            this.euler.set(s.x * this.time, s.y * this.time, s.z * this.time);
            this.quaternion.setFromEuler(this.euler);
            this.matrix.compose(this.positions[i], this.quaternion, this.scale);
            mesh.setMatrixAt(i, this.matrix);
        }
    }
}
