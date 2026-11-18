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
    GPUSampler, GPUShaderModule, GPUBuffer, GPUBindGroupUBO, GPUBindGroupLayout,
} from "rive/gpu";
import { TextureFormat, Filter, WrapMode, LoadOp, StoreOp, BufferUsage } from "rive/gpu_enums";
import { Texture } from "../../textures/Texture";
import { CubeTexture } from "../../textures/CubeTexture";
import {
    NearestMipmapNearestFilter, NearestMipmapLinearFilter, LinearMipmapNearestFilter, LinearMipmapLinearFilter,
} from "../../constants";

const MIP_SHADER_NAMES: Array<string> = ["three/shaders/three_mip", "shaders/three_mip", "three_mip"];
const CUBE_SHADER_NAMES: Array<string> = ["three/shaders/three_cube", "shaders/three_cube", "three_cube"];
const PMREM_SHADER_NAMES: Array<string> = ["three/shaders/three_pmrem", "shaders/three_pmrem", "three_pmrem"];

// A texture's prefiltered environment chain.
class PmremEntry {
    texture: GPUTexture;
    view: GPUTextureView;
    levelViews: Array<GPUTextureView> = [];
    params: Array<GPUBuffer> = [];
    source: GPUTextureView? = null;
    version: i32 = -1;
    width: u32;
    levels: u32;

    constructor(texture: GPUTexture, w: u32, levels: u32) {
        this.texture = texture;
        this.view = texture.view();
        this.width = w;
        this.levels = levels;
    }
}

// A CubeTexture's equirectangular conversion.
class CubeEquirect {
    texture: GPUTexture;
    view: GPUTextureView;
    faces: Array<GPUTextureView?> = [null, null, null, null, null, null];
    version: i32 = -1;
    width: u32;
    height: u32;
    params: GPUBuffer = new GPUBuffer(BufferUsage.uniform, 16);

    constructor(texture: GPUTexture, w: u32, h: u32) {
        this.texture = texture;
        this.view = texture.view();
        this.width = w;
        this.height = h;
    }
}

