// CPU decoding of compressed texture formats (ThreeAS addition: three.js
// has no CPU fallback for raw compressed formats; it transcodes Basis
// Universal instead). CompressedTexture uses it when the device cannot
// sample a format (no `bc`, `etc2` or `astc` feature, or a format Rive has
// no GPU format for), so a texture in any of these formats renders
// everywhere, uncompressed:
//
// - BC1 (RGB / RGBA with 1-bit alpha), BC2, BC3, BC4, BC5 (unsigned and
//   signed), BC7 (BCDecoder);
// - ETC1, ETC2 RGB8, RGB8A1, RGBA8, EAC R11 / RG11 (unsigned and signed)
//   (ETCDecoder);
// - ASTC LDR 2D, every footprint from 4x4 to 12x12 (ASTCDecoder).
//
// Unsigned formats decode to RGBA8; signed ones (BC4/BC5 and EAC SNORM) to
// RGBA half floats, to keep their [-1, 1] range. Not decoded: BC6H, ASTC
// HDR and 3D, PVRTC.
//
//     const rgba = decodeCompressed(RGBA_ASTC_6x6_Format, blocks, 256, 256, true);
//
// decodeCompressedJob does the same for a whole mip chain in a Rive job.

import {
    RGB_S3TC_DXT1_Format, RGBA_S3TC_DXT1_Format, RGBA_S3TC_DXT3_Format, RGBA_S3TC_DXT5_Format, RGBA_BPTC_Format,
    RED_RGTC1_Format, SIGNED_RED_RGTC1_Format, RED_GREEN_RGTC2_Format, SIGNED_RED_GREEN_RGTC2_Format,
    RGB_ETC1_Format, RGB_ETC2_Format, RGB_ETC2_A1_Format, RGBA_ETC2_EAC_Format, R11_EAC_Format,
    SIGNED_R11_EAC_Format, RG11_EAC_Format, SIGNED_RG11_EAC_Format,
    RGBA_ASTC_4x4_Format, RGBA_ASTC_5x4_Format, RGBA_ASTC_5x5_Format, RGBA_ASTC_6x5_Format, RGBA_ASTC_6x6_Format,
    RGBA_ASTC_8x5_Format, RGBA_ASTC_8x6_Format, RGBA_ASTC_8x8_Format, RGBA_ASTC_10x5_Format, RGBA_ASTC_10x6_Format,
    RGBA_ASTC_10x8_Format, RGBA_ASTC_10x10_Format, RGBA_ASTC_12x10_Format, RGBA_ASTC_12x12_Format,
} from "../../constants";
import { decodeBC1, decodeBC2, decodeBC3, decodeBC4BC5, decodeBC4BC5Signed, decodeBC7 } from "./BCDecoder";
import { decodeETC2, decodeETC2RGBA, decodeEAC, decodeEACSigned } from "./ETCDecoder";
import { decodeASTC } from "./ASTCDecoder";
import { toHalf } from "../DataUpload";

/// Whether `format` is an ASTC format.
export function isASTCFormat(format: i32): bool {
    return format >= RGBA_ASTC_4x4_Format && format <= RGBA_ASTC_12x12_Format;
}

/// Block width of a compressed format, in texels (4 for BC and ETC).
export function compressedBlockWidth(format: i32): i32 {
    if (format == RGBA_ASTC_4x4_Format) return 4;
    if (format == RGBA_ASTC_5x4_Format || format == RGBA_ASTC_5x5_Format) return 5;
    if (format == RGBA_ASTC_6x5_Format || format == RGBA_ASTC_6x6_Format) return 6;
    if (format >= RGBA_ASTC_8x5_Format && format <= RGBA_ASTC_8x8_Format) return 8;
    if (format >= RGBA_ASTC_10x5_Format && format <= RGBA_ASTC_10x10_Format) return 10;
    if (format == RGBA_ASTC_12x10_Format || format == RGBA_ASTC_12x12_Format) return 12;
    return 4;
}

/// Block height of a compressed format, in texels.
export function compressedBlockHeight(format: i32): i32 {
    if (format == RGBA_ASTC_5x5_Format || format == RGBA_ASTC_6x5_Format || format == RGBA_ASTC_8x5_Format
            || format == RGBA_ASTC_10x5_Format) return 5;
    if (format == RGBA_ASTC_6x6_Format || format == RGBA_ASTC_8x6_Format || format == RGBA_ASTC_10x6_Format) return 6;
    if (format == RGBA_ASTC_8x8_Format || format == RGBA_ASTC_10x8_Format) return 8;
    if (format == RGBA_ASTC_10x10_Format || format == RGBA_ASTC_12x10_Format) return 10;
    if (format == RGBA_ASTC_12x12_Format) return 12;
    return 4;
}

/// Bytes a block of a compressed format takes (8 or 16).
export function compressedBlockBytes(format: i32): i32 {
    if (format == RGB_S3TC_DXT1_Format || format == RGBA_S3TC_DXT1_Format || format == RED_RGTC1_Format
            || format == SIGNED_RED_RGTC1_Format || format == RGB_ETC1_Format || format == RGB_ETC2_Format
            || format == RGB_ETC2_A1_Format || format == R11_EAC_Format || format == SIGNED_R11_EAC_Format) return 8;
    return 16;
}

