// Shadows: shadow maps from a directional sun (PCF soft), a spot light and
// a point light (six faces), cast by moving objects onto the floor and
// each other. A lattice (alphaMap + alphaTest) casts a cut-out shadow; a
// sphere with alphaHash is stochastically see-through, shadow included.

import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";
import { Context } from "rive/host";

export class Shadows extends THREE.ThreeLayout {
    movers: Array<THREE.Object3D> = [];
    lamp: THREE.PointLight = new THREE.PointLight(0xffa040, 6, 0, 2);
    bulb: THREE.Mesh = new THREE.Mesh();
    time: f64 = 0;

    override setup(context: Context): bool {
        const renderer = this.renderer!;
        renderer.shadowMap.enabled = true;
        renderer.shadowMap.type = THREE.PCFSoftShadowMap;
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        const scene = this.scene;
        scene.background = new THREE.Color(0x14161c);
        scene.add(new THREE.HemisphereLight(0xb8c8ff, 0x302820, 0.6));

        const sun = new THREE.DirectionalLight(0xfff1dc, 2.6);
        sun.position.set(4, 7, 3);
        sun.castShadow = true;
        sun.shadow.mapSize.set(2048, 2048);
        sun.shadow.bias = -0.0005;
        sun.shadow.normalBias = 0.02;
        const sc = sun.shadow.camera as THREE.OrthographicCamera;
        sc.left = -6; sc.right = 6; sc.top = 6; sc.bottom = -6; sc.near = 0.5; sc.far = 20;
        sc.updateProjectionMatrix();
        scene.add(sun);

        const spot = new THREE.SpotLight(0x6fa8ff, 40, 0, 0.45, 0.4, 2);
        spot.position.set(-4, 5, 2);
        spot.castShadow = true;
        spot.shadow.bias = -0.0005;
        spot.shadow.normalBias = 0.02;
        scene.add(spot);

        this.lamp.position.set(1.8, 1.2, -1.2);
        this.lamp.castShadow = true;
        this.lamp.shadow.bias = -0.002;
        this.lamp.shadow.normalBias = 0.02;
        scene.add(this.lamp);
        this.bulb = new THREE.Mesh(new THREE.SphereGeometry(0.08, 16, 8), new THREE.MeshBasicMaterial({ color: 0xffd8a0 }));
        scene.add(this.bulb);

        const floor = new THREE.Mesh(new THREE.PlaneGeometry(16, 16),
            new THREE.MeshStandardMaterial({ color: 0x8a8f99, roughness: 0.9 }));
        floor.rotation.x = -Math.PI / 2;
        floor.receiveShadow = true;
        scene.add(floor);

        const back = new THREE.Mesh(new THREE.BoxGeometry(8, 3, 0.2),
            new THREE.MeshStandardMaterial({ color: 0x6b7280, roughness: 0.8 }));
        back.position.set(0, 1.5, -3);
        back.receiveShadow = true;
        back.castShadow = true;
        scene.add(back);

        const shapes: Array<THREE.BufferGeometry> = [
            new THREE.TorusKnotGeometry(0.45, 0.15, 128, 16),
            new THREE.BoxGeometry(0.9, 0.9, 0.9),
            new THREE.ConeGeometry(0.5, 1.2, 32),
            new THREE.SphereGeometry(0.5, 32, 16),
        ];
        const colors: Array<u32> = [0xef476f, 0xffd166, 0x06d6a0, 0x118ab2];
        for (let i = 0; i < shapes.length; i++) {
            const m = new THREE.Mesh(shapes[i], new THREE.MeshStandardMaterial({ color: colors[i], roughness: 0.45 }));
            m.position.set(<f64>i * 1.6 - 2.4, 1.0, 0.2);
            m.castShadow = true;
            m.receiveShadow = true;
            scene.add(m);
            this.movers.push(m);
        }

        // A lattice: an alphaMap cut out by alphaTest, in the shadows too.
        const holes = new Uint8Array(32 * 32 * 4);
        for (let y = 0; y < 32; y++) {
            for (let x = 0; x < 32; x++) {
                const on: u8 = ((x / 4) % 2 == 0 || (y / 4) % 2 == 0) ? 255 : 0;
                const o = (y * 32 + x) * 4;
                holes[o] = on; holes[o + 1] = on; holes[o + 2] = on; holes[o + 3] = 255;
            }
        }
        const alphaMap = new THREE.DataTexture(holes, 32, 32);
        const lattice = new THREE.Mesh(new THREE.PlaneGeometry(1.6, 1.6), new THREE.MeshStandardMaterial({
            color: 0xc0c4cc, alphaMap: alphaMap, alphaTest: 0.5, side: THREE.DoubleSide,
        }));
        lattice.position.set(-3.2, 1.6, 1.4);
        lattice.rotation.set(-0.5, 0.6, 0);
        lattice.castShadow = true;
        scene.add(lattice);
        const ghost = new THREE.Mesh(new THREE.SphereGeometry(0.5, 32, 16), new THREE.MeshStandardMaterial({
            color: 0x9b5de5, opacity: 0.5, alphaHash: true,
        }));
        ghost.position.set(3.0, 1.0, 1.6);
        ghost.castShadow = true;
        scene.add(ghost);

        this.camera.position.set(0, 4.2, 7.5);
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.target.set(0, 0.8, 0);
        controls.update();
        this.controls = controls;
        return true;
    }

    override animate(seconds: f64): void {
        const t = (this.time += seconds);
        for (let i = 0; i < this.movers.length; i++) {
            const m = this.movers[i];
            m.rotation.y = t * 0.6 + <f64>i;
            m.rotation.x = t * 0.3;
            m.position.y = 1.0 + Math.sin(t * 1.5 + <f64>i) * 0.35;
        }
        this.lamp.position.set(Math.cos(t * 0.8) * 1.8, 1.4, Math.sin(t * 0.8) * 1.2 - 1.0);
        this.bulb.position.copy(this.lamp.position);
    }
}
