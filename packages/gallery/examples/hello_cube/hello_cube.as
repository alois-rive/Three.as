// three.js's "Creating a scene" tutorial
// (https://threejs.org/manual/#en/creating-a-scene), ported: the same
// calls, with types, a GPURenderer instead of a WebGLRenderer, and Rive's
// Layout hooks in place of the window and requestAnimationFrame.

import * as THREE from "../../three/Three";
import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";

export class HelloCube extends Layout {
    scene: THREE.Scene = new THREE.Scene();
    camera: THREE.PerspectiveCamera = new THREE.PerspectiveCamera(75, 1, 0.1, 1000);
    renderer: THREE.GPURenderer? = null;
    cube: THREE.Mesh = new THREE.Mesh();

    override init(context: Context): bool {
        this.renderer = new THREE.GPURenderer(context, { antialias: true });

        const geometry = new THREE.BoxGeometry(1, 1, 1);
        const material = new THREE.MeshBasicMaterial({ color: 0x00ff00 });
        this.cube = new THREE.Mesh(geometry, material);
        this.scene.add(this.cube);

        this.camera.position.z = 5;
        return true;
    }

    // The window resize handler.
    override resize(width: f64, height: f64, scale: f64): void {
        const renderer = this.renderer!;
        renderer.setPixelRatio(scale);
        renderer.setSize(width, height);
        this.camera.aspect = width / height;
        this.camera.updateProjectionMatrix();
    }

    // The animation loop: three.js rotates by 0.01 per frame.
    override advance(seconds: f64): bool {
        this.cube.rotation.x += 0.6 * seconds;
        this.cube.rotation.y += 0.6 * seconds;
        return true;
    }

    override draw(renderer: Renderer): void {
        const r = this.renderer!;
        r.render(this.scene, this.camera);
        r.present(renderer);
    }
}
