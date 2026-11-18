// three.js examples/jsm/loaders/KTX2Loader.js, for KTX2 files whose texels
// the GPU samples directly: BC1/BC3/BC7, ETC2 and ASTC (4x4, 6x6, 8x8)
// as CompressedTextures, and uncompressed RGBA8 / RGBA16F as
// DataTextures. Basis Universal (BasisLZ, UASTC transcoding) and Zstandard
// supercompression are not supported. `detectSupport(renderer)` reads the
// device's compression features; a format the device lacks fails with a
// log line (three.js would transcode Basis to one it has).
//
//     const t = new KTX2Loader(context).detectSupport(renderer).load("crate");   // crate.ktx2

import { Context } from "rive/host";
import { GPURenderer } from "../../renderers/GPURenderer";
import { Texture } from "../../textures/Texture";
import { DataTexture } from "../../textures/DataTexture";
import { CompressedTexture, CompressedMipmap, compressedFeature } from "../../textures/CompressedTexture";
import {
    RGB_S3TC_DXT1_Format, RGBA_S3TC_DXT1_Format, RGBA_S3TC_DXT5_Format, RGBA_BPTC_Format, RGB_ETC2_Format,
    RGBA_ETC2_EAC_Format, RGBA_ASTC_4x4_Format, RGBA_ASTC_6x6_Format, RGBA_ASTC_8x8_Format, RGBAFormat,
    UnsignedByteType, HalfFloatType, SRGBColorSpace, NoColorSpace, LinearFilter, LinearMipmapLinearFilter,
} from "../../constants";

// VkFormat values KTX2 uses.
const VK_R8G8B8A8_UNORM = 37;
const VK_R8G8B8A8_SRGB = 43;
const VK_R16G16B16A16_SFLOAT = 97;
const VK_BC1_RGB_UNORM = 131;
const VK_BC1_RGB_SRGB = 132;
const VK_BC1_RGBA_UNORM = 133;
const VK_BC1_RGBA_SRGB = 134;
const VK_BC3_UNORM = 137;
const VK_BC3_SRGB = 138;
const VK_BC7_UNORM = 145;
const VK_BC7_SRGB = 146;
const VK_ETC2_RGB_UNORM = 147;
const VK_ETC2_RGB_SRGB = 148;
const VK_ETC2_RGBA_UNORM = 151;
const VK_ETC2_RGBA_SRGB = 152;
const VK_ASTC_4x4_UNORM = 157;
const VK_ASTC_4x4_SRGB = 158;
const VK_ASTC_6x6_UNORM = 165;
const VK_ASTC_6x6_SRGB = 166;
const VK_ASTC_8x8_UNORM = 171;
const VK_ASTC_8x8_SRGB = 172;

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

export class KTX2Loader {
    context: Context?;
    error: string = "";
    private bc: bool = true;
    private etc2: bool = true;
    private astc: bool = true;

    constructor(context: Context? = null) {
        this.context = context;
    }

    /// Reads the device's texture compression support (three.js asks the
    /// renderer, as here).
    detectSupport(renderer: GPURenderer): KTX2Loader {
        const f = renderer.context.features();
        this.bc = f.bc;
        this.etc2 = f.etc2;
        this.astc = f.astc;
        return this;
    }

    /// Basis transcoders are not used; kept for three.js code.
    setTranscoderPath(path: string): KTX2Loader { return this; }

    load(name: string): Texture? {
        const context = this.context;
        if (context == null) return null;
        const bytes = context.blob(name);
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
        const vk = h.vkFormat;
        h.srgb = vk == VK_R8G8B8A8_SRGB || vk == VK_BC1_RGB_SRGB || vk == VK_BC1_RGBA_SRGB || vk == VK_BC3_SRGB
            || vk == VK_BC7_SRGB || vk == VK_ETC2_RGB_SRGB || vk == VK_ETC2_RGBA_SRGB || vk == VK_ASTC_4x4_SRGB
            || vk == VK_ASTC_6x6_SRGB || vk == VK_ASTC_8x8_SRGB;
        if (vk == VK_BC1_RGB_UNORM || vk == VK_BC1_RGB_SRGB) h.format = RGB_S3TC_DXT1_Format;
        else if (vk == VK_BC1_RGBA_UNORM || vk == VK_BC1_RGBA_SRGB) h.format = RGBA_S3TC_DXT1_Format;
        else if (vk == VK_BC3_UNORM || vk == VK_BC3_SRGB) h.format = RGBA_S3TC_DXT5_Format;
        else if (vk == VK_BC7_UNORM || vk == VK_BC7_SRGB) h.format = RGBA_BPTC_Format;
        else if (vk == VK_ETC2_RGB_UNORM || vk == VK_ETC2_RGB_SRGB) h.format = RGB_ETC2_Format;
        else if (vk == VK_ETC2_RGBA_UNORM || vk == VK_ETC2_RGBA_SRGB) h.format = RGBA_ETC2_EAC_Format;
        else if (vk == VK_ASTC_4x4_UNORM || vk == VK_ASTC_4x4_SRGB) h.format = RGBA_ASTC_4x4_Format;
        else if (vk == VK_ASTC_6x6_UNORM || vk == VK_ASTC_6x6_SRGB) h.format = RGBA_ASTC_6x6_Format;
        else if (vk == VK_ASTC_8x8_UNORM || vk == VK_ASTC_8x8_SRGB) h.format = RGBA_ASTC_8x8_Format;
        else if (vk == VK_R8G8B8A8_UNORM || vk == VK_R8G8B8A8_SRGB || vk == VK_R16G16B16A16_SFLOAT) h.format = RGBAFormat;
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
        const feature = compressedFeature(h.format);
        if ((feature == "bc" && !this.bc) || (feature == "etc2" && !this.etc2) || (feature == "astc" && !this.astc)) {
            this.error = "this device has no " + feature + " texture compression";
            return null;
        }
        const mipmaps: Array<CompressedMipmap> = [];
        for (let l = 0; l < levels.length; l++) {
            mipmaps.push(new CompressedMipmap(levels[l], max<u32>(1, h.width >> <u32>l), max<u32>(1, h.height >> <u32>l)));
        }
        const t = new CompressedTexture(mipmaps, h.width, h.height, h.format);
        t.colorSpace = colorSpace;
        return t;
    }
}
