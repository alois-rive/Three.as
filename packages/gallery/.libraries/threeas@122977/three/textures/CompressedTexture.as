// three.js CompressedTexture: block-compressed texels with their own mip
// levels (`mipmaps`, level 0 first). The GPU samples the blocks as they are
// when it can: S3TC/DXT1 and DXT5 (BC1, BC3), BPTC (BC7), ETC2 (RGB, RGBA)
// and ASTC 4x4, 6x6, 8x8 with the matching device feature (`bc`, `etc2`,
// `astc`) and a size that is a multiple of the block size. Otherwise
// (ThreeAS addition) the levels are decoded on the CPU
// (textures/decoders/TextureDecoders: every BC, ETC/EAC and ASTC LDR
// format) and uploaded uncompressed, RGBA8 (signed formats as half floats),
// in the same colour space: on the main lane for small textures, in a Rive
// job for large ones (the texture samples nothing until the job is done).
// `cpuDecode` forces it; so does running with `--arg threeCPUDecode`.
// Rows are top first, so flipY is false, as three.js.
//
// Mipmaps in RGBAFormat (UnsignedByteType, or HalfFloatType as 8 bytes a
// texel) upload as they are, as three.js's KTX2Loader output transcoded to
// RGBA32.

import { Context } from "rive/host";
import { GPUTexture, GPUTextureDesc, GPUTextureView } from "rive/gpu";
import { TextureFormat } from "rive/gpu_enums";
import { rive_gpu_texture_upload_v1 } from "rive/bindings";
import { Job, Jobs } from "rive/jobs";
import { clock } from "rive/os";
import { Texture } from "./Texture";
import {
    RGB_S3TC_DXT1_Format, RGBA_S3TC_DXT1_Format, RGBA_S3TC_DXT5_Format, RGBA_BPTC_Format, RGB_ETC2_Format,
    RGBA_ETC2_EAC_Format, RGBA_ASTC_4x4_Format, RGBA_ASTC_6x6_Format, RGBA_ASTC_8x8_Format, UnsignedByteType,
    HalfFloatType, RGBAFormat, LinearFilter, LinearMipmapLinearFilter, SRGBColorSpace, RGB_ETC1_Format,
    RGB_ETC2_A1_Format, R11_EAC_Format, SIGNED_RG11_EAC_Format,
} from "../constants";
import {
    compressedBlockWidth, compressedBlockHeight, compressedBlockBytes, isASTCFormat, decodeCompressed,
    decodesToHalfFloat, decodeCompressedJob, DecodedLevels,
} from "./decoders/TextureDecoders";

const uploadRegion = new rive_gpu_texture_upload_v1();

/// Textures of at most this many texels (all levels: a 128 x 128 chain)
/// decode on the main lane, in the frame that first draws them; larger ones
/// decode in a job. ASTC 4x4 decodes about 4 to 5 million texels a second
/// on the interpreted tier of an M-series Mac, 15 to 20 times that compiled
/// (docs/DEVIATIONS.md, "Textures").
export const CPU_DECODE_SYNC_TEXELS: i32 = 128 * 128 * 4 / 3 + 1;

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

/// The GPU format of a compressed three.js format, or rgba8unorm when Rive
/// has none for it (the texture then decodes on the CPU).
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
export function blockWidth(format: i32): u32 { return <u32>compressedBlockWidth(format); }
export function blockHeight(format: i32): u32 { return <u32>compressedBlockHeight(format); }
export function blockBytes(format: i32): u32 { return <u32>compressedBlockBytes(format); }

/// The device feature a compressed format needs: "bc", "etc2" or "astc"
/// ("" for RGBAFormat).
export function compressedFeature(format: i32): string {
    if (format == RGBAFormat) return "";
    if (format == RGB_ETC2_Format || format == RGBA_ETC2_EAC_Format) return "etc2";
    if (isASTCFormat(format)) return "astc";
    if (format == RGB_ETC1_Format || format == RGB_ETC2_A1_Format || (format >= R11_EAC_Format
            && format <= SIGNED_RG11_EAC_Format)) return "etc2";
    return "bc";
}

/// Whether the GPU behind `context` samples `format` as it is (a Rive GPU
/// format exists and the device has its feature); false when
/// `--arg threeCPUDecode` is given.
export function gpuSamplesCompressed(context: Context, format: i32): bool {
    if (compressedGPUFormat(format) == TextureFormat.rgba8unorm) return false;
    if (context.arg("threeCPUDecode") != null) return false;
    const f = context.features();
    const feature = compressedFeature(format);
    return feature == "bc" ? f.bc : feature == "etc2" ? f.etc2 : f.astc;
}

