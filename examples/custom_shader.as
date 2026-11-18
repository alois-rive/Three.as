// CustomShader: a ShaderMaterial running examples/shaders/wave.wgsl, with
// number, colour and texture uniforms; the texture is a live Rive artboard.

import * as THREE from "../three/Three";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { Context } from "rive/host";
import { Artboard } from "rive/artboard";

export class CustomShader extends THREE.ThreeLayout {
    @input screen: Artboard? = null;
    @input amplitude: f64 = 0.18;

    material: THREE.ShaderMaterial = new THREE.ShaderMaterial({ shader: "examples/shaders/wave", side: THREE.DoubleSide });
    texture: THREE.ArtboardTexture? = null;

    override setup(context: Context): bool {
        this.scene.background = new THREE.Color(0x101218);
        const m = this.material;
        m.uniforms.set("time", new THREE.Uniform<f64>(0));
        m.uniforms.set("amplitude", new THREE.Uniform<f64>(this.amplitude));
        m.uniforms.set("tint", new THREE.Uniform<THREE.Color>(new THREE.Color(0x66ccff)));
        m.uniforms.set("map", new THREE.Uniform<THREE.Texture>(new THREE.Texture()));
        const plane = new THREE.Mesh(new THREE.PlaneGeometry(3.2, 3.2, 96, 96), m);
        plane.rotation.x = -0.5;
        this.scene.add(plane);

        this.camera.position.set(0, 0.6, 4.6);
        const controls = new OrbitControls(this.camera, this.renderer);
        controls.update();
        this.controls = controls;
        return true;
    }

    override animate(seconds: f64): void {
        const screen = this.screen;
        if (this.texture == null && screen != null) {
            const t = new THREE.ArtboardTexture(screen, 512, 512);
            this.texture = t;
            this.material.uniform<THREE.Texture>("map").value = t;
        }
        const t = this.texture;
        if (t != null) t.advance(seconds);
        this.material.uniform<f64>("time").value += seconds;
        this.material.uniform<f64>("amplitude").value = this.amplitude;
    }
}
