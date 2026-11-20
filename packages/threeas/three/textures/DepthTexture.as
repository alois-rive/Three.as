// three.js DepthTexture: the depth a render target was rendered with, for
// shaders to read afterwards (soft particles, SSAO, depth of field...).
//
//     const target = new RenderTarget(w, h, { type: HalfFloatType });
//     target.depthTexture = new DepthTexture(w, h);
//     renderer.setRenderTarget(target);
//     renderer.render(scene, camera);
//     material.uniform<Texture>("tDepth").value = target.depthTexture!;
//
// It is the pass's depth attachment itself (24-bit depth plus stencil,
// whatever `type` says), resized with the target. ShaderMaterials declare it
// `texture_depth_2d` and read it with `textureLoad` (or `textureSample`);
// built-in materials cannot sample it. Rows are top first, as every render
// target texture here (`flipY` true; three.js: false).

import { GPUTexture, GPUTextureDesc, GPUTextureView, GPUTextureViewDesc } from "rive/gpu";
import { TextureFormat, TextureAspect } from "rive/gpu_enums";
import { Texture } from "./Texture";
import { NearestFilter, UnsignedIntType, UnsignedInt248Type, DepthFormat, DepthStencilFormat } from "../constants";

export class DepthTexture extends Texture {
    readonly isDepthTexture: bool = true;
    /// three.js's compareFunction (LessEqualCompare ...; -1: none). Kept
    /// for the API: shaders compare depth themselves.
    compareFunction: i32 = -1;
    private depthWidth: u32;
    private depthHeight: u32;
    private gpuTexture: GPUTexture? = null;
    private attachView: GPUTextureView? = null;
    private sampleView: GPUTextureView? = null;

    constructor(width: u32 = 1, height: u32 = 1, type: i32 = -1, format: i32 = DepthFormat) {
        super(null);
        this.depthWidth = width;
        this.depthHeight = height;
        this.format = format == DepthStencilFormat ? DepthStencilFormat : DepthFormat;
        this.type = type >= 0 ? type : (format == DepthStencilFormat ? UnsignedInt248Type : UnsignedIntType);
        this.magFilter = NearestFilter;
        this.minFilter = NearestFilter;
        this.flipY = true;
        this.generateMipmaps = false;
    }

    override get width(): u32 { return this.depthWidth; }
    override get height(): u32 { return this.depthHeight; }

    /// The depth-only view shaders sample (null before the first render).
    override getView(): GPUTextureView? { return this.sampleView; }

    /// The pass's depth attachment, made or resized to `width` x `height`
    /// (internal: the renderer).
    ensureAttachment(width: u32, height: u32): GPUTextureView? {
        const t = this.gpuTexture;
        if (t == null || t.width != width || t.height != height) {
            if (t != null) t.release();
            this.releaseViews();
            const d = new GPUTextureDesc();
            d.width = width;
            d.height = height;
            d.format = TextureFormat.depth24plusStencil8;
            d.renderTarget = true;
            const tex = new GPUTexture(d);
            this.gpuTexture = tex;
            this.attachView = tex.view();
            const sv = new GPUTextureViewDesc();
            sv.aspect = TextureAspect.depthOnly;
            this.sampleView = tex.view(sv);
            this.depthWidth = width;
            this.depthHeight = height;
            this.version++;
        }
        return this.attachView;
    }

    override dispose(): void {
        const t = this.gpuTexture;
        if (t != null) t.release();
        this.gpuTexture = null;
        this.releaseViews();
        super.dispose();
    }

    private releaseViews(): void {
        const a = this.attachView;
        if (a != null) a.release();
        const s = this.sampleView;
        if (s != null) s.release();
        this.attachView = null;
        this.sampleView = null;
    }
}