export class CompressedTexture extends Texture {
    readonly isCompressedTexture: bool = true;
    mipmaps: Array<CompressedMipmap>;
    dataWidth: u32;
    dataHeight: u32;
    /// Decode on the CPU even when the device could sample the format
    /// (ThreeAS; KTX2Loader sets it for formats its `workerConfig` rules
    /// out). The decoded texture keeps `format`, `colorSpace` and the mip
    /// levels.
    cpuDecode: bool = false;

    private gpuTexture: GPUTexture? = null;
    private gpuView: GPUTextureView? = null;
    private uploadedVersion: i32 = -1;
    private halfFloat: bool = false;
    private decodedOnCPU: bool = false;
    private job: Job<DecodedLevels>? = null;
    private jobVersion: i32 = -1;
    private jobStart: f64 = 0;

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
    override get isHDRSource(): bool { return this.halfFloat; }

    /// Whether the last upload decoded the blocks on the CPU (ThreeAS; false
    /// before the first upload).
    get isDecodedOnCPU(): bool { return this.decodedOnCPU; }

    /// The mip levels decoded on the CPU, as three.js's RGBAFormat mipmaps:
    /// RGBA8 texels (rows top first), or RGBA half floats (8 bytes a texel)
    /// for the signed formats. Empty for a format that cannot be decoded.
    /// ThreeAS; the renderer calls it when the device cannot sample the
    /// format.
    decompress(): Array<CompressedMipmap> {
        const out: Array<CompressedMipmap> = [];
        if (this.format == RGBAFormat) {
            for (let l = 0; l < this.mipmaps.length; l++) out.push(this.mipmaps[l]);
            return out;
        }
        const srgb = this.colorSpace == SRGBColorSpace;
        for (let l = 0; l < this.mipmaps.length; l++) {
            const m = this.mipmaps[l];
            const rgba = decodeCompressed(this.format, m.data, <i32>m.width, <i32>m.height, srgb);
            if (rgba == null) return [];
            out.push(new CompressedMipmap(rgba!, m.width, m.height));
        }
        return out;
    }

    /// Starts decoding on the CPU now rather than at the first draw
    /// (ThreeAS): a texture over CPU_DECODE_SYNC_TEXELS starts its job, so
    /// it decodes while the scene loads; smaller ones decode at their first
    /// draw anyway. KTX2Loader calls it for the textures it marks
    /// `cpuDecode`. Does nothing unless `cpuDecode` is set.
    startDecode(): void {
        if (!this.cpuDecode || this.format == RGBAFormat || this.mipmaps.length == 0) return;
        if (this.uploadedVersion == this.version || (this.job != null && this.jobVersion == this.version)) return;
        if (this.texelCount() > CPU_DECODE_SYNC_TEXELS) this.startJob();
    }

    private texelCount(): i32 {
        let texels = 0;
        for (let l = 0; l < this.mipmaps.length; l++) texels += <i32>(this.mipmaps[l].width * this.mipmaps[l].height);
        return texels;
    }

    override update(context: Context): void {
        if (this.mipmaps.length == 0) return;
        if (this.job != null) this.pollJob(context);
        if (this.uploadedVersion == this.version) return;
        if (this.format == RGBAFormat) {
            this.uploadLevels(this.mipmaps, this.type == HalfFloatType);
            return;
        }
        if (!this.cpuDecode && gpuSamplesCompressed(context, this.format)
                && this.dataWidth % blockWidth(this.format) == 0 && this.dataHeight % blockHeight(this.format) == 0) {
            this.uploadBlocks();
            return;
        }
        if (this.job != null && this.jobVersion == this.version) return;   // still decoding
        if (this.texelCount() > CPU_DECODE_SYNC_TEXELS) {
            this.startJob();
            return;
        }
        const start = clock();
        const levels = this.decompress();
        if (levels.length == 0) {
            context.log("three: CompressedTexture: format " + this.format.toString() + " cannot be decoded");
            this.uploadedVersion = this.version;
            return;
        }
        this.uploadLevels(levels, decodesToHalfFloat(this.format));
        this.logDecode(context, "", clock() - start);
    }

    private logDecode(context: Context, how: string, seconds: f64): void {
        context.log("three: CompressedTexture" + (this.name.length > 0 ? " '" + this.name + "'" : "") + ": format "
            + this.format.toString() + " decoded on the CPU" + how + " (" + this.dataWidth.toString() + "x"
            + this.dataHeight.toString() + ", " + this.mipmaps.length.toString()
            + (this.mipmaps.length == 1 ? " level, " : " levels, ")
            + (Math.round(seconds * 10000) / 10).toString() + " ms)");
    }

