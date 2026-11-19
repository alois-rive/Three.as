// Environments: an environment from a cube map (six image assets,
// CubeTextureLoader), a Radiance .hdr (RGBELoader) or an OpenEXR file
// (EXRLoader), as the background and the light of a roughness sweep; a
// mirror sphere reflects the moving scene through a CubeCamera.

import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";
import { RGBELoader } from "lib:threeas/three/addons/loaders/RGBELoader";
import { EXRLoader } from "lib:threeas/three/addons/loaders/EXRLoader";
import { Context } from "rive/host";

export class Environments extends THREE.ThreeLayout {
    /// 0: cube map (PNG faces), 1: Radiance .hdr, 2: OpenEXR.
    @input source: i32 = 0;
    cubeTarget: THREE.WebGLCubeRenderTarget = new THREE.WebGLCubeRenderTarget(128);
    cubeCamera: THREE.CubeCamera = new THREE.CubeCamera(0.1, 50, new THREE.WebGLCubeRenderTarget(1));
    mirror: THREE.Mesh = new THREE.Mesh();
    movers: Array<THREE.Mesh> = [];
    time: f64 = 0;

    override setup(context: Context): bool {
        const renderer = this.renderer!;
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        const sky = new THREE.CubeTextureLoader(context).setPath("studio_")
            .load(["px", "nx", "py", "ny", "pz", "nz"]);
        const scene = this.scene;
        let env: THREE.Texture = sky;
        if (this.source == 1 || this.source == 2) {
            const hdr = this.source == 1 ? new RGBELoader(context).load("studio_rgbe")
                : new EXRLoader(context).load("studio_exr");
            if (hdr != null) {
                hdr.mapping = THREE.EquirectangularReflectionMapping;
                env = hdr;
            }
        }
        scene.background = env;
        scene.environment = env;

        // Roughness sweep, lit by the cube map alone.
        const sphere = new THREE.SphereGeometry(0.32, 48, 24);
        for (let i = 0; i < 5; i++) {
            const m = new THREE.Mesh(sphere, new THREE.MeshStandardMaterial({
                color: 0xffffff, metalness: 1, roughness: <f64>i / 4,
            }));
            m.position.set(<f64>i * 0.8 - 1.6, -0.9, 0);
            scene.add(m);
        }

        // A mirror sphere reflecting the scene through a CubeCamera.
        this.cubeCamera = new THREE.CubeCamera(0.1, 50, this.cubeTarget);
        scene.add(this.cubeCamera);
        this.mirror = new THREE.Mesh(new THREE.SphereGeometry(0.7, 64, 32), new THREE.MeshStandardMaterial({
            color: 0xffffff, metalness: 1, roughness: 0.02, envMap: this.cubeTarget.texture,
        }));
        this.mirror.position.set(0, 0.6, 0);
        scene.add(this.mirror);
        const colors: Array<u32> = [0xef476f, 0x06d6a0, 0x118ab2];
        for (let i = 0; i < 3; i++) {
            const m = new THREE.Mesh(new THREE.BoxGeometry(0.35, 0.35, 0.35),
                new THREE.MeshStandardMaterial({ color: colors[i], roughness: 0.4 }));
            scene.add(m);
            this.movers.push(m);
        }

        this.camera.position.set(0, 0.4, 4.2);
        const controls = new OrbitControls(this.camera, renderer);
        controls.target.set(0, 0.1, 0);
        controls.update();
        this.controls = controls;
        return true;
    }

    override animate(seconds: f64): void {
        const t = (this.time += seconds);
        for (let i = 0; i < this.movers.length; i++) {
            const a = t * 0.8 + <f64>i * Math.PI * 2 / 3;
            const m = this.movers[i];
            m.position.set(Math.cos(a) * 1.4, 0.6 + Math.sin(a * 2) * 0.3, Math.sin(a) * 1.4);
            m.rotation.set(t, t * 0.7, 0);
        }
    }

    override renderFrame(): void {
        const r = this.renderer!;
        this.cubeCamera.position.copy(this.mirror.position);
        this.mirror.visible = false;
        this.cubeCamera.update(r, this.scene);
        this.mirror.visible = true;
        r.render(this.scene, this.camera);
    }
}
