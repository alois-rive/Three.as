// Texture views for the renderer (internal), like three.js's WebGLTextures:
// calls Texture.update once a frame, and gives each texture the view to
// bind. A texture that wants mipmaps (generateMipmaps and a mipmap
// minFilter) is copied into a mipmapped texture of our own and its levels
// drawn down from it, again only when the source changes (a new view or
// size, or texture.version).

import { Context } from "rive/host";
import {
    GPUTarget, GPUTexture, GPUTextureDesc, GPUTextureView, GPUTextureViewDesc, GPUPipeline, GPUPipelineDesc,
    GPUColorTargetDesc, GPUBindGroup, GPUBindGroupTexture, GPUBindGroupSampler, GPUColorAttachment, GPUPassDesc,
    GPUSampler, GPUShaderModule,
} from "rive/gpu";
import { TextureFormat, Filter, WrapMode, LoadOp, StoreOp } from "rive/gpu_enums";
import { Texture } from "../../textures/Texture";
import {
    NearestMipmapNearestFilter, NearestMipmapLinearFilter, LinearMipmapNearestFilter, LinearMipmapLinearFilter,
} from "../../constants";

const MIP_SHADER_NAMES: Array<string> = ["three/shaders/three_mip", "shaders/three_mip", "three_mip"];

class MipChain {
    texture: GPUTexture;
    view: GPUTextureView;
    source: GPUTextureView;
    version: i32;
    width: u32;
    height: u32;

    constructor(texture: GPUTexture, view: GPUTextureView, source: GPUTextureView, version: i32, w: u32, h: u32) {
        this.texture = texture;
        this.view = view;
        this.source = source;
        this.version = version;
        this.width = w;
        this.height = h;
    }
}

export function wantsMipmaps(t: Texture): bool {
    const f = t.minFilter;
    return t.generateMipmaps && (f == NearestMipmapNearestFilter || f == NearestMipmapLinearFilter
        || f == LinearMipmapNearestFilter || f == LinearMipmapLinearFilter);
}

export class GPUTextures {
    private context: Context;
    private frames: Map<i32, i32> = new Map<i32, i32>();
    private chains: Map<i32, MipChain> = new Map<i32, MipChain>();
    private mipModule: GPUShaderModule? = null;
    private mipPipeline: GPUPipeline? = null;
    private mipSampler: GPUSampler? = null;
    private mipBroken: bool = false;
    private colorAttachment: GPUColorAttachment = new GPUColorAttachment();
    private passDesc: GPUPassDesc = new GPUPassDesc();

    constructor(context: Context) {
        this.context = context;
    }

    /// Lets the texture draw or upload (once a frame), before any pass.
    update(t: Texture, frame: i32): void {
        if (this.frames.has(t.id) && this.frames.get(t.id) == frame) return;
        this.frames.set(t.id, frame);
        t.update(this.context);
    }

    /// The view to bind for `t`, mipmapped when it asks for mipmaps.
    /// `target` hosts the mip passes. Null while there is nothing to sample.
    view(t: Texture, target: GPUTarget): GPUTextureView? {
        const source = t.getView();
        if (source == null) return null;
        const w = t.width, h = t.height;
        if (!wantsMipmaps(t) || (w <= 1 && h <= 1) || this.mipBroken) return source;
        let chain: MipChain? = this.chains.has(t.id) ? this.chains.get(t.id) : null;
        if (chain != null && chain.source === source && chain.version == t.version
                && chain.width == w && chain.height == h) {
            return chain.view;
        }
        chain = this.build(t, source, w, h, chain, target);
        return chain != null ? chain.view : source;
    }

    /// Mip levels of the view `view()` returned (1 when not mipmapped).
    levels(t: Texture): u32 {
        if (!this.chains.has(t.id)) return 1;
        return this.chains.get(t.id).texture.numMipmaps;
    }

    dispose(id: i32): void {
        this.frames.delete(id);
        if (this.chains.has(id)) {
            this.chains.get(id).texture.release();
            this.chains.delete(id);
        }
    }

    private build(t: Texture, source: GPUTextureView, w: u32, h: u32, old: MipChain?, target: GPUTarget): MipChain? {
        if (!this.ensurePipeline()) return null;
        const levels = mipLevels(w, h);
        let chain = old;
        if (chain == null || chain.width != w || chain.height != h) {
            if (chain != null) chain.texture.release();
            const desc = new GPUTextureDesc();
            desc.width = w;
            desc.height = h;
            desc.format = TextureFormat.rgba8unorm;
            desc.renderTarget = true;
            desc.numMipmaps = levels;
            const tex = new GPUTexture(desc);
            chain = new MipChain(tex, tex.view(), source, t.version, w, h);
            this.chains.set(t.id, chain);
        }
        chain.source = source;
        chain.version = t.version;
        // Level 0 from the source, then each level from the one above.
        let from = source;
        for (let level: u32 = 0; level < levels; level++) {
            const vd = new GPUTextureViewDesc();
            vd.baseMipLevel = level;
            vd.mipCount = 1;
            const into = chain.texture.view(vd);
            this.blit(from, into, target);
            from = into;
        }
        return chain;
    }

    private blit(from: GPUTextureView, into: GPUTextureView, target: GPUTarget): void {
        const group = new GPUBindGroup(this.mipPipeline!.getBindGroupLayout(0), [],
            [new GPUBindGroupTexture(0, from)], [new GPUBindGroupSampler(1, this.mipSampler!)]);
        const color = this.colorAttachment;
        color.view = into;
        color.loadOp = LoadOp.clear;
        color.storeOp = StoreOp.store;
        color.clearR = 0; color.clearG = 0; color.clearB = 0; color.clearA = 0;
        const pd = this.passDesc;
        pd.label = "three mip";
        pd.color = [color];
        pd.depthView = null;
        const pass = target.beginRenderPass(pd);
        pass.setPipeline(this.mipPipeline!);
        pass.setBindGroup(0, group);
        pass.draw(3);
        pass.finish();
    }

    private ensurePipeline(): bool {
        if (this.mipPipeline != null) return true;
        if (this.mipBroken) return false;
        let module: GPUShaderModule? = null;
        for (let i = 0; i < MIP_SHADER_NAMES.length && module == null; i++) {
            module = this.context.shader(MIP_SHADER_NAMES[i]);
        }
        if (module == null) {
            this.context.log("three: mipmaps disabled: shader asset 'three/shaders/three_mip.wgsl' not found");
            this.mipBroken = true;
            return false;
        }
        this.mipModule = module;
        const target = new GPUColorTargetDesc();
        target.format = TextureFormat.rgba8unorm;
        const d = new GPUPipelineDesc();
        d.vertexModule = module;
        d.vertexEntryPoint = "vs_blit";
        d.fragmentModule = module;
        d.fragmentEntryPoint = "fs_blit";
        d.colorTargets = [target];
        this.mipPipeline = new GPUPipeline(d);
        this.mipSampler = new GPUSampler(Filter.linear, Filter.linear, Filter.nearest,
            WrapMode.clampToEdge, WrapMode.clampToEdge);
        return true;
    }
}

function mipLevels(w: u32, h: u32): u32 {
    let n: u32 = 1;
    let s = max<u32>(w, h);
    while (s > 1) {
        s >>= 1;
        n++;
    }
    return n;
}
