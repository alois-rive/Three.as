// Geometries: every built-in geometry, after three.js's webgl_geometries
// example, wearing a UV grid so texture coordinates and seams show.

import * as THREE from "lib:threeas/three/Three";
import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";

/// A size x size grid of `cells` x `cells` coloured squares (hue along u,
/// lightness along v) with dark lines, bottom row first.
function uvGridTexture(size: i32, cells: i32): THREE.DataTexture {
    const data = new Uint8Array(size * size * 4);
    const cell = size / cells;
    // One colour per cell (the per-pixel loop only copies bytes).
    const palette = new StaticArray<u32>(cells * cells);
    const color = new THREE.Color();
    for (let cy = 0; cy < cells; cy++) {
        for (let cx = 0; cx < cells; cx++) {
            color.setHSL(<f64>cx / <f64>cells, 0.65, 0.3 + 0.4 * <f64>cy / <f64>cells);
            palette[cy * cells + cx] = color.getHex();
        }
    }
    for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
            const hex: u32 = x % cell != 0 && y % cell != 0 ? palette[(y / cell) * cells + x / cell] : 0x202020;
            const o = (y * size + x) * 4;
            data[o] = <u8>((hex >> 16) & 0xFF);
            data[o + 1] = <u8>((hex >> 8) & 0xFF);
            data[o + 2] = <u8>(hex & 0xFF);
            data[o + 3] = 255;
        }
    }
    const texture = new THREE.DataTexture(data, size, size);
    texture.colorSpace = THREE.SRGBColorSpace;
    texture.magFilter = THREE.LinearFilter;
    texture.minFilter = THREE.LinearFilter;
    texture.wrapS = THREE.RepeatWrapping;
    texture.wrapT = THREE.RepeatWrapping;
    return texture;
}

export class Geometries extends Layout {
    renderer: THREE.GPURenderer? = null;
    scene: THREE.Scene = new THREE.Scene();
    camera: THREE.PerspectiveCamera = new THREE.PerspectiveCamera(40, 1, 0.1, 100);
    shapes: Array<THREE.Mesh> = [];
    time: f64 = 0;

    override init(context: Context): bool {
        this.renderer = new THREE.GPURenderer(context, { antialias: true });
        const scene = this.scene;
        scene.background = new THREE.Color(0x15171c);
        scene.add(new THREE.AmbientLight(0xffffff, 2.2));
        const sun = new THREE.DirectionalLight(0xffffff, 2.5);
        sun.position.set(2, 4, 5);
        scene.add(sun);

        const material = new THREE.MeshStandardMaterial({
            map: uvGridTexture(256, 8), side: THREE.DoubleSide, roughness: 0.6,
        });
        const geometries: Array<THREE.BufferGeometry> = [
            new THREE.SphereGeometry(0.75, 20, 10),
            new THREE.IcosahedronGeometry(0.75, 1),
            new THREE.OctahedronGeometry(0.75, 0),
            new THREE.TetrahedronGeometry(0.75, 0),
            new THREE.PlaneGeometry(1.5, 1.5, 4, 4),
            new THREE.BoxGeometry(1.2, 1.2, 1.2, 2, 2, 2),
            new THREE.CircleGeometry(0.75, 20, 0, Math.PI * 2),
            new THREE.RingGeometry(0.3, 0.75, 20, 5, 0, Math.PI * 2),
            new THREE.CylinderGeometry(0.4, 0.7, 1.2, 20, 5),
            new THREE.ConeGeometry(0.7, 1.3, 20, 3),
            new THREE.LatheGeometry(lathePoints(), 20),
            new THREE.TorusGeometry(0.5, 0.2, 20, 20),
            new THREE.TorusKnotGeometry(0.45, 0.14, 64, 10),
            new THREE.CapsuleGeometry(0.35, 0.6, 6, 16),
            new THREE.DodecahedronGeometry(0.75, 0),
            new THREE.CylinderGeometry(0.6, 0.6, 1, 6, 1, true, 0, Math.PI * 1.5),
        ];
        for (let i = 0; i < geometries.length; i++) {
            const mesh = new THREE.Mesh(geometries[i], material);
            const column = i % 4, row = i / 4;   // integer division
            mesh.position.set(<f64>column * 2.2 - 3.3, 2.85 - <f64>row * 1.9, 0);
            scene.add(mesh);
            this.shapes.push(mesh);
        }
        this.camera.position.set(0, 0.6, 13);
        this.camera.lookAt(0, 0, 0);
        return true;
    }

    override resize(width: f64, height: f64, scale: f64): void {
        const renderer = this.renderer!;
        renderer.setPixelRatio(scale);
        renderer.setSize(width, height);
        this.camera.aspect = width / height;
        this.camera.updateProjectionMatrix();
    }

    override advance(seconds: f64): bool {
        const t = (this.time += seconds);
        for (let i = 0; i < this.shapes.length; i++) {
            this.shapes[i].rotation.x = 0.35 + Math.sin(t * 0.5) * 0.25;
            this.shapes[i].rotation.y = t * 0.4 + 0.5;
        }
        return true;
    }

    override draw(renderer: Renderer): void {
        const r = this.renderer!;
        r.render(this.scene, this.camera);
        r.present(renderer);
    }
}

function lathePoints(): Array<THREE.Vector2> {
    const points: Array<THREE.Vector2> = [];
    for (let i = 0; i < 10; i++) {
        points.push(new THREE.Vector2(Math.sin(<f64>i * 0.2) * 0.6 + 0.15, (<f64>i - 5) * 0.14));
    }
    return points;
}
