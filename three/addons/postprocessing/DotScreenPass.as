// three.js examples/jsm/postprocessing/DotScreenPass.js: a halftone-like dot
// pattern over the image's brightness (DotScreenShader).
//
//     composer.addPass(new DotScreenPass(new Vector2(0, 0), 0.5, 0.8));

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Vector2 } from "../../math/Vector2";
import { DotScreenShader } from "../shaders/DotScreenShader";
import { Pass, FullScreenQuad } from "./Pass";

export class DotScreenPass extends Pass {
    material: ShaderMaterial;
    uniforms: Map<string, UniformBase>;
    private fsQuad: FullScreenQuad;

    /// `center` (pixels), `angle` (radians) and `scale` default to the
    /// shader's (0.5, 0.5), 1.57 and 1 (three.js leaves them undefined).
    constructor(center: Vector2? = null, angle: f64 = 1.57, scale: f64 = 1.0) {
        super();
        this.material = DotScreenShader.createMaterial();
        this.uniforms = this.material.uniforms;
        if (center != null) this.uniform<Vector2>("center").value.copy(center);
        this.uniform<f64>("angle").value = angle;
        this.uniform<f64>("scale").value = scale;
        this.fsQuad = new FullScreenQuad(this.material);
    }

    /// The uniform `name`, typed (three.js: pass.uniforms.name).
    uniform<T>(name: string): Uniform<T> {
        return this.uniforms.get(name) as Uniform<T>;
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        this.uniform<Texture>("tDiffuse").value = readBuffer.texture;
        this.uniform<Vector2>("tSize").value.set(<f64>readBuffer.width, <f64>readBuffer.height);
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
