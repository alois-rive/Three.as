// three.js examples/jsm/postprocessing/HalftonePass.js: an RGB halftone
// (HalftoneShader).
//
//     composer.addPass(new HalftonePass(w, h, { shape: 1, radius: 6, scatter: 0.2 }));

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { HalftoneShader } from "../shaders/HalftoneShader";
import { Pass, FullScreenQuad } from "./Pass";

/// HalftonePass's params (three.js: any subset of the shader's uniforms);
/// the defaults are HalftoneShader's.
export class HalftonePassParameters {
    /// 1 dot, 2 ellipse, 3 line, 4 square.
    shape: i32 = 1;
    radius: f64 = 4;
    rotateR: f64 = Math.PI / 12 * 1;
    rotateG: f64 = Math.PI / 12 * 2;
    rotateB: f64 = Math.PI / 12 * 3;
    scatter: f64 = 0;
    blending: f64 = 1;
    /// 1 linear, 2 multiply, 3 add, 4 lighter, 5 darker.
    blendingMode: i32 = 1;
    greyscale: bool = false;
    disable: bool = false;
}

export class HalftonePass extends Pass {
    uniforms: Map<string, UniformBase>;
    material: ShaderMaterial;
    private fsQuad: FullScreenQuad;

    constructor(width: f64, height: f64, params: HalftonePassParameters? = null) {
        super();
        this.material = HalftoneShader.createMaterial();
        this.uniforms = this.material.uniforms;
        this.uniform("width").value = width;
        this.uniform("height").value = height;
        if (params != null) {
            this.uniform("shape").value = <f64>params.shape;
            this.uniform("radius").value = params.radius;
            this.uniform("rotateR").value = params.rotateR;
            this.uniform("rotateG").value = params.rotateG;
            this.uniform("rotateB").value = params.rotateB;
            this.uniform("scatter").value = params.scatter;
            this.uniform("blending").value = params.blending;
            this.uniform("blendingMode").value = <f64>params.blendingMode;
            this.uniform("greyscale").value = params.greyscale ? 1 : 0;
            this.uniform("disable").value = params.disable ? 1 : 0;
        }
        this.fsQuad = new FullScreenQuad(this.material);
    }

    /// A number uniform (three.js: pass.uniforms.radius.value).
    uniform(name: string): Uniform<f64> {
        return this.uniforms.get(name) as Uniform<f64>;
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        (this.uniforms.get("tDiffuse") as Uniform<Texture>).value = readBuffer.texture;
        if (this.renderToScreen) {
            renderer.setRenderTarget(null);
            this.fsQuad.render(renderer);
        } else {
            renderer.setRenderTarget(writeBuffer);
            if (this.clear) renderer.clear();
            this.fsQuad.render(renderer);
        }
    }

    override setSize(width: f64, height: f64): void {
        this.uniform("width").value = width;
        this.uniform("height").value = height;
    }

    override dispose(): void {
        this.material.dispose();
        this.fsQuad.dispose();
    }
}
