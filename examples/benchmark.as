// Benchmark: many separate meshes (per-object draws) plus one instanced
// mesh, all moving every frame. rive . --artboard=Benchmark --bench=300

import * as THREE from "../three/Three";
import { Context } from "rive/host";

export class Benchmark extends THREE.ThreeLayout {
    /// Separate meshes (each its own draw).
    @input meshes: i32 = 1000;
    /// Instances in the instanced mesh.
    @input instances: i32 = 10000;
    cubes: Array<THREE.Mesh> = [];
    swarm: THREE.InstancedMesh? = null;
    time: f64 = 0;
    private dummy: THREE.Object3D = new THREE.Object3D();

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = new THREE.Color(0x111318);
        scene.add(new THREE.HemisphereLight(0xffffff, 0x404050, 1.2));
        const sun = new THREE.DirectionalLight(0xffffff, 2);
        sun.position.set(3, 5, 4);
        scene.add(sun);
        const geometry = new THREE.BoxGeometry(0.3, 0.3, 0.3);
        const materials: Array<THREE.Material> = [];
        for (let i = 0; i < 8; i++) {
            const c = new THREE.Color().setHSL(<f64>i / 8, 0.6, 0.55);
            materials.push(new THREE.MeshStandardMaterial({ color: c.getHex(), roughness: 0.5 }));
        }
        const side = <i32>Math.ceil(Math.cbrt(<f64>this.meshes));
        for (let i = 0; i < this.meshes; i++) {
            const m = new THREE.Mesh(geometry, materials[i % 8]);
            const x = i % side, y = (i / side) % side, z = i / (side * side);
            m.position.set((<f64>x - <f64>side / 2) * 0.5, (<f64>y - <f64>side / 2) * 0.5, (<f64>z - <f64>side / 2) * 0.5);
            scene.add(m);
            this.cubes.push(m);
        }
        const swarm = new THREE.InstancedMesh(new THREE.IcosahedronGeometry(0.05, 0),
            new THREE.MeshLambertMaterial({ color: 0xffcc66 }), this.instances);
        scene.add(swarm);
        this.swarm = swarm;
        this.camera.position.set(0, 2, 12);
        this.camera.lookAt(0, 0, 0);
        return true;
    }

    override animate(seconds: f64): void {
        const t = (this.time += seconds);
        for (let i = 0; i < this.cubes.length; i++) {
            const m = this.cubes[i];
            m.rotation.x = t + <f64>i * 0.01;
            m.rotation.y = t * 0.7 + <f64>i * 0.02;
        }
        const swarm = this.swarm;
        if (swarm == null) return;
        const d = this.dummy;
        for (let i = 0; i < swarm.count; i++) {
            const a = <f64>i * 0.618 + t * 0.2;
            const r = 3 + (<f64>(i % 100)) * 0.03;
            d.position.set(Math.cos(a) * r, Math.sin(<f64>i * 0.37 + t) * 2, Math.sin(a) * r);
            d.updateMatrix();
            swarm.setMatrixAt(i, d.matrix);
        }
        swarm.instanceMatrix.needsUpdate = true;
    }
}
