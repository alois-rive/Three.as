// three.js examples/jsm/postprocessing/OutputPass.js: tone mapping (the
// renderer's toneMapping and toneMappingExposure) and the sRGB conversion,
// from the composer's linear HDR buffer. Put it last (before FXAA, which
// wants display colour).

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { OutputShader } from "../shaders/PostShaders";
import { Pass, FullScreenQuad } from "./Pass";

export class OutputPass extends Pass {
    readonly isOutputPass: bool = true;
    material: ShaderMaterial;
    uniforms: Map<string, UniformBase>;
    private fsQuad: FullScreenQuad;

    constructor() {
        super();
        this.material = OutputShader.createMaterial();
        this.uniforms = this.material.uniforms;
        this.fsQuad = new FullScreenQuad(this.material);
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        (this.uniforms.get("tDiffuse") as Uniform<Texture>).value = readBuffer.texture;
        (this.uniforms.get("toneMapping") as Uniform<f64>).value = <f64>renderer.toneMapping;
        (this.uniforms.get("toneMappingExposure") as Uniform<f64>).value = renderer.toneMappingExposure;
        renderer.setRenderTarget(this.renderToScreen ? null : writeBuffer);
        this.fsQuad.render(renderer);
    }

    override dispose(): void {
        this.material.dispose();
        this.fsQuad.dispose();
    }
}
