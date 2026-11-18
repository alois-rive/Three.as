// Environment: image-based lighting. A procedural studio (sky, two
// softboxes, a warm key, the floor) as an equirectangular map is the
// scene's environment and its (blurred) background; spheres sweep
// metalness (rows) against roughness (columns), lit by nothing else.

import * as THREE from "../three/Three";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { Context } from "rive/host";

/// A width x 2 equirectangular studio, sRGB bytes, bottom row first.
function studio(width: i32): THREE.DataTexture {
    const height = width / 2;
    const data = new Uint8Array(width * height * 4);
    for (let y = 0; y < height; y++) {
        const lat = (<f64>y + 0.5) / <f64>height * Math.PI - Math.PI / 2;   // -pi/2 .. pi/2
        for (let x = 0; x < width; x++) {
            const lon = (<f64>x + 0.5) / <f64>width * Math.PI * 2 - Math.PI;
            let r: f64, g: f64, b: f64;
            if (lat > 0) {
                const t = lat / (Math.PI / 2);
                r = 120 - 70 * t; g = 130 - 70 * t; b = 150 - 60 * t;
            } else {
                r = 70; g = 62; b = 56;
            }
            // Two cool softboxes and a warm key.
            if (Math.abs(lat - 0.5) < 0.22 && (Math.abs(lon - 0.9) < 0.35 || Math.abs(lon + 1.6) < 0.3)) {
                r = 255; g = 255; b = 255;
            }
            const dl = lat - 0.9, dn = lon - 2.4;
            if (dl * dl + dn * dn < 0.05) { r = 255; g = 214; b = 160; }
            const o = (y * width + x) * 4;
            data[o] = <u8>r; data[o + 1] = <u8>g; data[o + 2] = <u8>b; data[o + 3] = 255;
        }
    }
    const t = new THREE.DataTexture(data, width, height);
    t.colorSpace = THREE.SRGBColorSpace;
    t.magFilter = THREE.LinearFilter;
    return t;
}

export class Environment extends THREE.ThreeLayout {
    knot: THREE.Mesh = new THREE.Mesh();

    override setup(context: Context): bool {
        const renderer = this.renderer!;
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        const pmrem = new THREE.PMREMGenerator(renderer);
        const env = pmrem.fromEquirectangular(studio(256)).texture;
        this.scene.environment = env;
        this.scene.background = env;
        this.scene.backgroundBlurriness = 0.35;
        this.scene.backgroundIntensity = 0.8;

        const sphere = new THREE.SphereGeometry(0.38, 48, 24);
        for (let row = 0; row < 3; row++) {
            for (let col = 0; col < 5; col++) {
                const m = new THREE.MeshStandardMaterial({
                    color: row == 1 ? 0xffc35a : 0xd8dde6,
                    metalness: <f64>row * 0.5,
                    roughness: 0.05 + <f64>col / 4 * 0.9,
                });
                const mesh = new THREE.Mesh(sphere, m);
                mesh.position.set(<f64>col * 0.95 - 1.9, 1.0 - <f64>row * 0.95, 0);
                this.scene.add(mesh);
            }
        }
        this.knot = new THREE.Mesh(new THREE.TorusKnotGeometry(0.35, 0.11, 160, 20),
            new THREE.MeshPhysicalMaterial({ color: 0xb01030, roughness: 0.5, clearcoat: 1, clearcoatRoughness: 0.05 }));
        this.knot.position.set(0, 2.0, -0.5);
        this.scene.add(this.knot);

        this.camera.position.set(0, 0.6, 5.2);
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.target.set(0, 0.5, 0);
        controls.update();
        this.controls = controls;
        return true;
    }

    override animate(seconds: f64): void {
        this.knot.rotation.y += seconds * 0.5;
    }
}
