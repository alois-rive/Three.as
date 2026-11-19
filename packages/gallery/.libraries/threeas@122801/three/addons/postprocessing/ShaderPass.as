// three.js examples/jsm/postprocessing/ShaderPass.js: a fullscreen pass of
// one shader, reading the previous pass as `tDiffuse`. Takes a
// ShaderDefinition (three.js's shader object); `ShaderPass.fromMaterial`
// takes a ready ShaderMaterial (three.js's other constructor form).

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { ShaderDefinition } from "../shaders/PostShaders";
import { Pass, FullScreenQuad } from "./Pass";

export class ShaderPass extends Pass {
    textureID: string;
    material: ShaderMaterial;
    uniforms: Map<string, UniformBase>;
    protected fsQuad: FullScreenQuad;

    constructor(shader: ShaderDefinition, textureID: string = "tDiffuse") {
        super();
        this.textureID = textureID;
        this.material = shader.createMaterial();
        this.uniforms = this.material.uniforms;
        this.fsQuad = new FullScreenQuad(this.material);
    }

    static fromMaterial(material: ShaderMaterial, textureID: string = "tDiffuse"): ShaderPass {
        const pass = new ShaderPass(new ShaderDefinition(material.name, material.shader,
            material.fragmentEntryPoint, material.vertexEntryPoint), textureID);
        pass.material = material;
        pass.uniforms = material.uniforms;
        pass.fsQuad.material = material;
        return pass;
    }

    /// The uniform `name`, typed (three.js: pass.uniforms.name).
    uniform<T>(name: string): Uniform<T> {
        return this.uniforms.get(name) as Uniform<T>;
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        if (this.uniforms.has(this.textureID)) {
            (this.uniforms.get(this.textureID) as Uniform<Texture>).value = readBuffer.texture;
        }
        this.fsQuad.material = this.material;
        const oldAutoClear = renderer.autoClear;
        renderer.autoClear = true;
        renderer.setRenderTarget(this.renderToScreen ? null : writeBuffer);
        this.fsQuad.render(renderer);
        renderer.autoClear = oldAutoClear;
    }

    override dispose(): void {
        this.material.dispose();
        this.fsQuad.dispose();
    }
}
