// three.js examples/jsm/loaders/KTX2Loader.js, for KTX2 files holding GPU
// texels directly: BC1-BC5 and BC7, ETC2 / EAC and ASTC (every 2D
// footprint) as CompressedTextures, and uncompressed RGBA8 / RGBA16F as
// DataTextures. Basis Universal (BasisLZ, UASTC transcoding) and Zstandard
// supercompression are not supported. `detectSupport(renderer)` reads the
// device's compression features into `workerConfig`, as three.js; a format
// the device cannot sample is decoded on the CPU and uploaded uncompressed
// (ThreeAS: CompressedTexture's fallback; three.js transcodes Basis to a
// format the device has instead), so `parse` returns a usable texture
// either way. Clear a `workerConfig` flag to force the fallback for that
// family (or set `texture.cpuDecode`).
//
//     const t = new KTX2Loader(context).detectSupport(renderer).load("crate");   // crate.ktx2

import { Context } from "rive/host";
import { GPURenderer } from "../../renderers/GPURenderer";
import { Texture } from "../../textures/Texture";
import { DataTexture } from "../../textures/DataTexture";
import {
    CompressedTexture, CompressedMipmap, compressedFeature, compressedGPUFormat, blockWidth, blockHeight,
} from "../../textures/CompressedTexture";
import { TextureFormat } from "rive/gpu_enums";
import {
    RGB_S3TC_DXT1_Format, RGBA_S3TC_DXT1_Format, RGBA_S3TC_DXT3_Format, RGBA_S3TC_DXT5_Format, RGBA_BPTC_Format,
    RED_RGTC1_Format, SIGNED_RED_RGTC1_Format, RED_GREEN_RGTC2_Format, SIGNED_RED_GREEN_RGTC2_Format,
    RGB_ETC2_Format, RGB_ETC2_A1_Format, RGBA_ETC2_EAC_Format, R11_EAC_Format, SIGNED_R11_EAC_Format,
    RG11_EAC_Format, SIGNED_RG11_EAC_Format, RGBA_ASTC_4x4_Format, RGBAFormat,
    UnsignedByteType, HalfFloatType, SRGBColorSpace, NoColorSpace, LinearFilter, LinearMipmapLinearFilter,
} from "../../constants";

// VkFormat values KTX2 uses.
const VK_R8G8B8A8_UNORM = 37;
const VK_R8G8B8A8_SRGB = 43;
const VK_R16G16B16A16_SFLOAT = 97;
const VK_BC1_RGB_UNORM = 131;     // ... 132 its sRGB variant, and so on in pairs
const VK_BC1_RGBA_UNORM = 133;
const VK_BC2_UNORM = 135;
const VK_BC3_UNORM = 137;
const VK_BC4_UNORM = 139;          // 140 SNORM
const VK_BC5_UNORM = 141;          // 142 SNORM
const VK_BC7_UNORM = 145;
const VK_ETC2_R8G8B8_UNORM = 147;
const VK_ETC2_R8G8B8A1_UNORM = 149;
const VK_ETC2_R8G8B8A8_UNORM = 151;
const VK_EAC_R11_UNORM = 153;      // 154 SNORM
const VK_EAC_R11G11_UNORM = 155;   // 156 SNORM
const VK_ASTC_4x4_UNORM = 157;     // 157 to 184: 14 footprints, UNORM then SRGB
const VK_ASTC_12x12_SRGB = 184;

const MAGIC: StaticArray<u8> = [0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a];

/// What a KTX2 header describes (parseHeader), for tools and tests.
export class KTX2Header {
    vkFormat: u32 = 0;
    width: u32 = 0;
    height: u32 = 0;
    levelCount: u32 = 0;
    supercompressionScheme: u32 = 0;
    /// The three.js format (0 when not supported here) and colour space.
    format: i32 = 0;
    srgb: bool = false;
}