class MipChain {
    texture: GPUTexture;
    view: GPUTextureView;
    source: GPUTextureView;
    version: i32;
    width: u32;
    height: u32;
    format: u32 = <u32>TextureFormat.rgba8unorm;

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
    private mipPipelineHDR: GPUPipeline? = null;
    private cubeModule: GPUShaderModule? = null;
    private cubePipeline: GPUPipeline? = null;
    private cubeLayout: GPUBindGroupLayout? = null;
    private cubeBroken: bool = false;
    private cubes: Map<i32, CubeEquirect> = new Map<i32, CubeEquirect>();
    private cubeStaging: Float32Array = new Float32Array(4);
    private pmremPipeline: GPUPipeline? = null;
    private pmremLayout: GPUBindGroupLayout? = null;
    private pmremSampler: GPUSampler? = null;
    private pmremBroken: bool = false;
    private pmrems: Map<i32, PmremEntry> = new Map<i32, PmremEntry>();
    private pmremStaging: Float32Array = new Float32Array(8);
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
        let source: GPUTextureView? = null;
        let w: u32 = 0, h: u32 = 0;
        let format = <u32>TextureFormat.rgba8unorm;
        if (t instanceof CubeTexture) {
            const ce = this.cubeEquirect(t as CubeTexture, target);
            if (ce == null) return null;
            source = ce.view;
            w = ce.width;
            h = ce.height;
            format = <u32>TextureFormat.rgba16float;
        } else {
            source = t.getView();
            w = t.width;
            h = t.height;
            if (t.isHDRSource) format = <u32>TextureFormat.rgba16float;
        }
        if (source == null) return null;
        if (!wantsMipmaps(t) || (w <= 1 && h <= 1) || this.mipBroken) return source;
        let chain: MipChain? = this.chains.has(t.id) ? this.chains.get(t.id) : null;
        if (chain != null && chain.source === source && chain.version == t.version
                && chain.width == w && chain.height == h) {
            return chain.view;
        }
        chain = this.build(t, source!, w, h, chain, target, format);
        return chain != null ? chain.view : source;
    }

    /// Mip levels of the view `view()` returned (1 when not mipmapped).
    levels(t: Texture): u32 {
        if (!this.chains.has(t.id)) return 1;
        return this.chains.get(t.id).texture.numMipmaps;
    }

    dispose(id: i32): void {
        this.frames.delete(id);
        if (this.cubes.has(id)) {
            this.cubes.get(id).texture.release();
            this.cubes.delete(id);
        }
        if (this.pmrems.has(id)) {
            this.pmrems.get(id).texture.release();
            this.pmrems.delete(id);
        }
        if (this.chains.has(id)) {
            this.chains.get(id).texture.release();
            this.chains.delete(id);
        }
    }

    private build(t: Texture, source: GPUTextureView, w: u32, h: u32, old: MipChain?, target: GPUTarget,
                  format: u32): MipChain? {
        if (!this.ensurePipeline()) return null;
        const levels = mipLevels(w, h);
        let chain = old;
        if (chain == null || chain.width != w || chain.height != h || chain.format != format) {
            if (chain != null) chain.texture.release();
            const desc = new GPUTextureDesc();
            desc.width = w;
            desc.height = h;
            desc.format = <TextureFormat>format;
            desc.renderTarget = true;
            desc.numMipmaps = levels;
            const tex = new GPUTexture(desc);
            chain = new MipChain(tex, tex.view(), source, t.version, w, h);
            chain.format = format;
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
            this.blit(from, into, target, format != <u32>TextureFormat.rgba8unorm);
            from = into;
        }
        return chain;
    }

    private blit(from: GPUTextureView, into: GPUTextureView, target: GPUTarget, hdr: bool): void {
        const pipeline = hdr ? this.mipPipelineHDR! : this.mipPipeline!;
        const group = new GPUBindGroup(pipeline.getBindGroupLayout(0), [],
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
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, group);
        pass.draw(3);
        pass.finish();
    }

    /// The equirectangular conversion of a cube texture, redrawn when a face
    /// view or the texture's version changed. Null until every face can be
    /// sampled.
    private cubeEquirect(t: CubeTexture, target: GPUTarget): CubeEquirect? {
        if (!t.ready || !this.ensureCubePipeline()) return null;
        const face = max<u32>(1, t.width);
        const maxSize = this.context.features().maxTextureSize2D;
        const w = min<u32>(face * 4, maxSize), h = min<u32>(face * 2, maxSize / 2);
        let ce: CubeEquirect? = this.cubes.has(t.id) ? this.cubes.get(t.id) : null;
        if (ce == null || ce.width != w || ce.height != h) {
            if (ce != null) ce.texture.release();
            const desc = new GPUTextureDesc();
            desc.width = w;
            desc.height = h;
            desc.format = TextureFormat.rgba16float;
            desc.renderTarget = true;
            ce = new CubeEquirect(new GPUTexture(desc), w, h);
            this.cubes.set(t.id, ce);
        }
        let changed = ce.version != t.version;
        const views: Array<GPUTextureView> = [];
        for (let i = 0; i < 6; i++) {
            const v = t.faceTexture(i).getView()!;
            views.push(v);
            if (ce.faces[i] !== v) changed = true;
        }
        if (!changed) return ce;
        const p = this.cubeStaging;
        p[0] = t.flipX ? 1 : 0;
        p[1] = t.flipRows ? 1 : 0;
        p[2] = t.colorSpace == "srgb" ? 1 : 0;
        p[3] = t.premultiplyAlpha ? 1 : 0;
        ce.params.update(0, p.buffer);
        const textures: Array<GPUBindGroupTexture> = [];
        for (let i = 0; i < 6; i++) {
            textures.push(new GPUBindGroupTexture(<u32>i, views[i]));
            ce.faces[i] = views[i];
        }
        const group = new GPUBindGroup(this.cubeLayout!, [new GPUBindGroupUBO(7, ce.params)], textures,
            [new GPUBindGroupSampler(6, this.mipSampler!)]);
        const color = this.colorAttachment;
        color.view = ce.view;
        color.loadOp = LoadOp.clear;
        color.storeOp = StoreOp.store;
        color.clearR = 0; color.clearG = 0; color.clearB = 0; color.clearA = 0;
        const pd = this.passDesc;
        pd.label = "three cube";
        pd.color = [color];
        pd.depthView = null;
        const pass = target.beginRenderPass(pd);
        pass.setPipeline(this.cubePipeline!);
        pass.setBindGroup(0, group);
        pass.draw(3);
        pass.finish();
        ce.version = t.version;
        return ce;
    }

    /// The PMREM of an environment texture (equirectangular or cube): a
    /// GGX-prefiltered mip chain, level k at roughness k / (levels - 1),
    /// redone when the source changes. Null when the source cannot be
    /// sampled yet or the shader is missing.
    pmrem(t: Texture, target: GPUTarget): GPUTextureView? {
        if (!this.ensurePmremPipeline()) return null;
        const src = this.view(t, target);
        if (src == null) return null;
        const cube = t instanceof CubeTexture;
        let sw: u32, sh: u32;
        if (cube) {
            const ce = this.cubes.get(t.id);
            sw = ce.width; sh = ce.height;
        } else {
            sw = t.width; sh = t.height;
        }
        let w: u32 = 128;
        while (w < sw && w < 1024) w <<= 1;
        const h = w / 2;
        const levels = mipLevels(w / 16, w / 16);   // the last level is 16 x 8
        let e: PmremEntry? = this.pmrems.has(t.id) ? this.pmrems.get(t.id) : null;
        if (e == null || e.width != w) {
            if (e != null) e.texture.release();
            const desc = new GPUTextureDesc();
            desc.width = w;
            desc.height = h;
            desc.format = TextureFormat.rgba16float;
            desc.renderTarget = true;
            desc.numMipmaps = levels;
            const tex = new GPUTexture(desc);
            e = new PmremEntry(tex, w, levels);
            for (let l: u32 = 0; l < levels; l++) {
                const vd = new GPUTextureViewDesc();
                vd.baseMipLevel = l;
                vd.mipCount = 1;
                e.levelViews.push(tex.view(vd));
                e.params.push(new GPUBuffer(BufferUsage.uniform, 32));
            }
            this.pmrems.set(t.id, e);
        }
        if (e.source === src && e.version == t.version) return e.view;
        const srcLevels = this.levels(t);
        const p = this.pmremStaging;
        for (let l: u32 = 0; l < levels; l++) {
            p[0] = levels > 1 ? <f32>(<f64>l / <f64>(levels - 1)) : 0;
            p[1] = <f32>(srcLevels - 1);
            p[2] = <f32>(<f64>sw * <f64>sh);
            p[3] = 0;
            p[4] = !cube && t.colorSpace == "srgb" ? 1 : 0;
            p[5] = !cube && t.premultiplyAlpha ? 1 : 0;
            p[6] = cube || t.flipY ? 1 : 0;
            p[7] = 0;
            e.params[l].update(0, p.buffer);
            const group = new GPUBindGroup(this.pmremLayout!, [new GPUBindGroupUBO(2, e.params[l])],
                [new GPUBindGroupTexture(0, src)], [new GPUBindGroupSampler(1, this.pmremSampler!)]);
            const color = this.colorAttachment;
            color.view = e.levelViews[l];
            color.loadOp = LoadOp.clear;
            color.storeOp = StoreOp.store;
            color.clearR = 0; color.clearG = 0; color.clearB = 0; color.clearA = 0;
            const pd = this.passDesc;
            pd.label = "three pmrem";
            pd.color = [color];
            pd.depthView = null;
            const pass = target.beginRenderPass(pd);
            pass.setPipeline(this.pmremPipeline!);
            pass.setBindGroup(0, group);
            pass.draw(3);
            pass.finish();
        }
        e.source = src;
        e.version = t.version;
        return e.view;
    }

    /// Levels of `pmrem(t)`'s chain (0 before it exists).
    pmremLevels(t: Texture): u32 {
        return this.pmrems.has(t.id) ? this.pmrems.get(t.id).levels : 0;
    }

    private ensurePmremPipeline(): bool {
        if (this.pmremPipeline != null) return true;
        if (this.pmremBroken || !this.ensurePipeline()) return false;
        let module: GPUShaderModule? = null;
        for (let i = 0; i < PMREM_SHADER_NAMES.length && module == null; i++) {
            module = this.context.shader(PMREM_SHADER_NAMES[i]);
        }
        const layout = module != null ? GPUBindGroupLayout.fromShader(module!, 0) : null;
        if (module == null || layout == null) {
            this.context.log("three: PMREM disabled: shader asset 'three/shaders/three_pmrem.wgsl' not found");
            this.pmremBroken = true;
            return false;
        }
        this.pmremLayout = layout;
        const target = new GPUColorTargetDesc();
        target.format = TextureFormat.rgba16float;
        const d = new GPUPipelineDesc();
        d.vertexModule = module;
        d.vertexEntryPoint = "vs_blit";
        d.fragmentModule = module;
        d.fragmentEntryPoint = "fs_prefilter";
        d.colorTargets = [target];
        d.bindGroupLayouts = [layout];
        this.pmremPipeline = new GPUPipeline(d);
        this.pmremSampler = new GPUSampler(Filter.linear, Filter.linear, Filter.linear,
            WrapMode.repeat, WrapMode.clampToEdge);
        return true;
    }

    private ensureCubePipeline(): bool {
        if (this.cubePipeline != null) return true;
        if (this.cubeBroken || !this.ensurePipeline()) return false;
        let module: GPUShaderModule? = null;
        for (let i = 0; i < CUBE_SHADER_NAMES.length && module == null; i++) {
            module = this.context.shader(CUBE_SHADER_NAMES[i]);
        }
        const layout = module != null ? GPUBindGroupLayout.fromShader(module!, 0) : null;
        if (module == null || layout == null) {
            this.context.log("three: cube textures disabled: shader asset 'three/shaders/three_cube.wgsl' not found");
            this.cubeBroken = true;
            return false;
        }
        this.cubeModule = module;
        this.cubeLayout = layout;
        const target = new GPUColorTargetDesc();
        target.format = TextureFormat.rgba16float;
        const d = new GPUPipelineDesc();
        d.vertexModule = module;
        d.vertexEntryPoint = "vs_blit";
        d.fragmentModule = module;
        d.fragmentEntryPoint = "fs_cube_to_equirect";
        d.colorTargets = [target];
        d.bindGroupLayouts = [layout];
        this.cubePipeline = new GPUPipeline(d);
        return true;
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
        const hdrTarget = new GPUColorTargetDesc();
        hdrTarget.format = TextureFormat.rgba16float;
        const dh = new GPUPipelineDesc();
        dh.vertexModule = module;
        dh.vertexEntryPoint = "vs_blit";
        dh.fragmentModule = module;
        dh.fragmentEntryPoint = "fs_blit";
        dh.colorTargets = [hdrTarget];
        this.mipPipelineHDR = new GPUPipeline(dh);
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
