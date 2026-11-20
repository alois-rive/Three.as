// Texture views for the renderer (internal), like three.js's WebGLTextures:
// calls Texture.update once a frame, and gives each texture the view to
// bind. A texture that wants mipmaps (generateMipmaps and a mipmap
// minFilter) is copied into a mipmapped texture of our own and its levels
// drawn down from it, again only when the source changes (a new view or
// size, or texture.version). The views and bind groups those passes use are
// made with their texture and kept (none a redraw), and everything is
// released when the texture is disposed (its "dispose" event, Disposal).

import { Context } from "rive/host";
import {
    GPUTarget, GPUTexture, GPUTextureDesc, GPUTextureView, GPUTextureViewDesc, GPUPipeline, GPUPipelineDesc,
    GPUColorTargetDesc, GPUBindGroup, GPUBindGroupTexture, GPUBindGroupSampler, GPUColorAttachment, GPUPassDesc,
    GPURenderPass, GPUSampler, GPUShaderModule, GPUBuffer, GPUBindGroupUBO, GPUBindGroupLayout,
} from "rive/gpu";
import { TextureFormat, Filter, WrapMode, LoadOp, StoreOp, BufferUsage } from "rive/gpu_enums";
import { Texture } from "../../textures/Texture";
import { CubeTexture } from "../../textures/CubeTexture";
import { RendererData } from "../../core/RendererData";
import {
    DisposeQueue, DisposeListener, DISPOSED_TEXTURE, DISPOSED_PMREM, PMREM_DISPOSE_EVENT, RendererSlot, dataOf, setDataOf,
    detach,
} from "./Disposal";
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
    /// Per level: its params over `groupSource` (rebuilt when the source
    /// view changes).
    groups: Array<GPUBindGroup?> = [];
    groupSource: GPUTextureView? = null;
    source: GPUTextureView? = null;
    version: i32 = -1;
    width: u32;
    levels: u32;
    /// PMREMResult.dispose() of its texture.
    listener: DisposeListener? = null;

    constructor(texture: GPUTexture, w: u32, levels: u32) {
        this.texture = texture;
        this.view = texture.view();
        this.width = w;
        this.levels = levels;
    }

    releaseGroups(): void {
        for (let i = 0; i < this.groups.length; i++) {
            const g = this.groups[i];
            if (g != null) g.release();
            this.groups[i] = null;
        }
        this.groupSource = null;
    }

    release(): void {
        detach(this.listener);
        this.listener = null;
        this.releaseGroups();
        for (let i = 0; i < this.params.length; i++) this.params[i].release();
        for (let i = 0; i < this.levelViews.length; i++) this.levelViews[i].release();
        this.params = [];
        this.levelViews = [];
        this.view.release();
        this.texture.release();
    }
}

// A CubeTexture's equirectangular conversion.
class CubeEquirect {
    texture: GPUTexture;
    view: GPUTextureView;
    faces: Array<GPUTextureView?> = [null, null, null, null, null, null];
    /// The conversion's bind group, over `faces`.
    group: GPUBindGroup? = null;
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

    release(): void {
        const g = this.group;
        if (g != null) g.release();
        this.group = null;
        this.params.release();
        this.view.release();
        this.texture.release();
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
    /// Each level's own view, and the group drawing level k (k >= 1) from
    /// level k - 1 (made with the texture).
    levelViews: Array<GPUTextureView> = [];
    groups: Array<GPUBindGroup> = [];
    /// The group drawing level 0 from `group0Source`.
    group0: GPUBindGroup? = null;
    group0Source: GPUTextureView? = null;

    constructor(texture: GPUTexture, view: GPUTextureView, source: GPUTextureView, version: i32, w: u32, h: u32) {
        this.texture = texture;
        this.view = view;
        this.source = source;
        this.version = version;
        this.width = w;
        this.height = h;
    }

    release(): void {
        const g0 = this.group0;
        if (g0 != null) g0.release();
        this.group0 = null;
        this.group0Source = null;
        for (let i = 0; i < this.groups.length; i++) this.groups[i].release();
        for (let i = 0; i < this.levelViews.length; i++) this.levelViews[i].release();
        this.groups = [];
        this.levelViews = [];
        this.view.release();
        this.texture.release();
    }
}

/// A GPU texture standing in for a texture that copies were written into
/// (an image, a canvas, a FramebufferTexture), valid while the texture's
/// version is the one recorded.
export class CopyTarget {
    texture: GPUTexture;
    view: GPUTextureView;
    format: u32;
    version: i32;

