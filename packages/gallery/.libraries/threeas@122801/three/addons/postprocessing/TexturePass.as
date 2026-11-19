// three.js examples/jsm/postprocessing/TexturePass.js: draws `map` (with
// `opacity`) over the read buffer, as three.js (it does not swap). Its
// shader (three/shaders/post/texture.wgsl, not CopyShader) decodes the
// texture as it says it is stored (sRGB, premultiplied, flipY), where
// three.js's texture formats decode on sampling.

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Vector4 } from "../../math/Vector4";
import { NormalBlending, SRGBColorSpace } from "../../constants";
import { ShaderDefinition, emptyTexture } from "../shaders/PostShaders";
import { Pass, FullScreenQuad } from "./Pass";

class TextureShaderDefinition extends ShaderDefinition {
    constructor() { super("TextureShader", "three/shaders/post/texture"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("opacity", new Uniform<f64>(1));
        m.set("flags", new Uniform<Vector4>(new Vector4(0, 1, 1, 0)));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

const TextureShader: ShaderDefinition = new TextureShaderDefinition();

export class TexturePass extends Pass {
    map: Texture?;
    opacity: f64;
    uniforms: Map<string, UniformBase>;
    material: ShaderMaterial;
    private fsQuad: FullScreenQuad;

    constructor(map: Texture? = null, opacity: f64 = 1.0) {
        super();
        this.map = map;
        this.opacity = opacity;
        this.material = TextureShader.createMaterial();
        // Premultiplied over when not opaque (three.js: premultipliedAlpha).
        this.material.blending = NormalBlending;
        this.uniforms = this.material.uniforms;
        this.needsSwap = false;
        this.fsQuad = new FullScreenQuad(this.material);
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        const oldAutoClear = renderer.autoClear;
        renderer.autoClear = false;
        this.fsQuad.material = this.material;
        (this.uniforms.get("opacity") as Uniform<f64>).value = this.opacity;
        const map = this.map;
        if (map != null) {
            (this.uniforms.get("tDiffuse") as Uniform<Texture>).value = map;
            (this.uniforms.get("flags") as Uniform<Vector4>).value.set(map.colorSpace == SRGBColorSpace ? 1 : 0,
                map.premultiplyAlpha ? 1 : 0, map.flipY ? 1 : 0, 0);
        }
        this.material.transparent = this.opacity < 1.0;
        renderer.setRenderTarget(this.renderToScreen ? null : readBuffer);
        if (this.clear) renderer.clear();
        this.fsQuad.render(renderer);
        renderer.autoClear = oldAutoClear;
    }

    override dispose(): void {
        this.material.dispose();
        this.fsQuad.dispose();
    }
}
