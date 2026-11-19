// FirstScene: a lit scene with a live Rive artboard as the cube's texture.
//
//   - The cube's MeshStandardMaterial maps an ArtboardTexture of the
//     `screen` input artboard, which plays its own state machine.
//   - The floor is a DataTexture checkerboard, repeated.
//   - A metal sphere and a blue point light orbit the cube.
//   - `speed` (a script input) scales time, so Rive can animate or bind it.

import * as THREE from "lib:threeas/three/Three";
import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { Artboard } from "rive/artboard";

/// A size x size RGBA checkerboard of `cells` x `cells` squares.
function checkerTexture(size: i32, cells: i32, a: u32, b: u32): THREE.DataTexture {
    const data = new Uint8Array(size * size * 4);
    const cell = size / cells;
    for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
            const c = ((x / cell + y / cell) & 1) == 0 ? a : b;
            const o = (y * size + x) * 4;
            data[o] = <u8>((c >> 16) & 0xFF);
            data[o + 1] = <u8>((c >> 8) & 0xFF);
            data[o + 2] = <u8>(c & 0xFF);
            data[o + 3] = 255;
        }
    }
    const texture = new THREE.DataTexture(data, size, size);
    texture.colorSpace = THREE.SRGBColorSpace;
    return texture;
}

export class FirstScene extends Layout {
    /// The artboard shown on the cube.
    @input screen: Artboard? = null;
    /// Time scale.
    @input speed: f64 = 1;

    renderer: THREE.GPURenderer? = null;
    scene: THREE.Scene = new THREE.Scene();
    camera: THREE.PerspectiveCamera = new THREE.PerspectiveCamera(45, 1, 0.1, 100);
    cubeMaterial: THREE.MeshStandardMaterial = new THREE.MeshStandardMaterial({ roughness: 0.4, metalness: 0.05 });
    cube: THREE.Mesh = new THREE.Mesh();
    sphere: THREE.Mesh = new THREE.Mesh();
    blueLight: THREE.PointLight = new THREE.PointLight(0x5fa8ff, 8, 0, 2);
    screenTexture: THREE.ArtboardTexture? = null;
    time: f64 = 0;

    override init(context: Context): bool {
        this.renderer = new THREE.GPURenderer(context, { antialias: true });
        const scene = this.scene;
        scene.background = new THREE.Color(0x0e1116);

        this.camera.position.set(0, 2.2, 5.5);
        this.camera.lookAt(0, 0.6, 0);

        // The cube, its texture attached once the input is bound.
        this.cube = new THREE.Mesh(new THREE.BoxGeometry(1.6, 1.6, 1.6), this.cubeMaterial);
        this.cube.position.y = 1.1;
        scene.add(this.cube);

        // The floor.
        const checker = checkerTexture(64, 2, 0x2a2f3a, 0x3a4150);
        checker.wrapS = THREE.RepeatWrapping;
        checker.wrapT = THREE.RepeatWrapping;
        checker.repeat.set(8, 8);
        const floor = new THREE.Mesh(
            new THREE.PlaneGeometry(16, 16),
            new THREE.MeshStandardMaterial({ map: checker, roughness: 0.9 }));
        floor.rotation.x = -Math.PI / 2;
        scene.add(floor);

        // A metal sphere.
        this.sphere = new THREE.Mesh(
            new THREE.SphereGeometry(0.35, 48, 24),
            new THREE.MeshStandardMaterial({ color: 0xffb020, metalness: 1, roughness: 0.3 }));
        scene.add(this.sphere);

        // Lights.
        scene.add(new THREE.AmbientLight(0xffffff, 1.5));
        const sun = new THREE.DirectionalLight(0xfff2e0, 3);
        sun.position.set(3, 6, 4);
        scene.add(sun);
        scene.add(this.blueLight);
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
        // The artboard input may be bound after init: attach it when it is.
        let texture = this.screenTexture;
        const screen = this.screen;
        if (texture == null && screen != null) {
            texture = new THREE.ArtboardTexture(screen, 512, 512);
            this.screenTexture = texture;
            this.cubeMaterial.map = texture;
        }
        const dt = seconds * this.speed;
        if (texture != null) texture.advance(dt);

        const t = (this.time += dt);
        this.cube.rotation.y = t * 0.5;
        this.cube.rotation.x = Math.sin(t * 0.4) * 0.25;
        this.sphere.position.set(Math.cos(t) * 2.2, 0.6 + Math.sin(t * 2) * 0.25, Math.sin(t) * 2.2);
        this.blueLight.position.set(Math.cos(t + Math.PI) * 2.5, 1.8, Math.sin(t + Math.PI) * 2.5);
        return true;
    }

    override draw(renderer: Renderer): void {
        const r = this.renderer!;
        r.render(this.scene, this.camera);
        r.present(renderer);
    }
}