    constructor(texture: GPUTexture, view: GPUTextureView, format: u32, version: i32) {
        this.texture = texture;
        this.view = view;
        this.format = format;
        this.version = version;
    }

    release(): void {
        this.view.release();
        this.texture.release();
    }
}

/// What a renderer keeps for a texture (on the texture, Disposal).
class TextureGPU extends RendererData {
    /// The renderer's view counter of the last update.
    frame: i32 = -1;
    chain: MipChain? = null;
    copied: CopyTarget? = null;
    cube: CubeEquirect? = null;
    pmrem: PmremEntry? = null;
    listener: DisposeListener? = null;

    releasePmrem(): void {
        const e = this.pmrem;
        if (e != null) e.release();
        this.pmrem = null;
    }

    override release(): void {
        detach(this.listener);
        this.listener = null;
        this.releasePmrem();
        const c = this.chain;
        if (c != null) c.release();
        this.chain = null;
        const o = this.copied;
        if (o != null) o.release();
        this.copied = null;
        const ce = this.cube;
        if (ce != null) ce.release();
        this.cube = null;
    }
}

export function wantsMipmaps(t: Texture): bool {
    const f = t.minFilter;
    return t.generateMipmaps && (f == NearestMipmapNearestFilter || f == NearestMipmapLinearFilter
        || f == LinearMipmapNearestFilter || f == LinearMipmapLinearFilter);
}

export class GPUTextures {
    private context: Context;
    private mipModule: GPUShaderModule? = null;
    private mipPipeline: GPUPipeline? = null;
    private mipPipelineHDR: GPUPipeline? = null;
    private cubeModule: GPUShaderModule? = null;
    private cubePipeline: GPUPipeline? = null;
    private cubeLayout: GPUBindGroupLayout? = null;
    private cubeBroken: bool = false;
    private cubeStaging: Float32Array = new Float32Array(4);
    private pmremPipeline: GPUPipeline? = null;
    private pmremLayout: GPUBindGroupLayout? = null;
    private pmremSampler: GPUSampler? = null;
    private pmremBroken: bool = false;
    private pmremStaging: Float32Array = new Float32Array(8);
    private mipSampler: GPUSampler? = null;
    private mipLayout: GPUBindGroupLayout? = null;
    private mipLayoutHDR: GPUBindGroupLayout? = null;
    private mipBroken: bool = false;
    private colorAttachment: GPUColorAttachment = new GPUColorAttachment();
    private colorList: Array<GPUColorAttachment> = [];
    private passDesc: GPUPassDesc = new GPUPassDesc();
    private renderPass: GPURenderPass? = null;
    // Each texture's state is on the texture (TextureGPU, Disposal).
    private queue: DisposeQueue;
    private slot: RendererSlot;
    private _count: i32 = 0;

    constructor(context: Context, queue: DisposeQueue, slot: RendererSlot) {
        this.context = context;
        this.queue = queue;
        this.slot = slot;
        this.colorList.push(this.colorAttachment);
    }

    /// Lets the texture draw or upload (once a frame), before any pass.
    update(t: Texture, frame: i32): void {
        const d = this.stateOf(t);
        if (d.frame == frame) return;
        d.frame = frame;
        t.update(this.context);
    }

