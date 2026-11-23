// three.js RenderTarget (WebGLRenderTarget): render a scene into
// `texture` instead of the screen, then use it as a material map, or draw
// its Rive `Image` (renderTarget.image) in 2D.
//
//     const rt = new RenderTarget(512, 512);
//     renderer.setRenderTarget(rt);
//     renderer.render(otherScene, otherCamera);
//     renderer.setRenderTarget(null);
//     material.map = rt.texture;
//
// The size is in pixels. The texture holds sRGB, premultiplied colour (the
// renderer's output), flipped like a Rive image. `count` > 1 makes a
// multiple render target (`textures`, written by a ShaderMaterial's
// @location(n) outputs); `depthTexture` keeps the depth for shaders.

import { Context } from "rive/host";
import { GPUCanvas, GPUTexture, GPUTextureDesc, GPUTextureView } from "rive/gpu";
import { TextureFormat } from "rive/gpu_enums";
import { Image } from "rive/image";
import { Texture } from "../textures/Texture";
import { DepthTexture } from "../textures/DepthTexture";
import { Vector4 } from "../math/Vector4";
import { Event, EventDispatcher } from "../core/EventDispatcher";
import { isFloat32 } from "../textures/DataUpload";
import {
    ClampToEdgeWrapping, LinearFilter, SRGBColorSpace, NoColorSpace, UnsignedByteType,
} from "../constants";

let _rtId: i32 = 0;

export class RenderTargetOptions {
    depthBuffer: bool = true;
    /// MSAA samples (above 1: 4x where supported; not with `count` > 1 or
    /// a depthTexture).
    samples: i32 = 0;
    generateMipmaps: bool = false;
    /// UnsignedByteType (sRGB, a Rive canvas), or HalfFloatType / FloatType:
    /// linear HDR colour in an rgba16float texture (no tone mapping or sRGB
    /// encoding when rendered into), as post-processing wants.
    type: i32 = UnsignedByteType;
    /// "RGBA32F" with FloatType: an rgba32float texture where the device
    /// renders into 32-bit floats (`colorBufferFloat`), rgba16float
    /// elsewhere. Sample it nearest or with textureLoad (WebGPU does not
    /// filter 32-bit floats); it does not blend, multisample or copy.
    internalFormat: string? = null;
    /// The textures' wrapping and filters, as three.js's options.
    wrapS: i32 = ClampToEdgeWrapping;
    wrapT: i32 = ClampToEdgeWrapping;
    magFilter: i32 = LinearFilter;
    minFilter: i32 = LinearFilter;
    /// Colour attachments (1 to 4): `textures` has one texture each.
    count: i32 = 1;
    /// Renders keep their depth in it, for shaders to read.
    depthTexture: DepthTexture? = null;
}

/// The texture of a RenderTarget: samples its canvas (or its own texture:
/// HDR targets and the extra attachments of a multiple render target).
export class RenderTargetTexture extends Texture {
    readonly isRenderTargetTexture: bool = true;
    canvas: GPUCanvas? = null;
    /// The colour texture of HalfFloatType targets and of a multiple render
    /// target's extra attachments (`gpuFormat`).
    hdr: GPUTexture? = null;
    hdrView: GPUTextureView? = null;
    gpuFormat: u32 = <u32>TextureFormat.rgba16float;
    pixelWidth: u32 = 0;
    pixelHeight: u32 = 0;

    constructor() {
        super(null);
        this.flipY = true;
        this.premultiplyAlpha = true;
        this.colorSpace = SRGBColorSpace;
        this.minFilter = LinearFilter;
        this.magFilter = LinearFilter;
        this.generateMipmaps = false;
    }

    override get width(): u32 { return this.pixelWidth; }
    override get height(): u32 { return this.pixelHeight; }

    override get isHDRSource(): bool { return this.hdrView != null && this.gpuFormat == <u32>TextureFormat.rgba16float; }

    override getView(): GPUTextureView? {
        const h = this.hdrView;
        if (h != null) return h;
        const c = this.canvas;
        return c != null ? c.view : null;
    }

    /// Its own colour texture in `format`, made or resized (internal).
    ensureOwn(format: u32): GPUTextureView? {
        let t = this.hdr;
        if (t == null || t.width != this.pixelWidth || t.height != this.pixelHeight || this.gpuFormat != format) {
            const old = this.hdrView;
            if (old != null) old.release();
            if (t != null) t.release();
            const d = new GPUTextureDesc();
            d.width = this.pixelWidth;
            d.height = this.pixelHeight;
            d.format = <TextureFormat>format;
            d.renderTarget = true;
            t = new GPUTexture(d);
            this.hdr = t;
            this.hdrView = t.view();
            this.gpuFormat = format;
        }
        return this.hdrView;
    }

    releaseOwn(): void {
        const v = this.hdrView;
        if (v != null) v.release();
        this.hdrView = null;
        const h = this.hdr;
        if (h != null) h.release();
        this.hdr = null;
    }
}

export class RenderTarget extends EventDispatcher {
    readonly isRenderTarget: bool = true;
    id: i32;
    width: u32;
    height: u32;
    depthBuffer: bool;
    samples: i32;
    /// UnsignedByteType, HalfFloatType or FloatType (see RenderTargetOptions).
    type: i32;
    /// The first colour attachment (textures[0]).
    texture: RenderTargetTexture = new RenderTargetTexture();
    /// Every colour attachment (one unless `count` > 1).
    textures: Array<RenderTargetTexture> = [];
    /// The depth of renders into it, for shaders (null: the renderer's own,
    /// not kept).
    depthTexture: DepthTexture? = null;
    /// Bumped by setSize; the renderer resizes on the next render.
    version: i32 = 0;
    /// The viewport and scissor of renders into it, in pixels from the
    /// bottom left (setSize resets both to the whole target).
    viewport: Vector4;
    scissor: Vector4;
    scissorTest: bool = false;

