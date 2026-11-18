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
// renderer's output), flipped like a Rive image.

import { Context } from "rive/host";
import { GPUCanvas, GPUTexture, GPUTextureDesc, GPUTextureView } from "rive/gpu";
import { TextureFormat } from "rive/gpu_enums";
import { Image } from "rive/image";
import { Texture } from "../textures/Texture";
import { LinearFilter, SRGBColorSpace, NoColorSpace, UnsignedByteType } from "../constants";

let _rtId: i32 = 0;

export class RenderTargetOptions {
    depthBuffer: bool = true;
    /// MSAA samples (above 1: 4x where supported).
    samples: i32 = 0;
    generateMipmaps: bool = false;
    /// UnsignedByteType (sRGB, a Rive canvas), or HalfFloatType / FloatType:
    /// linear HDR colour in an rgba16float texture (no tone mapping or sRGB
    /// encoding when rendered into), as post-processing wants.
    type: i32 = UnsignedByteType;
}

/// The texture of a RenderTarget: samples its canvas.
export class RenderTargetTexture extends Texture {
    readonly isRenderTargetTexture: bool = true;
    canvas: GPUCanvas? = null;
    /// The HDR colour texture (HalfFloatType targets).
    hdr: GPUTexture? = null;
    hdrView: GPUTextureView? = null;
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

    override getView(): GPUTextureView? {
        const h = this.hdrView;
        if (h != null) return h;
        const c = this.canvas;
        return c != null ? c.view : null;
    }
}

export class RenderTarget {
    readonly isRenderTarget: bool = true;
    id: i32;
    width: u32;
    height: u32;
    depthBuffer: bool;
    samples: i32;
    /// UnsignedByteType, HalfFloatType or FloatType (see RenderTargetOptions).
    type: i32;
    texture: RenderTargetTexture = new RenderTargetTexture();
    /// Bumped by setSize; the renderer resizes on the next render.
    version: i32 = 0;

    constructor(width: u32 = 1, height: u32 = 1, options: RenderTargetOptions? = null) {
        this.id = _rtId++;
        this.width = width;
        this.height = height;
        const o = options != null ? options : new RenderTargetOptions();
        this.depthBuffer = o.depthBuffer;
        this.samples = o.samples;
        this.type = o.type;
        if (o.type != UnsignedByteType) this.texture.colorSpace = NoColorSpace;
        this.texture.generateMipmaps = o.generateMipmaps;
        this.texture.pixelWidth = width;
        this.texture.pixelHeight = height;
    }

    /// A target of the same size and options (a texture of its own).
    clone(): RenderTarget {
        const o = new RenderTargetOptions();
        o.depthBuffer = this.depthBuffer;
        o.samples = this.samples;
        o.type = this.type;
        o.generateMipmaps = this.texture.generateMipmaps;
        return new RenderTarget(this.width, this.height, o);
    }

    setSize(width: u32, height: u32): void {
        if (width == this.width && height == this.height) return;
        this.width = width;
        this.height = height;
        this.texture.pixelWidth = width;
        this.texture.pixelHeight = height;
        this.version++;
        this.texture.version++;
    }

    /// What it rendered, as a Rive Image (for Renderer.drawImage), once
    /// rendered into.
    get image(): Image? {
        const c = this.texture.canvas;
        return c != null ? c.image : null;
    }

    /// Whether it holds linear HDR colour.
    get isHDR(): bool { return this.type != UnsignedByteType; }

    /// The HDR texture behind the target (made on first use; internal).
    ensureHDR(): GPUTextureView? {
        let t = this.texture.hdr;
        if (t == null || t.width != this.width || t.height != this.height) {
            if (t != null) t.release();
            const d = new GPUTextureDesc();
            d.width = this.width;
            d.height = this.height;
            d.format = TextureFormat.rgba16float;
            d.renderTarget = true;
            t = new GPUTexture(d);
            this.texture.hdr = t;
            this.texture.hdrView = t.view();
        }
        return this.texture.hdrView;
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

    dispose(): void {
        const h = this.texture.hdr;
        if (h != null) h.release();
        this.texture.hdr = null;
        this.texture.hdrView = null;
        const c = this.texture.canvas;
        if (c != null) c.release();
        this.texture.canvas = null;
        this.texture.dispose();
    }
}

/// three.js's name for it.
export class WebGLRenderTarget extends RenderTarget {
    constructor(width: u32 = 1, height: u32 = 1, options: RenderTargetOptions? = null) {
        super(width, height, options);
    }
}