    private peek(t: Texture): TextureGPU? {
        const d = dataOf(t, this.slot);
        return d != null ? d as TextureGPU : null;
    }

    /// `t`'s state, made (listening for its "dispose") when it has none.
    private stateOf(t: Texture): TextureGPU {
        const d = dataOf(t, this.slot);
        if (d != null) return d as TextureGPU;
        const n = new TextureGPU();
        setDataOf(t, this.slot, n);
        n.listener = new DisposeListener(this.queue, DISPOSED_TEXTURE, n).attach(t);
        this._count++;
        return n;
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
            source = this.baseView(t);
            w = t.width;
            h = t.height;
            if (t.isHDRSource) format = <u32>TextureFormat.rgba16float;
            const d = this.peek(t);
            if (d != null && d.copied != null) format = d.copied!.format;
        }
        if (source == null) return null;
        if (!wantsMipmaps(t) || (w <= 1 && h <= 1) || this.mipBroken) return source;
        const d = this.stateOf(t);
        let chain = d.chain;
        if (chain != null && chain.source === source && chain.version == t.version
                && chain.width == w && chain.height == h) {
            return chain.view;
        }
        chain = this.build(t, d, source!, w, h, chain, target, format);
        return chain != null ? chain.view : source;
    }

    /// Mip levels of the view `view()` returned (1 when not mipmapped).
    levels(t: Texture): u32 {
        const d = this.peek(t);
        if (d == null || d.chain == null) return t.mipLevelCount;
        return d.chain!.texture.numMipmaps;
    }

    /// Textures the renderer has prepared and not disposed
    /// (renderer.info.memory.textures).
    get count(): i32 { return this._count; }

    /// The texture's own view (no mip chain): what a texture copy wrote
    /// into it (copyTextureToTexture into an image or a
    /// FramebufferTexture), else `t.getView()`.
    baseView(t: Texture): GPUTextureView? {
        const d = this.peek(t);
        if (d != null && d.copied != null) {
            const o = d.copied!;
            // The texture changed on its own since (a new image, a redraw):
            // its content wins.
            if (o.version == t.version) return o.view;
            o.release();
            d.copied = null;
        }
        return t.getView();
    }

    /// The GPU texture copies write into for `t` (internal:
    /// copyTextureToTexture), or null.
    copyTarget(t: Texture): CopyTarget? {
        const d = this.peek(t);
        if (d == null || d.copied == null) return null;
        const o = d.copied!;
        return o.version == t.version ? o : null;
    }

    /// Rebuilds `t`'s mip chain at its next use (its level 0 was written).
    invalidate(t: Texture): void {
        const d = this.peek(t);
        if (d != null && d.chain != null) d.chain!.version = -0x7fffffff;
    }

    /// Makes `t` sample `texture` from now on, until `t` changes on its own.
    setCopyTarget(t: Texture, texture: GPUTexture, view: GPUTextureView, format: u32): CopyTarget {
        const d = this.stateOf(t);
        const old = d.copied;
        if (old != null && old.texture !== texture) old.release();
        const o = new CopyTarget(texture, view, format, t.version);
        d.copied = o;
        return o;
    }

    /// Frees a disposed texture's state (its "dispose").
    free(data: RendererData): void {
        if (data.serial != this.slot.serial) return;
        data.release();
        data.serial = -1;
        this._count--;
    }

    /// Frees a texture's PMREM only (PMREMResult.dispose()); it is
    /// prefiltered again if used again.
    freePmrem(data: RendererData): void {
        if (data.serial != this.slot.serial) return;
        (data as TextureGPU).releasePmrem();
    }

