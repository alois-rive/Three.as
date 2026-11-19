// three.js CompressedTexture: block-compressed texels with their own mip
// levels (`mipmaps`, level 0 first), uploaded as is: S3TC/DXT1 and DXT5
// (BC1, BC3), BPTC (BC7), ETC2 (RGB, RGBA) and ASTC 4x4, 6x6, 8x8, when the
// device has the matching feature (`bc`, `etc2`, `astc`; KTX2Loader checks).
// The texture's size must be a multiple of the block size. Rows are top
// first, so flipY is false, as three.js.

import { Context } from "rive/host";
import { GPUTexture, GPUTextureDesc, GPUTextureView } from "rive/gpu";
import { TextureFormat } from "rive/gpu_enums";
import { rive_gpu_texture_upload_v1 } from "rive/bindings";
import { Texture } from "./Texture";
import {
    RGB_S3TC_DXT1_Format, RGBA_S3TC_DXT1_Format, RGBA_S3TC_DXT5_Format, RGBA_BPTC_Format, RGB_ETC2_Format,
    RGBA_ETC2_EAC_Format, RGBA_ASTC_4x4_Format, RGBA_ASTC_6x6_Format, RGBA_ASTC_8x8_Format, UnsignedByteType,
    LinearFilter, LinearMipmapLinearFilter,
} from "../constants";

const uploadRegion = new rive_gpu_texture_upload_v1();

/// One mip level: its bytes and size in texels.
export class CompressedMipmap {
    data: Uint8Array;
    width: u32;
    height: u32;

    constructor(data: Uint8Array, width: u32, height: u32) {
        this.data = data;
        this.width = width;
        this.height = height;
    }
}

/// The GPU format of a compressed three.js format (rgba8unorm when unknown).
export function compressedGPUFormat(format: i32): TextureFormat {
    if (format == RGB_S3TC_DXT1_Format || format == RGBA_S3TC_DXT1_Format) return TextureFormat.bc1unorm;
    if (format == RGBA_S3TC_DXT5_Format) return TextureFormat.bc3unorm;
    if (format == RGBA_BPTC_Format) return TextureFormat.bc7unorm;
    if (format == RGB_ETC2_Format) return TextureFormat.etc2rgb8;
    if (format == RGBA_ETC2_EAC_Format) return TextureFormat.etc2rgba8;
    if (format == RGBA_ASTC_4x4_Format) return TextureFormat.astc4x4;
    if (format == RGBA_ASTC_6x6_Format) return TextureFormat.astc6x6;
    if (format == RGBA_ASTC_8x8_Format) return TextureFormat.astc8x8;
    return TextureFormat.rgba8unorm;
}

/// Block width, height and bytes of a compressed three.js format.
export function blockWidth(format: i32): u32 {
    if (format == RGBA_ASTC_6x6_Format) return 6;
    if (format == RGBA_ASTC_8x8_Format) return 8;
    return 4;
}

export function blockBytes(format: i32): u32 {
    return format == RGB_S3TC_DXT1_Format || format == RGBA_S3TC_DXT1_Format || format == RGB_ETC2_Format ? 8 : 16;
}

/// The device feature a compressed format needs: "bc", "etc2" or "astc".
export function compressedFeature(format: i32): string {
    if (format == RGB_ETC2_Format || format == RGBA_ETC2_EAC_Format) return "etc2";
    if (format == RGBA_ASTC_4x4_Format || format == RGBA_ASTC_6x6_Format || format == RGBA_ASTC_8x8_Format) return "astc";
    return "bc";
}

export class CompressedTexture extends Texture {
    readonly isCompressedTexture: bool = true;
    mipmaps: Array<CompressedMipmap>;
    dataWidth: u32;
    dataHeight: u32;

    private gpuTexture: GPUTexture? = null;
    private gpuView: GPUTextureView? = null;
    private uploadedVersion: i32 = -1;

    constructor(mipmaps: Array<CompressedMipmap>, width: u32, height: u32, format: i32, type: i32 = UnsignedByteType) {
        super(null);
        this.mipmaps = mipmaps;
        this.dataWidth = width;
        this.dataHeight = height;
        this.format = format;
        this.type = type;
        this.flipY = false;
        this.generateMipmaps = false;   // the levels come with the data
        this.magFilter = LinearFilter;
        this.minFilter = mipmaps.length > 1 ? LinearMipmapLinearFilter : LinearFilter;
        this.version = 1;
    }

    override get width(): u32 { return this.dataWidth; }
    override get height(): u32 { return this.dataHeight; }
    override get mipLevelCount(): u32 { return this.gpuTexture != null ? <u32>this.mipmaps.length : 1; }

    override update(context: Context): void {
        if (this.uploadedVersion == this.version || this.mipmaps.length == 0) return;
        const format = compressedGPUFormat(this.format);
        let tex = this.gpuTexture;
        if (tex == null || tex.width != this.dataWidth || tex.height != this.dataHeight || tex.format != format) {
            if (tex != null) tex.release();
            const desc = new GPUTextureDesc();
            desc.width = this.dataWidth;
            desc.height = this.dataHeight;
            desc.format = format;
            desc.numMipmaps = <u32>this.mipmaps.length;
            tex = new GPUTexture(desc);
            this.gpuTexture = tex;
            this.gpuView = tex.view();
        }
        const bw = blockWidth(this.format), bb = blockBytes(this.format);
        for (let l = 0; l < this.mipmaps.length; l++) {
            const m = this.mipmaps[l];
            const blocksX = (m.width + bw - 1) / bw, blocksY = (m.height + bw - 1) / bw;
            uploadRegion.mipLevel = <u32>l;
            uploadRegion.width = blocksX * bw;   // the level's physical size
            uploadRegion.height = blocksY * bw;
            uploadRegion.bytesPerRow = blocksX * bb;   // a row of blocks
            uploadRegion.rowsPerImage = 0;
            // Rive checks the data against bytesPerRow x texel rows: pad.
            const d = m.data;
            const padded = new Uint8Array(<i32>(blocksX * bb * blocksY * bw));
            padded.set(d.subarray(0, min<i32>(d.length, padded.length)));
            const bytes = padded.buffer;
            tex.upload(uploadRegion, bytes);
        }
        uploadRegion.mipLevel = 0;
        uploadRegion.bytesPerRow = 0;
        uploadRegion.rowsPerImage = 0;
        this.uploadedVersion = this.version;
    }

    override getView(): GPUTextureView? { return this.gpuView; }

    override dispose(): void {
        const tex = this.gpuTexture;
        if (tex != null) tex.release();
        this.gpuTexture = null;
        this.gpuView = null;
        this.uploadedVersion = -1;
        super.dispose();
    }
}