    constructor(width: u32 = 1, height: u32 = 1, options: RenderTargetOptions? = null) {
        super();
        this.id = _rtId++;
        this.width = width;
        this.height = height;
        this.viewport = new Vector4(0, 0, <f64>width, <f64>height);
        this.scissor = new Vector4(0, 0, <f64>width, <f64>height);
        const o = options != null ? options : new RenderTargetOptions();
        this.depthBuffer = o.depthBuffer;
        this.samples = o.samples;
        this.type = o.type;
        this.depthTexture = o.depthTexture;
        const count = max<i32>(1, min<i32>(4, o.count));
        this.textures.push(this.texture);
        for (let i = 1; i < count; i++) {
            const t = new RenderTargetTexture();
            // Extra attachments hold what the shader wrote, as is.
            t.colorSpace = NoColorSpace;
            t.premultiplyAlpha = false;
            this.textures.push(t);
        }
        for (let i = 0; i < count; i++) {
            const t = this.textures[i];
            t.type = o.type;
            t.internalFormat = o.internalFormat;
            t.wrapS = o.wrapS;
            t.wrapT = o.wrapT;
            t.magFilter = o.magFilter;
            t.minFilter = o.minFilter;
            if (o.type != UnsignedByteType) t.colorSpace = NoColorSpace;
            t.generateMipmaps = o.generateMipmaps;
            t.pixelWidth = width;
            t.pixelHeight = height;
        }
    }

    /// Colour attachments.
    get count(): i32 { return this.textures.length; }

    /// A target of the same size and options (textures of its own; a
    /// depthTexture is not shared, as three.js clones it).
    clone(): RenderTarget {
        const o = new RenderTargetOptions();
        o.depthBuffer = this.depthBuffer;
        o.samples = this.samples;
        o.type = this.type;
        o.count = this.textures.length;
        o.generateMipmaps = this.texture.generateMipmaps;
        const t = this.texture;
        o.internalFormat = t.internalFormat;
        o.wrapS = t.wrapS;
        o.wrapT = t.wrapT;
        o.magFilter = t.magFilter;
        o.minFilter = t.minFilter;
        const d = this.depthTexture;
        if (d != null) o.depthTexture = new DepthTexture(this.width, this.height, d.type, d.format);
        return new RenderTarget(this.width, this.height, o);
    }

    setSize(width: u32, height: u32): void {
        if (width == this.width && height == this.height) return;
        this.width = width;
        this.height = height;
        this.viewport.set(0, 0, <f64>width, <f64>height);
        this.scissor.set(0, 0, <f64>width, <f64>height);
        for (let i = 0; i < this.textures.length; i++) {
            const t = this.textures[i];
            t.pixelWidth = width;
            t.pixelHeight = height;
            t.version++;
        }
        this.version++;
    }

    /// What it rendered, as a Rive Image (for Renderer.drawImage), once
    /// rendered into.
    get image(): Image? {
        const c = this.texture.canvas;
        return c != null ? c.image : null;
    }

    /// Whether it holds linear HDR colour.
    get isHDR(): bool { return this.type != UnsignedByteType; }

    /// Whether it is a FloatType target whose texture asks for 32-bit
    /// floats ("RGBA32F").
    get wantsFloat32(): bool { return isFloat32(this.type, this.texture.internalFormat); }

    /// The GPU format of an HDR target: rgba32float when it wantsFloat32
    /// and the device renders 32-bit floats (`float32`:
    /// `features().colorBufferFloat`), else rgba16float.
    hdrFormat(float32: bool): u32 {
        return float32 && this.wantsFloat32 ? <u32>TextureFormat.rgba32float : <u32>TextureFormat.rgba16float;
    }

    /// The HDR texture behind the target (made on first use, in `format`;
    /// internal).
    ensureHDR(format: u32 = <u32>TextureFormat.rgba16float): GPUTextureView? {
        return this.texture.ensureOwn(format);
    }

    /// The canvas behind the target (made on first use; internal).
    ensureCanvas(context: Context): GPUCanvas? {
        let c = this.texture.canvas;
        if (c == null) {
            c = context.gpuCanvas(this.width, this.height);
            if (c == null) return null;
            this.texture.canvas = c;
        }
        if (c.width != this.width || c.height != this.height) {
            if (!c.resize(this.width, this.height)) return null;
        }
        return c;
    }

    /// Frees its canvas and textures now, and (dispatching "dispose", as
    /// three.js) each renderer's depth and MSAA attachments for it at that
    /// renderer's next render.
    dispose(): void {
        for (let i = 0; i < this.textures.length; i++) {
            const t = this.textures[i];
            t.releaseOwn();
            const c = t.canvas;
            if (c != null) c.release();
            t.canvas = null;
            t.dispose();
        }
        const d = this.depthTexture;
        if (d != null) d.dispose();
        if (this.hasListeners("dispose")) this.dispatchEvent(new Event("dispose"));
    }
}

/// three.js's name for it.
export class WebGLRenderTarget extends RenderTarget {
    constructor(width: u32 = 1, height: u32 = 1, options: RenderTargetOptions? = null) {
        super(width, height, options);
    }
}