    /// renderer.dispose(): releases the pipelines and samplers (made again
    /// on use); the state on textures is left to be collected, or released
    /// when replaced.
    reset(): void {
        this._count = 0;
        releasePipeline(this.mipPipeline); this.mipPipeline = null;
        releasePipeline(this.mipPipelineHDR); this.mipPipelineHDR = null;
        releasePipeline(this.cubePipeline); this.cubePipeline = null;
        releasePipeline(this.pmremPipeline); this.pmremPipeline = null;
        releaseLayout(this.mipLayout); this.mipLayout = null;
        releaseLayout(this.mipLayoutHDR); this.mipLayoutHDR = null;
        releaseLayout(this.cubeLayout); this.cubeLayout = null;
        releaseLayout(this.pmremLayout); this.pmremLayout = null;
        releaseSampler(this.mipSampler); this.mipSampler = null;
        releaseSampler(this.pmremSampler); this.pmremSampler = null;
        this.mipModule = null;
        this.cubeModule = null;
        this.renderPass = null;
    }

    private build(t: Texture, d: TextureGPU, source: GPUTextureView, w: u32, h: u32, old: MipChain?,
                  target: GPUTarget, format: u32): MipChain? {
        if (!this.ensurePipeline()) return null;
        const levels = mipLevels(w, h);
        const hdr = format != <u32>TextureFormat.rgba8unorm;
        const layout = hdr ? this.mipLayoutHDR! : this.mipLayout!;
        let chain = old;
        if (chain == null || chain.width != w || chain.height != h || chain.format != format) {
            if (chain != null) chain.release();
            const desc = new GPUTextureDesc();
            desc.width = w;
            desc.height = h;
            desc.format = <TextureFormat>format;
            desc.renderTarget = true;
            desc.numMipmaps = levels;
            const tex = new GPUTexture(desc);
            chain = new MipChain(tex, tex.view(), source, t.version, w, h);
            chain.format = format;
            // Each level's view, and the groups drawing a level from the one
            // above, once.
            for (let level: u32 = 0; level < levels; level++) {
                const vd = new GPUTextureViewDesc();
                vd.baseMipLevel = level;
                vd.mipCount = 1;
                chain.levelViews.push(tex.view(vd));
                if (level > 0) chain.groups.push(this.mipGroup(layout, chain.levelViews[level - 1]));
            }
            d.chain = chain;
        }
        chain.source = source;
        chain.version = t.version;
        let g0 = chain.group0;
        if (g0 == null || chain.group0Source !== source) {
            if (g0 != null) g0.release();
            g0 = this.mipGroup(layout, source);
            chain.group0 = g0;
            chain.group0Source = source;
        }
        // Level 0 from the source, then each level from the one above.
        const pipeline = hdr ? this.mipPipelineHDR! : this.mipPipeline!;
        for (let level: u32 = 0; level < levels; level++) {
            this.blit(pipeline, level == 0 ? g0! : chain.groups[level - 1], chain.levelViews[level], target);
        }
        return chain;
    }

    private mipGroup(layout: GPUBindGroupLayout, from: GPUTextureView): GPUBindGroup {
        return new GPUBindGroup(layout, [], [new GPUBindGroupTexture(0, from)],
            [new GPUBindGroupSampler(1, this.mipSampler!)]);
    }