/// Whether decodeCompressed reads `format`.
export function canDecodeCompressed(format: i32): bool {
    return isASTCFormat(format) || format == RGB_S3TC_DXT1_Format || format == RGBA_S3TC_DXT1_Format
        || format == RGBA_S3TC_DXT3_Format || format == RGBA_S3TC_DXT5_Format || format == RGBA_BPTC_Format
        || format == RED_RGTC1_Format || format == SIGNED_RED_RGTC1_Format || format == RED_GREEN_RGTC2_Format
        || format == SIGNED_RED_GREEN_RGTC2_Format || format == RGB_ETC1_Format || format == RGB_ETC2_Format
        || format == RGB_ETC2_A1_Format || format == RGBA_ETC2_EAC_Format || format == R11_EAC_Format
        || format == SIGNED_R11_EAC_Format || format == RG11_EAC_Format || format == SIGNED_RG11_EAC_Format;
}

/// Whether `format` decodes to RGBA half floats (the signed formats)
/// rather than RGBA8.
export function decodesToHalfFloat(format: i32): bool {
    return format == SIGNED_RED_RGTC1_Format || format == SIGNED_RED_GREEN_RGTC2_Format
        || format == SIGNED_R11_EAC_Format || format == SIGNED_RG11_EAC_Format;
}

/// Bytes of compressed data a `width` x `height` level of `format` holds.
export function compressedLevelBytes(format: i32, width: i32, height: i32): i32 {
    const bw = compressedBlockWidth(format), bh = compressedBlockHeight(format);
    return ((width + bw - 1) / bw) * ((height + bh - 1) / bh) * compressedBlockBytes(format);
}

/// Decodes one level of `format` (blocks in rows, top first) to RGBA:
/// width * height * 4 bytes of RGBA8, or, for decodesToHalfFloat formats,
/// width * height * 8 bytes of RGBA half floats. `srgb` selects ASTC's sRGB
/// decode (the texture's colour space; the other formats decode the same
/// either way, the shader converts). Data shorter than the level decodes as
/// zero blocks. Null for a format it cannot read.
export function decodeCompressed(format: i32, data: Uint8Array, width: i32, height: i32, srgb: bool): Uint8Array? {
    if (!canDecodeCompressed(format) || width <= 0 || height <= 0) return null;
    const need = compressedLevelBytes(format, width, height);
    let blocks = data;
    if (data.length < need) {
        blocks = new Uint8Array(need);
        blocks.set(data);
    }
    if (decodesToHalfFloat(format)) {
        const f = new Float32Array(width * height * 4);
        if (format == SIGNED_RED_RGTC1_Format) decodeBC4BC5Signed(blocks, width, height, f, 1);
        else if (format == SIGNED_RED_GREEN_RGTC2_Format) decodeBC4BC5Signed(blocks, width, height, f, 2);
        else if (format == SIGNED_R11_EAC_Format) decodeEACSigned(blocks, width, height, f, 1);
        else decodeEACSigned(blocks, width, height, f, 2);
        const h = new Uint16Array(f.length);
        for (let i = 0; i < f.length; i++) h[i] = toHalf(f[i]);
        return Uint8Array.wrap(h.buffer);
    }
    const out = new Uint8Array(width * height * 4);
    if (isASTCFormat(format)) {
        decodeASTC(blocks, width, height, compressedBlockWidth(format), compressedBlockHeight(format), srgb, out);
    } else if (format == RGB_S3TC_DXT1_Format) decodeBC1(blocks, width, height, out, false);
    else if (format == RGBA_S3TC_DXT1_Format) decodeBC1(blocks, width, height, out, true);
    else if (format == RGBA_S3TC_DXT3_Format) decodeBC2(blocks, width, height, out);
    else if (format == RGBA_S3TC_DXT5_Format) decodeBC3(blocks, width, height, out);
    else if (format == RGBA_BPTC_Format) decodeBC7(blocks, width, height, out);
    else if (format == RED_RGTC1_Format) decodeBC4BC5(blocks, width, height, out, 1);
    else if (format == RED_GREEN_RGTC2_Format) decodeBC4BC5(blocks, width, height, out, 2);
    else if (format == RGB_ETC1_Format || format == RGB_ETC2_Format) decodeETC2(blocks, width, height, out, false);
    else if (format == RGB_ETC2_A1_Format) decodeETC2(blocks, width, height, out, true);
    else if (format == RGBA_ETC2_EAC_Format) decodeETC2RGBA(blocks, width, height, out);
    else if (format == R11_EAC_Format) decodeEAC(blocks, width, height, out, 1);
    else decodeEAC(blocks, width, height, out, 2);
    return out;
}

/// What decodeCompressedJob hands back: one RGBA buffer per mip level.
export class DecodedLevels {
    error: string = "";
    levels: Array<Uint8Array> = [];
}

/// The job behind CompressedTexture's CPU fallback for large textures:
/// decodes the levels of `data` (level i at offsets[i], widths[i] x
/// heights[i] texels) as decodeCompressed does, off the main lane.
@job export function decodeCompressedJob(format: i32, srgb: bool, data: ArrayBuffer, offsets: Int32Array,
                                         widths: Int32Array, heights: Int32Array): DecodedLevels {
    const result = new DecodedLevels();
    const bytes = Uint8Array.wrap(data);
    const n = offsets.length;
    for (let i = 0; i < n; i++) {
        const end = i + 1 < n ? offsets[i + 1] : bytes.length;
        const level = decodeCompressed(format, bytes.subarray(offsets[i], max<i32>(offsets[i], end)), widths[i],
            heights[i], srgb);
        if (level == null) {
            result.error = "format " + format.toString() + " cannot be decoded";
            result.levels = [];
            return result;
        }
        result.levels.push(level!);
    }
    return result;
}
