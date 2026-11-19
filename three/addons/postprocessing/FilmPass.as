// three.js examples/jsm/postprocessing/FilmPass.js (r170): film grain,
// optionally grayscale (FilmShader); its time advances by deltaTime.
//
//     composer.addPass(new FilmPass(0.35, false));

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { FilmShader } from "../shaders/FilmShader";
import { Pass, FullScreenQuad } from "./Pass";

export class FilmPass extends Pass {
    material: ShaderMaterial;
    uniforms: Map<string, UniformBase>;
    private fsQuad: FullScreenQuad;

    /// `intensity`: 0 no effect, 1 full effect.
    constructor(intensity: f64 = 0.5, grayscale: bool = false) {
        super();
        this.material = FilmShader.createMaterial();
        this.uniforms = this.material.uniforms;
        this.uniform<f64>("intensity").value = intensity;
        this.uniform<f64>("grayscale").value = grayscale ? 1 : 0;
        this.fsQuad = new FullScreenQuad(this.material);
    }

    /// The uniform `name`, typed (three.js: pass.uniforms.name).
    uniform<T>(name: string): Uniform<T> {
        return this.uniforms.get(name) as Uniform<T>;
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        this.uniform<Texture>("tDiffuse").value = readBuffer.texture;
        this.uniform<f64>("time").value += deltaTime;
        if (this.renderToScreen) {
            renderer.setRenderTarget(null);
            this.fsQuad.render(renderer);
        } else {
            renderer.setRenderTarget(writeBuffer);
            if (this.clear) renderer.clear();
            this.fsQuad.render(renderer);
        }
    }

    override dispose(): void {
        this.material.dispose();
        this.fsQuad.dispose();
    }
}
