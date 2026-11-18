// Post-processing: an EffectComposer with RenderPass (linear HDR),
// UnrealBloomPass, OutputPass (ACES tone mapping and sRGB) and FXAA, over
// emissive rings and spheres.

import * as THREE from "../three/Three";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { EffectComposer } from "../three/addons/postprocessing/EffectComposer";
import { RenderPass } from "../three/addons/postprocessing/RenderPass";
import { UnrealBloomPass } from "../three/addons/postprocessing/UnrealBloomPass";
import { OutputPass } from "../three/addons/postprocessing/OutputPass";
import { FXAAPass } from "../three/addons/postprocessing/FXAAPass";
import { Context } from "rive/host";

export class PostProcessing extends THREE.ThreeLayout {
    @input bloom: bool = true;
    composer: EffectComposer? = null;
    bloomPass: UnrealBloomPass? = null;
    rings: Array<THREE.Mesh> = [];
    time: f64 = 0;

    override setup(context: Context): bool {
        const renderer = this.renderer!;
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        renderer.toneMappingExposure = 1.0;
        const scene = this.scene;
        scene.background = new THREE.Color(0x05060a);
        scene.add(new THREE.HemisphereLight(0x8090ff, 0x201810, 0.4));
        const key = new THREE.PointLight(0xffffff, 30, 0, 2);
        key.position.set(2, 3, 3);
        scene.add(key);

        const colors: Array<u32> = [0xff3366, 0x33ccff, 0xffcc33, 0x66ff99];
        for (let i = 0; i < colors.length; i++) {
            const ring = new THREE.Mesh(new THREE.TorusGeometry(0.9 + <f64>i * 0.35, 0.05, 16, 128),
                new THREE.MeshStandardMaterial({ color: 0x111111, emissive: colors[i], emissiveIntensity: 2 }));
            scene.add(ring);
            this.rings.push(ring);
        }
        const core = new THREE.Mesh(new THREE.IcosahedronGeometry(0.45, 3),
            new THREE.MeshStandardMaterial({ color: 0xffffff, emissive: 0xffaa66, emissiveIntensity: 1.2, roughness: 0.3 }));
        scene.add(core);
        const floor = new THREE.Mesh(new THREE.PlaneGeometry(20, 20),
            new THREE.MeshStandardMaterial({ color: 0x20232b, roughness: 0.5, metalness: 0.2 }));
        floor.rotation.x = -Math.PI / 2;
        floor.position.y = -2;
        scene.add(floor);
        for (let i = 0; i < 6; i++) {
            const a = <f64>i / 6 * Math.PI * 2;
            const ball = new THREE.Mesh(new THREE.SphereGeometry(0.25, 32, 16),
                new THREE.MeshStandardMaterial({ color: 0x8899aa, roughness: 0.25, metalness: 0.6 }));
            ball.position.set(Math.cos(a) * 3, -1.75, Math.sin(a) * 3);
            scene.add(ball);
        }

        this.camera.position.set(0, 1.5, 6.5);
        const controls = new OrbitControls(this.camera, renderer);
        controls.update();
        this.controls = controls;

        const composer = new EffectComposer(renderer);
        composer.addPass(new RenderPass(scene, this.camera));
        const size = renderer.getDrawingBufferSize(new THREE.Vector2());
        const bloomPass = new UnrealBloomPass(size, 0.5, 0.3, 0.9);
        bloomPass.enabled = this.bloom;
        composer.addPass(bloomPass);
        composer.addPass(new OutputPass());
        composer.addPass(new FXAAPass());
        this.composer = composer;
        this.bloomPass = bloomPass;
        return true;
    }

    override animate(seconds: f64): void {
        const t = (this.time += seconds);
        for (let i = 0; i < this.rings.length; i++) {
            const r = this.rings[i];
            r.rotation.x = t * (0.3 + <f64>i * 0.15);
            r.rotation.y = t * (0.2 + <f64>i * 0.1) + <f64>i;
        }
        const b = this.bloomPass;
        if (b != null) b.enabled = this.bloom;
    }

    override renderFrame(): void {
        const c = this.composer;
        if (c != null) c.render(this.delta);
    }
}