/// The compressed formats the device samples (three.js's
/// `KTX2Loader.workerConfig`; detectSupport fills it). A format whose flag
/// is false decodes on the CPU: clear one to force the fallback. Rive's
/// `bc` feature covers DXT (BC1, BC3) and BPTC (BC7), `etc2` covers ETC1
/// and ETC2. Until detectSupport, every flag is true and the texture asks
/// the device itself.
export class KTX2WorkerConfig {
    astcSupported: bool = true;
    etc1Supported: bool = true;
    etc2Supported: bool = true;
    dxtSupported: bool = true;
    bptcSupported: bool = true;
    pvrtcSupported: bool = false;
}

export class KTX2Loader {
    context: Context?;
    error: string = "";
    workerConfig: KTX2WorkerConfig = new KTX2WorkerConfig();

    constructor(context: Context? = null) {
        this.context = context;
    }

    /// Reads the device's texture compression support (three.js asks the
    /// renderer, as here).
    detectSupport(renderer: GPURenderer): KTX2Loader {
        const f = renderer.context.features();
        // `--arg threeCPUDecode` rules every format out (CompressedTexture's fallback).
        const all = renderer.context.arg("threeCPUDecode") == null;
        const c = this.workerConfig;
        c.astcSupported = all && f.astc;
        c.etc1Supported = all && f.etc2;
        c.etc2Supported = all && f.etc2;
        c.dxtSupported = all && f.bc;
        c.bptcSupported = all && f.bc;
        c.pvrtcSupported = false;
        return this;
    }

    /// Whether `workerConfig` lets the GPU sample `format` (a Rive GPU format
    /// exists for it and its flag is set).
    gpuSupports(format: i32): bool {
        if (compressedGPUFormat(format) == TextureFormat.rgba8unorm) return false;
        const c = this.workerConfig;
        const feature = compressedFeature(format);
        if (feature == "astc") return c.astcSupported;
        if (feature == "etc2") return c.etc2Supported;
        return format == RGBA_BPTC_Format ? c.bptcSupported : c.dxtSupported;
    }

    /// Basis transcoders are not used; kept for three.js code.
    setTranscoderPath(path: string): KTX2Loader { return this; }