    private startJob(): void {
        const n = this.mipmaps.length;
        let total = 0;
        for (let l = 0; l < n; l++) total += this.mipmaps[l].data.length;
        const data = new Uint8Array(total);
        const offsets = new Int32Array(n), widths = new Int32Array(n), heights = new Int32Array(n);
        let o = 0;
        for (let l = 0; l < n; l++) {
            const m = this.mipmaps[l];
            offsets[l] = o;
            widths[l] = <i32>m.width;
            heights[l] = <i32>m.height;
            data.set(m.data, o);
            o += m.data.length;
        }
        const old = this.job;
        if (old != null) old.release();
        this.job = Jobs.run(decodeCompressedJob, this.format, this.colorSpace == SRGBColorSpace, data.buffer, offsets,
            widths, heights);
        this.jobVersion = this.version;
        this.jobStart = clock();
    }

    private pollJob(context: Context): void {
        const job = this.job!;
        if (job.running) return;
        const settled = job.peek();
        this.job = null;
        if (this.jobVersion != this.version) {   // the texture changed meanwhile: decode again
            job.release();
            return;
        }
        if (settled == null || !settled.ok || settled.value.error.length > 0) {
            const why = settled == null ? "stopped" : !settled.ok ? settled.error : settled.value.error;
            context.log("three: CompressedTexture: decoding failed: " + why);
            this.uploadedVersion = this.version;
            job.release();
            return;
        }
        const d = settled.value;
        const levels: Array<CompressedMipmap> = [];
        for (let l = 0; l < this.mipmaps.length; l++) {
            const end = l + 1 < d.offsets.length ? d.offsets[l + 1] : d.data.length;
            levels.push(new CompressedMipmap(d.data.subarray(d.offsets[l], end), this.mipmaps[l].width,
                this.mipmaps[l].height));
        }
        this.uploadLevels(levels, decodesToHalfFloat(this.format));
        job.release();
        this.logDecode(context, " in a job", clock() - this.jobStart);
    }

    /// The blocks as they are, in the device's compressed format.
    private uploadBlocks(): void {
        const format = compressedGPUFormat(this.format);
        const tex = this.ensureTexture(format);
        const bw = blockWidth(this.format), bh = blockHeight(this.format), bb = blockBytes(this.format);
        for (let l = 0; l < this.mipmaps.length; l++) {
            const m = this.mipmaps[l];
            const blocksX = (m.width + bw - 1) / bw, blocksY = (m.height + bh - 1) / bh;
            uploadRegion.mipLevel = <u32>l;
            uploadRegion.width = blocksX * bw;   // the level's physical size
            uploadRegion.height = blocksY * bh;
            uploadRegion.bytesPerRow = blocksX * bb;   // a row of blocks
            uploadRegion.rowsPerImage = 0;
            // Rive checks the data against bytesPerRow x texel rows: pad.
            const d = m.data;
            const padded = new Uint8Array(<i32>(blocksX * bb * blocksY * bh));
            padded.set(d.subarray(0, min<i32>(d.length, padded.length)));
            tex.upload(uploadRegion, padded.buffer);
        }
        this.finishUpload(false, false);
    }

    /// Uncompressed levels: RGBA8, or RGBA half floats.
    private uploadLevels(levels: Array<CompressedMipmap>, half: bool): void {
        const tex = this.ensureTexture(half ? TextureFormat.rgba16float : TextureFormat.rgba8unorm);
        const texelBytes = half ? 8 : 4;
        for (let l = 0; l < levels.length; l++) {
            const m = levels[l];
            const need = <i32>(m.width * m.height) * texelBytes;
            let d = m.data;
            if (d.length != need || d.byteOffset != 0 || d.buffer.byteLength != need) {
                const copy = new Uint8Array(need);
                copy.set(d.subarray(0, min<i32>(d.length, need)));
                d = copy;
            }
            uploadRegion.mipLevel = <u32>l;
            uploadRegion.width = m.width;
            uploadRegion.height = m.height;
            uploadRegion.bytesPerRow = 0;
            uploadRegion.rowsPerImage = 0;
            tex.upload(uploadRegion, d.buffer);
        }
        this.finishUpload(this.format != RGBAFormat, half);
    }

    private ensureTexture(format: TextureFormat): GPUTexture {
        let tex = this.gpuTexture;
        if (tex == null || tex.width != this.dataWidth || tex.height != this.dataHeight || tex.format != format
                || tex.numMipmaps != <u32>this.mipmaps.length) {
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
        return tex!;
    }

    private finishUpload(cpu: bool, half: bool): void {
        uploadRegion.mipLevel = 0;
        uploadRegion.bytesPerRow = 0;
        uploadRegion.rowsPerImage = 0;
        this.decodedOnCPU = cpu;
        this.halfFloat = half;
        this.uploadedVersion = this.version;
    }

    override getView(): GPUTextureView? { return this.gpuView; }

    override dispose(): void {
        const tex = this.gpuTexture;
        if (tex != null) tex.release();
        const job = this.job;
        if (job != null) job.release();
        this.job = null;
        this.gpuTexture = null;
        this.gpuView = null;
        this.uploadedVersion = -1;
        super.dispose();
    }
}
