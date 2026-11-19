// three.js examples/jsm/postprocessing/UnrealBloomPass.js: a luminosity
// high pass, five mips of separable gaussian blur and their composite,
// added onto the read buffer. The same stages and parameters as three.js
// (strength, radius, threshold; kernel sizes 3, 5, 7, 9, 11). bloomTintColors
// are not supported (all white).

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Vector2 } from "../../math/Vector2";
import { Color } from "../../math/Color";
import { HalfFloatType, AdditiveBlending } from "../../constants";
import { BloomShaderDefinition, CopyShader } from "../shaders/PostShaders";
import { Pass, FullScreenQuad } from "./Pass";

const KERNEL_SIZES: StaticArray<f64> = [3, 5, 7, 9, 11];

export class UnrealBloomPass extends Pass {
    strength: f64;
    radius: f64;
    threshold: f64;
    resolution: Vector2;
    clearColor: Color = new Color(0, 0, 0);
    nMips: i32 = 5;

    renderTargetsHorizontal: Array<RenderTarget> = [];
    renderTargetsVertical: Array<RenderTarget> = [];
    renderTargetBright: RenderTarget;

    private highPassMaterial: ShaderMaterial;
    private blurMaterialsH: Array<ShaderMaterial> = [];
    private blurMaterialsV: Array<ShaderMaterial> = [];
    private compositeMaterial: ShaderMaterial;
    private blendMaterial: ShaderMaterial;
    private fsQuad: FullScreenQuad = new FullScreenQuad();
    private _oldClearColor: Color = new Color();

    constructor(resolution: Vector2, strength: f64 = 1, radius: f64 = 0, threshold: f64 = 0) {
        super();
        this.strength = strength;
        this.radius = radius;
        this.threshold = threshold;
        this.resolution = resolution.clone();
        let w = <u32>Math.max(1, Math.round(resolution.x / 2));
        let h = <u32>Math.max(1, Math.round(resolution.y / 2));
        this.renderTargetBright = new RenderTarget(w, h, { type: HalfFloatType });
        for (let i = 0; i < this.nMips; i++) {
            this.renderTargetsHorizontal.push(new RenderTarget(w, h, { type: HalfFloatType }));
            this.renderTargetsVertical.push(new RenderTarget(w, h, { type: HalfFloatType }));
            const mh = new BloomShaderDefinition("UnrealBloomPass.blurH", "fs_blur").createMaterial();
            const mv = new BloomShaderDefinition("UnrealBloomPass.blurV", "fs_blur").createMaterial();
            mh.uniform<f64>("kernelRadius").value = KERNEL_SIZES[i];
            mv.uniform<f64>("kernelRadius").value = KERNEL_SIZES[i];
            mh.uniform<Vector2>("direction").value.set(1, 0);
            mv.uniform<Vector2>("direction").value.set(0, 1);
            this.blurMaterialsH.push(mh);
            this.blurMaterialsV.push(mv);
            w = max<u32>(1, w / 2);
            h = max<u32>(1, h / 2);
        }
        this.highPassMaterial = new BloomShaderDefinition("UnrealBloomPass.highPass", "fs_high_pass").createMaterial();
        this.compositeMaterial = new BloomShaderDefinition("UnrealBloomPass.composite", "fs_composite").createMaterial();
        this.compositeMaterial.uniform<Texture>("blurTexture1").value = this.renderTargetsVertical[0].texture;
        this.compositeMaterial.uniform<Texture>("blurTexture2").value = this.renderTargetsVertical[1].texture;
        this.compositeMaterial.uniform<Texture>("blurTexture3").value = this.renderTargetsVertical[2].texture;
        this.compositeMaterial.uniform<Texture>("blurTexture4").value = this.renderTargetsVertical[3].texture;
        this.compositeMaterial.uniform<Texture>("blurTexture5").value = this.renderTargetsVertical[4].texture;
        this.blendMaterial = CopyShader.createMaterial();
        this.blendMaterial.blending = AdditiveBlending;
        this.blendMaterial.transparent = true;
        this.needsSwap = false;
    }

    override setSize(width: f64, height: f64): void {
        let w = <u32>Math.max(1, Math.round(width / 2));
        let h = <u32>Math.max(1, Math.round(height / 2));
        this.renderTargetBright.setSize(w, h);
        for (let i = 0; i < this.nMips; i++) {
            this.renderTargetsHorizontal[i].setSize(w, h);
            this.renderTargetsVertical[i].setSize(w, h);
            w = max<u32>(1, w / 2);
            h = max<u32>(1, h / 2);
        }
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        renderer.getClearColor(this._oldClearColor);
        const oldClearAlpha = renderer.getClearAlpha();
        const oldAutoClear = renderer.autoClear;
        renderer.autoClear = true;
        renderer.setClearColor<Color>(this.clearColor, 0);

        // 1. The bright parts.
        const hp = this.highPassMaterial;
        hp.uniform<Texture>("tDiffuse").value = readBuffer.texture;
        hp.uniform<f64>("luminosityThreshold").value = this.threshold;
        this.fsQuad.material = hp;
        renderer.setRenderTarget(this.renderTargetBright);
        this.fsQuad.render(renderer);

        // 2. Blur each mip, horizontally then vertically.
        let input: RenderTarget = this.renderTargetBright;
        for (let i = 0; i < this.nMips; i++) {
            const mh = this.blurMaterialsH[i];
            mh.uniform<Texture>("tDiffuse").value = input.texture;
            this.fsQuad.material = mh;
            renderer.setRenderTarget(this.renderTargetsHorizontal[i]);
            this.fsQuad.render(renderer);
            const mv = this.blurMaterialsV[i];
            mv.uniform<Texture>("tDiffuse").value = this.renderTargetsHorizontal[i].texture;
            this.fsQuad.material = mv;
            renderer.setRenderTarget(this.renderTargetsVertical[i]);
            this.fsQuad.render(renderer);
            input = this.renderTargetsVertical[i];
        }

        // 3. Composite the mips.
        const cm = this.compositeMaterial;
        cm.uniform<f64>("bloomStrength").value = this.strength;
        cm.uniform<f64>("bloomRadius").value = this.radius;
        this.fsQuad.material = cm;
        renderer.setRenderTarget(this.renderTargetsHorizontal[0]);
        this.fsQuad.render(renderer);

        // 4. Add it onto the input.
        const bm = this.blendMaterial;
        bm.uniform<Texture>("tDiffuse").value = this.renderTargetsHorizontal[0].texture;
        this.fsQuad.material = bm;
        renderer.autoClear = false;
        renderer.setRenderTarget(this.renderToScreen ? null : readBuffer);
        this.fsQuad.render(renderer);

        renderer.setClearColor<Color>(this._oldClearColor, oldClearAlpha);
        renderer.autoClear = oldAutoClear;
    }

    override dispose(): void {
        this.renderTargetBright.dispose();
        for (let i = 0; i < this.nMips; i++) {
            this.renderTargetsHorizontal[i].dispose();
            this.renderTargetsVertical[i].dispose();
            this.blurMaterialsH[i].dispose();
            this.blurMaterialsV[i].dispose();
        }
        this.highPassMaterial.dispose();
        this.compositeMaterial.dispose();
        this.blendMaterial.dispose();
        this.fsQuad.dispose();
    }
}