    load(name: string): Texture? {
        const context = this.context;
        if (context == null) return null;
        const bytesAsset = context.blob(name);
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            context.log("three: KTX2Loader: no blob asset named '" + name + "'");
            return null;
        }
        const t = this.parse(Uint8Array.wrap(bytes));
        if (t == null) context.log("three: KTX2Loader: " + this.error);
        else t.name = name;
        return t;
    }

    parseHeader(b: Uint8Array): KTX2Header? {
        if (b.length < 80) return null;
        for (let i = 0; i < 12; i++) if (b[i] != MAGIC[i]) return null;
        const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
        const h = new KTX2Header();
        h.vkFormat = v.getUint32(12, true);
        h.width = v.getUint32(20, true);
        h.height = v.getUint32(24, true);
        h.levelCount = max<u32>(1, v.getUint32(40, true));
        h.supercompressionScheme = v.getUint32(44, true);
        const vk = <i32>h.vkFormat;
        if (vk == VK_R8G8B8A8_UNORM || vk == VK_R16G16B16A16_SFLOAT) h.format = RGBAFormat;
        else if (vk == VK_R8G8B8A8_SRGB) { h.format = RGBAFormat; h.srgb = true; }
        else if (vk >= VK_ASTC_4x4_UNORM && vk <= VK_ASTC_12x12_SRGB) {
            // Footprints in RGBA_ASTC_*_Format's order, an sRGB variant after each.
            h.format = RGBA_ASTC_4x4_Format + (vk - VK_ASTC_4x4_UNORM) / 2;
            h.srgb = ((vk - VK_ASTC_4x4_UNORM) & 1) == 1;
        } else if (vk >= VK_BC1_RGB_UNORM && vk <= VK_EAC_R11G11_UNORM + 1) {
            const pair = vk - ((vk - VK_BC1_RGB_UNORM) & 1);   // the UNORM of the pair
            const second = vk != pair;   // SRGB, or SNORM for BC4, BC5 and EAC
            const signed = second && (pair == VK_BC4_UNORM || pair == VK_BC5_UNORM || pair == VK_EAC_R11_UNORM
                || pair == VK_EAC_R11G11_UNORM);
            h.srgb = second && !signed;
            if (pair == VK_BC1_RGB_UNORM) h.format = RGB_S3TC_DXT1_Format;
            else if (pair == VK_BC1_RGBA_UNORM) h.format = RGBA_S3TC_DXT1_Format;
            else if (pair == VK_BC2_UNORM) h.format = RGBA_S3TC_DXT3_Format;
            else if (pair == VK_BC3_UNORM) h.format = RGBA_S3TC_DXT5_Format;
            else if (pair == VK_BC4_UNORM) h.format = signed ? SIGNED_RED_RGTC1_Format : RED_RGTC1_Format;
            else if (pair == VK_BC5_UNORM) h.format = signed ? SIGNED_RED_GREEN_RGTC2_Format : RED_GREEN_RGTC2_Format;
            else if (pair == VK_BC7_UNORM) h.format = RGBA_BPTC_Format;
            else if (pair == VK_ETC2_R8G8B8_UNORM) h.format = RGB_ETC2_Format;
            else if (pair == VK_ETC2_R8G8B8A1_UNORM) h.format = RGB_ETC2_A1_Format;
            else if (pair == VK_ETC2_R8G8B8A8_UNORM) h.format = RGBA_ETC2_EAC_Format;
            else if (pair == VK_EAC_R11_UNORM) h.format = signed ? SIGNED_R11_EAC_Format : R11_EAC_Format;
            else if (pair == VK_EAC_R11G11_UNORM) h.format = signed ? SIGNED_RG11_EAC_Format : RG11_EAC_Format;
            // BC6H (143, 144) stays 0: not supported.
        }
        return h;
    }

    parse(b: Uint8Array): Texture? {
        this.error = "";
        const h = this.parseHeader(b);
        if (h == null) {
            this.error = "not a KTX2 file";
            return null;
        }
        if (h.supercompressionScheme != 0) {
            this.error = "supercompressed KTX2 (Basis/Zstandard) is not supported";
            return null;
        }
        if (h.format == 0) {
            this.error = "VkFormat " + h.vkFormat.toString() + " is not supported";
            return null;
        }
        const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
        const levels: Array<Uint8Array> = [];
        for (let l: u32 = 0; l < h.levelCount; l++) {
            const o = 80 + <i32>l * 24;
            const offset = <i32>v.getUint64(o, true);
            const length = <i32>v.getUint64(o + 8, true);
            if (offset + length > b.length) {
                this.error = "truncated level " + l.toString();
                return null;
            }
            levels.push(b.subarray(offset, offset + length));
        }
        const colorSpace = h.srgb ? SRGBColorSpace : NoColorSpace;
        if (h.format == RGBAFormat) {
            const half = h.vkFormat == VK_R16G16B16A16_SFLOAT;
            const base = levels[0];
            const data: ArrayBufferView = half
                ? Uint16Array.wrap(base.buffer.slice(base.byteOffset, base.byteOffset + base.byteLength))
                : base.slice();
            const t = new DataTexture(data, h.width, h.height, RGBAFormat, half ? HalfFloatType : UnsignedByteType);
            t.colorSpace = colorSpace;
            t.flipY = false;
            t.magFilter = LinearFilter;
            t.minFilter = LinearMipmapLinearFilter;
            t.generateMipmaps = true;
            return t;
        }
        const mipmaps: Array<CompressedMipmap> = [];
        for (let l = 0; l < levels.length; l++) {
            mipmaps.push(new CompressedMipmap(levels[l], max<u32>(1, h.width >> <u32>l), max<u32>(1, h.height >> <u32>l)));
        }
        const t = new CompressedTexture(mipmaps, h.width, h.height, h.format);
        t.colorSpace = colorSpace;
        // Formats the device lacks decode on the CPU: a large texture starts
        // its job now, a small one decodes when first drawn.
        t.cpuDecode = !this.gpuSupports(h.format) || h.width % blockWidth(h.format) != 0
            || h.height % blockHeight(h.format) != 0;
        t.startDecode();
        return t;
    }
}
