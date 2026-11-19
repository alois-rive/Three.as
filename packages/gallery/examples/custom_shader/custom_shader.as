// CustomShader: a ShaderMaterial running examples/custom_shader/wave.wgsl, with
// number, colour and texture uniforms; the texture is a live Rive artboard.
// Beside it, a `lights: true` ShaderMaterial (examples/custom_shader/lit.wgsl,
// built from three/shaders/lib/three_chunks.wgsl) lit by the scene's lights
// and shadows, with fog.

import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";
import { Context } from "rive/host";
import { Artboard } from "rive/artboard";

export class CustomShader extends THREE.ThreeLayout {
    @input screen: Artboard? = null;
    @input amplitude: f64 = 0.18;

    material: THREE.ShaderMaterial = new THREE.ShaderMaterial({ shader: "examples/custom_shader/wave", side: THREE.DoubleSide });
    texture: THREE.ArtboardTexture? = null;
    knot: THREE.Mesh = new THREE.Mesh();

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

        // A toon-banded knot lit through the chunks, casting and receiving
        // shadows (its own shader reads the shadow maps).
        const sun = new THREE.DirectionalLight(0xfff0dd, 3);
        sun.position.set(2, 4, 3);
        sun.castShadow = true;
        this.scene.add(sun);
        this.scene.add(new THREE.HemisphereLight(0x8899ff, 0x221100, 1.0));
        this.scene.fog = new THREE.Fog(0x101218, 4, 12);
        this.renderer!.shadowMap.enabled = true;
        const lit = new THREE.ShaderMaterial({ shader: "examples/custom_shader/lit", lights: true, fog: true });
        lit.uniforms.set("color", new THREE.Uniform<THREE.Color>(new THREE.Color(0xff7a59)));
        lit.uniforms.set("bands", new THREE.Uniform<f64>(3));
        lit.uniforms.set("rim", new THREE.Uniform<THREE.Color>(new THREE.Color(0x3355ff)));
        const knot = new THREE.Mesh(new THREE.TorusKnotGeometry(0.35, 0.12, 128, 16), lit);
        knot.position.set(1.4, 0.9, 0.4);
        knot.castShadow = true;
        knot.receiveShadow = true;
        this.scene.add(knot);
        this.knot = knot;
        plane.receiveShadow = true;

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
        this.knot.rotation.y += seconds * 0.6;
        this.material.uniform<f64>("amplitude").value = this.amplitude;
    }
}