    private blit(pipeline: GPUPipeline, group: GPUBindGroup, into: GPUTextureView, target: GPUTarget): void {
        const color = this.colorAttachment;
        color.view = into;
        color.loadOp = LoadOp.dontCare;
        color.storeOp = StoreOp.store;
        const pd = this.passDesc;
        pd.label = "three mip";
        pd.color = this.colorList;
        pd.depthView = null;
        const pass = target.beginRenderPass(pd, this.renderPass);
        this.renderPass = pass;
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
        const d = this.stateOf(t);
        let ce = d.cube;
        if (ce == null || ce.width != w || ce.height != h) {
            if (ce != null) ce.release();
            const desc = new GPUTextureDesc();
            desc.width = w;
            desc.height = h;
            desc.format = TextureFormat.rgba16float;
            desc.renderTarget = true;
            ce = new CubeEquirect(new GPUTexture(desc), w, h);
            d.cube = ce;
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
        let group = ce.group;
        let facesChanged = group == null;
        for (let i = 0; i < 6 && !facesChanged; i++) facesChanged = ce.faces[i] !== views[i];
        if (facesChanged) {
            const textures: Array<GPUBindGroupTexture> = [];
            for (let i = 0; i < 6; i++) {
                textures.push(new GPUBindGroupTexture(<u32>i, views[i]));
                ce.faces[i] = views[i];
            }
            if (group != null) group.release();
            group = new GPUBindGroup(this.cubeLayout!, [new GPUBindGroupUBO(7, ce.params)], textures,
                [new GPUBindGroupSampler(6, this.mipSampler!)]);
            ce.group = group;
        }
        const color = this.colorAttachment;
        color.view = ce.view;
        color.loadOp = LoadOp.dontCare;
        color.storeOp = StoreOp.store;
        const pd = this.passDesc;
        pd.label = "three cube";
        pd.color = this.colorList;
        pd.depthView = null;
        const pass = target.beginRenderPass(pd, this.renderPass);
        this.renderPass = pass;
        pass.setPipeline(this.cubePipeline!);
        pass.setBindGroup(0, group!);
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
            const ce = this.stateOf(t).cube!;
            sw = ce.width; sh = ce.height;
        } else {
            sw = t.width; sh = t.height;
        }
        let w: u32 = 128;
        while (w < sw && w < 1024) w <<= 1;
        const h = w / 2;
        const levels = mipLevels(w / 16, w / 16);   // the last level is 16 x 8
        const d = this.stateOf(t);
        let e = d.pmrem;
        if (e == null || e.width != w) {
            if (e != null) e.release();
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
                e.groups.push(null);
            }
            // PMREMResult.dispose() frees it alone.
            e.listener = new DisposeListener(this.queue, DISPOSED_PMREM, d).attach(t, PMREM_DISPOSE_EVENT);
            d.pmrem = e;
        }
        if (e.source === src && e.version == t.version) return e.view;
        if (e.groupSource !== src) e.releaseGroups();
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
            let group = e.groups[l];
            if (group == null) {
                group = new GPUBindGroup(this.pmremLayout!, [new GPUBindGroupUBO(2, e.params[l])],
                    [new GPUBindGroupTexture(0, src)], [new GPUBindGroupSampler(1, this.pmremSampler!)]);
                e.groups[l] = group;
            }
            const color = this.colorAttachment;
            color.view = e.levelViews[l];
            color.loadOp = LoadOp.dontCare;
            color.storeOp = StoreOp.store;
            const pd = this.passDesc;
            pd.label = "three pmrem";
            pd.color = this.colorList;
            pd.depthView = null;
            const pass = target.beginRenderPass(pd, this.renderPass);
            this.renderPass = pass;
            pass.setPipeline(this.pmremPipeline!);
            pass.setBindGroup(0, group!);
            pass.draw(3);
            pass.finish();
        }
        e.groupSource = src;
        e.source = src;
        e.version = t.version;
        return e.view;
    }

    /// Levels of `pmrem(t)`'s chain (0 before it exists).
    pmremLevels(t: Texture): u32 {
        const d = this.peek(t);
        return d != null && d.pmrem != null ? d.pmrem!.levels : 0;
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
        this.mipLayout = this.mipPipeline!.getBindGroupLayout(0);
        this.mipLayoutHDR = this.mipPipelineHDR!.getBindGroupLayout(0);
        this.mipSampler = new GPUSampler(Filter.linear, Filter.linear, Filter.nearest,
            WrapMode.clampToEdge, WrapMode.clampToEdge);
        return true;
    }
}

function releasePipeline(p: GPUPipeline?): void {
    if (p != null) p.release();
}

function releaseLayout(l: GPUBindGroupLayout?): void {
    if (l != null) l.release();
}

function releaseSampler(s: GPUSampler?): void {
    if (s != null) s.release();
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
