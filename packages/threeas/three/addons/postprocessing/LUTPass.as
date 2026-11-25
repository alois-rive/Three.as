// three.js examples/jsm/postprocessing/LUTPass.js: colour grading through
// a 3D LUT (a Data3DTexture from LUTCubeLoader or LUT3dlLoader), mixed in
// by `intensity`. Put it after the OutputPass, as three.js's example, so
// the LUT sees display colour.
//
//     const result = new LUTCubeLoader(context).load("warm");
//     composer.addPass(new LUTPass({ lut: result!.texture3D, intensity: 1 }));
//
// The LUT is a texture_3d: without the device's `texture3D` feature (and
// with no lut set) the pass copies its input unchanged, with one log line.

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Data3DTexture } from "../../textures/DataArrayTexture";
import { ShaderDefinition, CopyShader, emptyTexture } from "../shaders/PostShaders";
import { ShaderPass } from "./ShaderPass";

class LUTShaderDefinition extends ShaderDefinition {
    constructor() { super("LUTShader", "three/shaders/post/lut"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        // A white texel until a LUT is set (the pass copies meanwhile).
        const white = new Uint8Array(4);
        white.fill(255);
        m.set("lut", new Uniform<Texture>(new Data3DTexture(white, 1, 1, 1)));
        m.set("lutSize", new Uniform<f64>(0));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("intensity", new Uniform<f64>(1));
        return m;
    }
}

export const LUTShader: ShaderDefinition = new LUTShaderDefinition();

/// LUTPass's options (three.js: { lut, intensity }).
export class LUTPassParameters {
    lut: Data3DTexture? = null;
    intensity: f64 = 1;
}

export class LUTPass extends ShaderPass {
    private _lut: Data3DTexture? = null;
    private copyMaterial: ShaderMaterial = CopyShader.createMaterial();
    private warned: bool = false;
    // LUTShader's white 1x1x1 placeholder, disposed once a LUT replaces it.
    private placeholder: Texture? = null;

    constructor(options: LUTPassParameters? = null) {
        super(LUTShader);
        this.placeholder = this.uniform<Texture>("lut").value;
        const o = options != null ? options! : new LUTPassParameters();
        this.lut = o.lut;
        this.intensity = o.intensity;
    }

    get lut(): Data3DTexture? { return this._lut; }
    set lut(v: Data3DTexture?) {
        if (v === this._lut) return;
        this._lut = v;
        if (v != null) {
            this.uniform<f64>("lutSize").value = <f64>v.width;
            this.uniform<Texture>("lut").value = v;
            const placeholder = this.placeholder;
            if (placeholder != null) placeholder.dispose();
            this.placeholder = null;
        } else {
            this.uniform<f64>("lutSize").value = 0;
            let placeholder = this.placeholder;
            if (placeholder == null) {
                const white = new Uint8Array(4);
                white.fill(255);
                placeholder = new Data3DTexture(white, 1, 1, 1);
                this.placeholder = placeholder;
            }
            this.uniform<Texture>("lut").value = placeholder!;
        }
    }

    get intensity(): f64 { return this.uniform<f64>("intensity").value; }
    set intensity(v: f64) { this.uniform<f64>("intensity").value = v; }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        const has3D = renderer.context.features().texture3D;
        if (!has3D && !this.warned) {
            renderer.context.log("three: LUTPass: no 3D textures on this device; the pass copies its input");
            this.warned = true;
        }
        const material = has3D && this._lut != null ? this.material : this.copyMaterial;
        (material.uniforms.get("tDiffuse") as Uniform<Texture>).value = readBuffer.texture;
        this.fsQuad.material = material;
        const oldAutoClear = renderer.autoClear;
        renderer.autoClear = true;
        renderer.setRenderTarget(this.renderToScreen ? null : writeBuffer);
        this.fsQuad.render(renderer);
        renderer.autoClear = oldAutoClear;
    }

    /// Disposes the materials, the quad and the placeholder LUT (the LUT
    /// set stays the caller's, as three.js).
    override dispose(): void {
        super.dispose();
        this.copyMaterial.dispose();
        const placeholder = this.placeholder;
        if (placeholder != null) placeholder.dispose();
        this.placeholder = null;
    }
}
