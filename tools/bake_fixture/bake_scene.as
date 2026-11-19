// tools/bake_e2e.sh's test project: a scene that imports the engine as a
// library, as any project does, with materials, lights, fog and shadows to
// give a few program keys. `lit` 0 and 1 (two artboards) share some keys;
// after 4 s a toon mesh appears (only a --scenario that plays longer than
// the default --time=3s records its key).

import * as THREE from "lib:threeas/three/Three";
import { Context } from "rive/host";

export class BakeScene extends THREE.ThreeLayout {
    @input lit: f64 = 0;
    time: f64 = 0;
    meshes: Array<THREE.Mesh> = [];
    late: bool = false;

    override setup(context: Context): bool {
        const scene = this.scene;
        scene.background = new THREE.Color(0x15171c);
        const sun = new THREE.DirectionalLight(0xffffff, 2.5);
        sun.position.set(3, 5, 4);
        scene.add(sun);
        const geometry = new THREE.TorusKnotGeometry(0.45, 0.16, 96, 16);
        const materials: Array<THREE.Material> = [
            new THREE.MeshStandardMaterial({ color: 0x4f9de8, roughness: 0.4, metalness: 0.2 }),
            new THREE.MeshPhongMaterial({ color: 0xe8a04f, shininess: 60 }),
            new THREE.MeshBasicMaterial({ color: 0x8be04f }),
        ];
        if (this.lit > 0) {
            const lamp = new THREE.PointLight(0xffaa66, 6, 0, 2);
            lamp.position.set(-2, 1.5, 2);
            scene.add(lamp);
            scene.add(new THREE.HemisphereLight(0x8899ff, 0x221100, 0.8));
            scene.fog = new THREE.Fog(0x15171c, 4, 12);
            sun.castShadow = true;
            this.renderer!.shadowMap.enabled = true;
            materials.push(new THREE.MeshPhysicalMaterial({ color: 0xd04fe8, roughness: 0.3, clearcoat: 1 }));
            const floor = new THREE.Mesh(new THREE.PlaneGeometry(8, 8), new THREE.MeshLambertMaterial({ color: 0x777777 }));
            floor.rotation.x = -Math.PI / 2;
            floor.position.y = -0.9;
            floor.receiveShadow = true;
            scene.add(floor);
        }
        for (let i = 0; i < materials.length; i++) {
            const m = new THREE.Mesh(geometry, materials[i]);
            m.position.x = (<f64>i - <f64>(materials.length - 1) / 2) * 1.3;
            m.castShadow = true;
            scene.add(m);
            this.meshes.push(m);
        }
        this.camera.position.set(0, 1.2, 5);
        this.camera.lookAt(0, 0, 0);
        return true;
    }

    override animate(seconds: f64): void {
        this.time += seconds;
        for (let i = 0; i < this.meshes.length; i++) this.meshes[i].rotation.y += seconds * (0.5 + 0.1 * <f64>i);
        if (!this.late && this.time > 4) {
            this.late = true;
            const toon = new THREE.Mesh(new THREE.SphereGeometry(0.3, 32, 16), new THREE.MeshToonMaterial({ color: 0xffdd55 }));
            toon.position.y = 1.1;
            this.scene.add(toon);
        }
    }
}
