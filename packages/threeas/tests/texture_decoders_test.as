// The CPU decoders of compressed textures (three/textures/decoders/):
// rive . --test
//
// "GPU reference vectors" decodes tests/fixtures/texture_vectors.bin.zlib,
// blocks of every format with the texels Apple silicon's GPU decoder
// produced for them (tools/make_texture_vectors.py). The other groups
// decode hand-made blocks whose texels follow from the format
// specifications; each test says how.

import { Tests } from "rive/test";
import { unzlibSync } from "../three/addons/libs/fflate";
import { decodeCompressed, decodesToHalfFloat, compressedBlockWidth, compressedBlockHeight } from "../three/textures/decoders/TextureDecoders";
import { fromHalf } from "../three/textures/DataUpload";
import {
    RGB_S3TC_DXT1_Format, RGBA_S3TC_DXT1_Format, RGBA_S3TC_DXT3_Format, RGBA_S3TC_DXT5_Format, RGBA_BPTC_Format,
    RED_RGTC1_Format, SIGNED_RED_RGTC1_Format, RED_GREEN_RGTC2_Format, RGB_ETC1_Format, RGB_ETC2_Format,
    RGB_ETC2_A1_Format, RGBA_ETC2_EAC_Format, R11_EAC_Format, SIGNED_R11_EAC_Format, RGBA_ASTC_4x4_Format,
    RGBA_ASTC_5x5_Format, RGBA_ASTC_6x5_Format, RGBA_ASTC_10x8_Format, RGBA_ASTC_12x12_Format,
} from "../three/constants";

/// Compares every record of the vectors file; "" when all match, else what
/// differs.
function checkVectors(file: Uint8Array): string {
    const v = new DataView(file.buffer, file.byteOffset, file.byteLength);
    if (file.length < 8 || file[0] != 0x54 || file[1] != 0x58 || file[2] != 0x56 || file[3] != 0x31) return "bad file";
    const count = <i32>v.getUint32(4, true);
    let o = 8;
    let report = "";
    for (let r = 0; r < count; r++) {
        const format = v.getInt32(o, true);
        const srgb = file[o + 4] != 0;
        const bw = <i32>file[o + 5], bh = <i32>file[o + 6], bb = <i32>file[o + 7];
        const tol = <i32>file[o + 8], kind = <i32>file[o + 9];
        const n = <i32>v.getUint16(o + 10, true);
        o += 12;
        const blocks = file.subarray(o, o + n * bb);
        o += n * bb;
        const texels = n * bw * bh;
        if (compressedBlockWidth(format) != bw || compressedBlockHeight(format) != bh) {
            report += "format " + format.toString() + ": block size " + compressedBlockWidth(format).toString() + "; ";
        }
        // The blocks side by side: one row of n blocks.
        const out = decodeCompressed(format, blocks, n * bw, bh, srgb);
        if (out == null) {
            report += "format " + format.toString() + " not decoded; ";
            o += texels * 4 * (kind == 1 ? 2 : 1);
            continue;
        }
        const half = decodesToHalfFloat(format);
        const halves = half ? Uint16Array.wrap(out!.buffer) : new Uint16Array(0);
        let bad = 0;
        let first = "";
        for (let b = 0; b < n; b++) {
            for (let y = 0; y < bh; y++) {
                for (let x = 0; x < bw; x++) {
                    const t = (b * bh + y) * bw + x;
                    const g = (y * n * bw + b * bw + x) * 4;
                    for (let c = 0; c < 4; c++) {
                        let diff: f64;
                        let got: f64, want: f64;
                        if (kind == 1) {
                            want = <f64>v.getInt16(o + (t * 4 + c) * 2, true) / 16384;
                            got = half ? <f64>fromHalf(halves[g + c]) : <f64>out![g + c] / 255;
                            diff = Math.abs(got - want) * 255;
                        } else {
                            want = <f64>file[o + t * 4 + c];
                            got = <f64>out![g + c];
                            diff = Math.abs(got - want);
                        }
                        if (diff > <f64>tol + 1e-3) {
                            if (bad == 0) {
                                first = "block " + b.toString() + " texel " + x.toString() + "," + y.toString()
                                    + " channel " + c.toString() + ": " + got.toString() + " != " + want.toString();
                            }
                            bad++;
                        }
                    }
                }
            }
        }
        o += texels * 4 * (kind == 1 ? 2 : 1);
        if (bad > 0) {
            report += "format " + format.toString() + (srgb ? " sRGB" : "") + ": " + bad.toString()
                + " channels differ (" + first + "); ";
        }
    }
    return report;
}

/// "r,g,b,a" of texel (x, y) of an RGBA8 image `width` wide.
function px(out: Uint8Array?, width: i32, x: i32, y: i32): string {
    if (out == null) return "null";
    const o = (y * width + x) * 4;
    return out![o].toString() + "," + out![o + 1].toString() + "," + out![o + 2].toString() + "," + out![o + 3].toString();
}

/// Channel c of texel (x, y) of a half-float RGBA image, as a float.
function pxf(out: Uint8Array?, width: i32, x: i32, y: i32, c: i32): f64 {
    if (out == null) return NaN;
    return <f64>fromHalf(Uint16Array.wrap(out!.buffer)[(y * width + x) * 4 + c]);
}

function bytes(a: StaticArray<u8>): Uint8Array {
    const out = new Uint8Array(a.length);
    for (let i = 0; i < a.length; i++) out[i] = a[i];
    return out;
}

/// Writes `n` bits of `value` at bit `pos` of a little-endian block.
function put(b: Uint8Array, pos: i32, n: i32, value: i32): void {
    for (let i = 0; i < n; i++) {
        const bit = (value >> i) & 1;
        if (bit != 0) b[(pos + i) >> 3] |= <u8>(1 << ((pos + i) & 7));
    }
}

/// An ETC / EAC block from its two 32-bit big-endian words.
function etc(hi: u32, lo: u32): Uint8Array {
    const b = new Uint8Array(8);
    for (let i = 0; i < 4; i++) {
        b[i] = <u8>(hi >> <u32>(24 - 8 * i));
        b[4 + i] = <u8>(lo >> <u32>(24 - 8 * i));
    }
    return b;
}

/// ETC pixel index bits where texel (x, y) (index x * 4 + y) gets y: the
/// rows take indices 0, 1, 2, 3.
function rowIndices(): u32 {
    let lo: u32 = 0;
    for (let i = 0; i < 16; i++) {
        const y = <u32>(i & 3);
        lo |= ((y >> 1) << <u32>(16 + i)) | ((y & 1) << <u32>i);
    }
    return lo;
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length);
    out.set(a);
    out.set(b, a.length);
    return out;
}

/// ASTC blocks laid out by tools/astc_encode.py's pack_block (the
/// parameters are in each test), checked by hand against the
/// specification below and by Apple's GPU decoder.
const ASTC_CEM0: StaticArray<u8> = [0x42, 0x00, 0x50, 0x90, 0x01, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0x00, 0x00];
const ASTC_CEM1: StaticArray<u8> = [0x42, 0x20, 0xaa, 0x8e, 0x01, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0x00, 0x00];
const ASTC_CEM4: StaticArray<u8> = [0x42, 0x80, 0x14, 0xf4, 0x3d, 0xb8, 0x01, 0, 0, 0, 0, 0, 0xff, 0xff, 0x00, 0x00];
const ASTC_CEM5: StaticArray<u8> = [0x42, 0xa0, 0xc8, 0x28, 0x90, 0xf5, 0x01, 0, 0, 0, 0, 0, 0xff, 0xff, 0x00, 0x00];
const ASTC_CEM6: StaticArray<u8> = [0x42, 0xc0, 0x90, 0xc9, 0x64, 0x00, 0x01, 0, 0, 0, 0, 0, 0xff, 0xff, 0x00, 0x00];
const ASTC_CEM8: StaticArray<u8> = [0x42, 0x00, 0x15, 0x90, 0x29, 0xa4, 0x3d, 0xb8, 0x01, 0, 0, 0, 0xff, 0xff, 0x00, 0x00];
const ASTC_CEM8_BLUE: StaticArray<u8> = [0x42, 0x00, 0x91, 0x15, 0xa4, 0x29, 0xb8, 0x3d, 0, 0, 0, 0, 0xff, 0xff, 0x00, 0x00];
const ASTC_CEM9: StaticArray<u8> = [0x42, 0x20, 0x79, 0x20, 0xa0, 0x10, 0xc9, 0xfc, 0, 0, 0, 0, 0xff, 0xff, 0x00, 0x00];
const ASTC_CEM10: StaticArray<u8> = [0x42, 0x40, 0x91, 0xc9, 0x64, 0x00, 0x15, 0xe0, 0x01, 0, 0, 0, 0xff, 0xff, 0x00, 0x00];
const ASTC_CEM12: StaticArray<u8> = [0x42, 0x80, 0x15, 0x90, 0x29, 0xa4, 0x3d, 0xb8, 0x51, 0xcc, 0x01, 0, 0xff, 0xff, 0x00, 0x00];
const ASTC_CEM13_BLUE: StaticArray<u8> = [0x42, 0xa0, 0xf1, 0xf8, 0xa0, 0xf8, 0x40, 0xf9, 0x64, 0x28, 0, 0, 0xff, 0xff, 0x00, 0x00];
const ASTC_RAMP: StaticArray<u8> = [0x42, 0x00, 0x50, 0x90, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x27, 0x27, 0x27, 0x27];
const ASTC_TRITS: StaticArray<u8> = [0x51, 0x00, 0x00, 0xfe, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x97, 0x4a, 0xc9];
const ASTC_2PART: StaticArray<u8> = [0x22, 0xe8, 0x00, 0xf0, 0xff, 0x01, 0, 0, 0, 0, 0, 0xfe, 0x1f, 0x00, 0x00, 0x00];
const ASTC_DUAL: StaticArray<u8> = [0xae, 0x85, 0x15, 0x90, 0x29, 0xa4, 0x3d, 0xb8, 0x51, 0xcc, 0x01, 0x3c, 0x33, 0x33, 0x33, 0x33];
const ASTC_INFILL: StaticArray<u8> = [0xad, 0x03, 0x00, 0xfe, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x09, 0xc0, 0x31];

/// e0 for texels 0-7 and e1 for 8-15 (the endpoint-family blocks: their 2-bit
/// weights are 0 for the first two rows, 64 for the last two; texel = e at
/// weight 0 or 64, whatever the UNORM16 expansion).
function halves(out: Uint8Array?): string {
    return px(out, 4, 0, 0) + " " + px(out, 4, 3, 1) + " | " + px(out, 4, 0, 2) + " " + px(out, 4, 3, 3);
}

export class TextureDecoderTests extends Tests {
    override run(): void {
        group("GPU reference vectors", () => {
            test("every format decodes as the GPU does", (expect) => {
                const bytes = this.blob("texture_vectors.bin");
                if (bytes == null) return;
                expect.that(checkVectors(unzlibSync(Uint8Array.wrap(bytes!)))).is("");
            });
        });

        // S3TC / RGTC / BPTC: Khronos Data Format Specification, "S3TC",
        // "RGTC", "BPTC". 565 colours widen by bit replication (31 -> 255);
        // a third is rounded to nearest.
        group("BC decoders", () => {
            test("BC1: four colours when c0 > c1", (expect) => {
                // c0 = 0xf800 (255, 0, 0), c1 = 0x001f (0, 0, 255); texel k
                // takes index k % 4: c0, c1, (2 c0 + c1) / 3 = (170, 0, 85),
                // (c0 + 2 c1) / 3 = (85, 0, 170).
                const b = bytes([0x00, 0xf8, 0x1f, 0x00, 0xe4, 0xe4, 0xe4, 0xe4]);
                const out = decodeCompressed(RGBA_S3TC_DXT1_Format, b, 4, 4, false);
                expect.that(px(out, 4, 0, 0)).is("255,0,0,255");
                expect.that(px(out, 4, 1, 0)).is("0,0,255,255");
                expect.that(px(out, 4, 2, 0)).is("170,0,85,255");
                expect.that(px(out, 4, 3, 3)).is("85,0,170,255");
            });
            test("BC1: three colours and black when c0 <= c1", (expect) => {
                // c0 = blue, c1 = red: index 2 is (c0 + c1) / 2 = (128, 0,
                // 128) rounded; index 3 is transparent black with 1-bit
                // alpha, opaque black in RGB_S3TC_DXT1.
                const b = bytes([0x1f, 0x00, 0x00, 0xf8, 0xe4, 0xe4, 0xe4, 0xe4]);
                const rgba = decodeCompressed(RGBA_S3TC_DXT1_Format, b, 4, 4, false);
                expect.that(px(rgba, 4, 0, 0)).is("0,0,255,255");
                expect.that(px(rgba, 4, 2, 0)).is("128,0,128,255");
                expect.that(px(rgba, 4, 3, 0)).is("0,0,0,0");
                const rgb = decodeCompressed(RGB_S3TC_DXT1_Format, b, 4, 4, false);
                expect.that(px(rgb, 4, 3, 0)).is("0,0,0,255");
            });
            test("BC2: explicit 4-bit alpha", (expect) => {
                // Texel k's alpha nibble is k: alpha k * 17. Colour white.
                const b = bytes([0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0]);
                const out = decodeCompressed(RGBA_S3TC_DXT3_Format, b, 4, 4, false);
                expect.that(px(out, 4, 0, 0)).is("255,255,255,0");
                expect.that(px(out, 4, 1, 0)).is("255,255,255,17");
                expect.that(px(out, 4, 3, 3)).is("255,255,255,255");
            });
            test("BC3: eight and six alpha values", (expect) => {
                // a0 = 255 > a1 = 0: a0, a1, then (6 a0 + a1) / 7 ... rounded:
                // 219, 182, 146, 109, 73, 36. Texel k takes index k % 8
                // (3-bit indices 0..7: bytes 0x88 0xc6 0xfa).
                const alpha = bytes([255, 0, 0x88, 0xc6, 0xfa, 0x88, 0xc6, 0xfa]);
                const color = bytes([0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0]);
                let out = decodeCompressed(RGBA_S3TC_DXT5_Format, concat(alpha, color), 4, 4, false);
                let got = "";
                for (let k = 0; k < 8; k++) got += out![k * 4 + 3].toString() + " ";
                expect.that(got).is("255 0 219 182 146 109 73 36 ");
                // a0 = 0 <= a1 = 255: 0, 255, 51, 102, 153, 204, then 0 and 255.
                alpha[0] = 0;
                alpha[1] = 255;
                out = decodeCompressed(RGBA_S3TC_DXT5_Format, concat(alpha, color), 4, 4, false);
                got = "";
                for (let k = 0; k < 8; k++) got += out![k * 4 + 3].toString() + " ";
                expect.that(got).is("0 255 51 102 153 204 0 255 ");
            });
            test("BC4 and BC5 into red and green", (expect) => {
                // BC4 is a BC3 alpha block in red: (r, 0, 0, 1). BC5 adds a
                // second for green.
                const red = bytes([255, 0, 0x88, 0xc6, 0xfa, 0x88, 0xc6, 0xfa]);
                const green = bytes([10, 10, 0, 0, 0, 0, 0, 0]);
                const r = decodeCompressed(RED_RGTC1_Format, red, 4, 4, false);
                expect.that(px(r, 4, 2, 0)).is("219,0,0,255");
                const rg = decodeCompressed(RED_GREEN_RGTC2_Format, concat(red, green), 4, 4, false);
                expect.that(px(rg, 4, 2, 0)).is("219,10,0,255");
            });
            test("BC4 signed: [-1, 1] as half floats", (expect) => {
                // r0 = 127, r1 = -128 (read as -127): 8 values, index 2 is
                // (6 * 127 - 127) / 7 / 127 = 5 / 7.
                const b = bytes([127, 0x80, 0x88, 0xc6, 0xfa, 0x88, 0xc6, 0xfa]);
                const out = decodeCompressed(SIGNED_RED_RGTC1_Format, b, 4, 4, false);
                expect.that(decodesToHalfFloat(SIGNED_RED_RGTC1_Format)).is(true);
                expect.that(pxf(out, 4, 0, 0, 0)).is(1.0);
                expect.that(pxf(out, 4, 1, 0, 0)).is(-1.0);
                expect.that(Math.abs(pxf(out, 4, 2, 0, 0) - 5.0 / 7.0) < 1e-3).is(true);
                expect.that(pxf(out, 4, 2, 0, 3)).is(1.0);
            });
            test("BC7 mode 6: 4-bit indices over 8-bit endpoints", (expect) => {
                // Mode 6 (bit 6 set): 7-bit endpoints and a p-bit each; e0 =
                // 0 with p 0, e1 = 127 with p 1, so (0, 0, 0, 0) to all 255.
                // Texel k has index k (texel 0, the anchor, 3 bits): weight
                // W4[k] of 0 4 9 13 17 21 26 30 34 38 43 47 51 55 60 64, and
                // value (W * 255 + 32) >> 6: texel 1 16, texel 8 135.
                const b = new Uint8Array(16);
                put(b, 0, 7, 0x40);
                for (let c = 0; c < 4; c++) put(b, 7 + c * 14 + 7, 7, 127);
                put(b, 63, 1, 0);
                put(b, 64, 1, 1);
                put(b, 65, 3, 0);
                for (let k = 1; k < 16; k++) put(b, 68 + (k - 1) * 4, 4, k);
                const out = decodeCompressed(RGBA_BPTC_Format, b, 4, 4, false);
                expect.that(px(out, 4, 0, 0)).is("0,0,0,0");
                expect.that(px(out, 4, 1, 0)).is("16,16,16,16");
                expect.that(px(out, 4, 0, 2)).is("135,135,135,135");
                expect.that(px(out, 4, 3, 3)).is("255,255,255,255");
            });
            test("BC7 reserved mode 8 is transparent black", (expect) => {
                const out = decodeCompressed(RGBA_BPTC_Format, new Uint8Array(16), 4, 4, false);
                expect.that(px(out, 4, 2, 2)).is("0,0,0,0");
            });
            test("sizes that are not block multiples are cropped", (expect) => {
                const b = bytes([0x00, 0xf8, 0x1f, 0x00, 0xe4, 0xe4, 0xe4, 0xe4]);
                const out = decodeCompressed(RGBA_S3TC_DXT1_Format, b, 3, 2, false);
                expect.that(out!.length).is(3 * 2 * 4);
                expect.that(px(out, 3, 2, 1)).is("170,0,85,255");
            });
        });

        // ETC1 / ETC2 / EAC: Khronos Data Format Specification, "ETC2"
        // and "EAC"; 64-bit big-endian blocks, texel (x, y) is pixel index
        // x * 4 + y.
        group("ETC decoders", () => {
            test("individual mode, side by side sub-blocks", (expect) => {
                // R1 G1 B1 = 10 3 0 (x 17: 170 51 0), R2 G2 B2 = 5 12 15 (85
                // 204 255); table 0 (+2) on the left half, 7 (+47) on the
                // right; every index 0 (small positive).
                const hi: u32 = <u32>(10 << 28) | (5 << 24) | (3 << 20) | (12 << 16) | (0 << 12) | (15 << 8) | (0 << 5) | (7 << 2);
                const out = decodeCompressed(RGB_ETC2_Format, etc(hi, 0), 4, 4, false);
                expect.that(px(out, 4, 1, 3)).is("172,53,2,255");
                expect.that(px(out, 4, 2, 0)).is("132,251,255,255");
                // ETC1 reads the same block the same way.
                expect.that(px(decodeCompressed(RGB_ETC1_Format, etc(hi, 0), 4, 4, false), 4, 2, 0)).is("132,251,255,255");
            });
            test("differential mode, stacked sub-blocks", (expect) => {
                // R G B = 16 4 31 (5 bits: 132 33 255), deltas -1 +3 0 (15 7
                // 31: 123 57 255); flip: top rows use the first colour, table 1 (17);
                // bottom rows the second, table 2 (29); every index 3 (-large).
                const hi: u32 = <u32>(16 << 27) | (7 << 24) | (4 << 19) | (3 << 16) | (31 << 11) | (0 << 8) | (1 << 5) | (2 << 2) | 3;
                const out = decodeCompressed(RGB_ETC2_Format, etc(hi, 0xffffffff), 4, 4, false);
                expect.that(px(out, 4, 0, 1)).is("115,16,238,255");
                expect.that(px(out, 4, 3, 2)).is("94,28,226,255");
            });
            test("T mode", (expect) => {
                // Red overflows (R = 11110 + delta 010 = 32): T mode. Colour 1
                // (10, 3, 12) = (170, 51, 204); colour 2 (5, 6, 7) = (85, 102,
                // 119); distance index 5 = 32. Paint 0 colour 1, 1 colour 2 +
                // 32, 2 colour 2, 3 colour 2 - 32; row y takes paint y.
                const hi: u32 = <u32>(7 << 29) | (2 << 27) | (0 << 26) | (2 << 24) | (3 << 20) | (12 << 16) | (5 << 12)
                    | (6 << 8) | (7 << 4) | (2 << 2) | (1 << 1) | 1;
                const out = decodeCompressed(RGB_ETC2_Format, etc(hi, rowIndices()), 4, 4, false);
                expect.that(px(out, 4, 0, 0)).is("170,51,204,255");
                expect.that(px(out, 4, 1, 1)).is("117,134,151,255");
                expect.that(px(out, 4, 2, 2)).is("85,102,119,255");
                expect.that(px(out, 4, 3, 3)).is("53,70,87,255");
            });
            test("H mode", (expect) => {
                // Green overflows (G = 00001 + delta 101 = -2): H mode.
                // Colour 1 (9, 6, 10) = (153, 102, 170), colour 2 (4, 8, 2) =
                // (68, 136, 34); distance index (da 1, db 0, colour 1 >=
                // colour 2: 1) = 5, 32. Paints: colour 1 +- 32, colour 2 +- 32.
                const hi: u32 = <u32>(9 << 27) | (3 << 24) | (0 << 20) | (1 << 19) | (1 << 18) | (2 << 15) | (4 << 11)
                    | (8 << 7) | (2 << 3) | (1 << 2) | (1 << 1);
                const out = decodeCompressed(RGB_ETC2_Format, etc(hi, rowIndices()), 4, 4, false);
                expect.that(px(out, 4, 0, 0)).is("185,134,202,255");
                expect.that(px(out, 4, 1, 1)).is("121,70,138,255");
                expect.that(px(out, 4, 2, 2)).is("100,168,66,255");
                expect.that(px(out, 4, 3, 3)).is("36,104,2,255");
            });
            test("planar mode", (expect) => {
                // Blue overflows (B = 00010 + delta 100 = -2): planar. O = (32,
                // 64, 16) -> (130, 129, 65), H = (63, 0, 32) -> (255, 0, 130),
                // V = (0, 127, 48) -> (0, 255, 195); texel = (x (H - O) + y (V
                // - O) + 4 O + 2) >> 2, clamped.
                const hi: u32 = <u32>(32 << 25) | (1 << 24) | (0 << 17) | (0 << 16) | (2 << 11) | (1 << 10) | (0 << 7)
                    | (31 << 2) | (1 << 1) | 1;
                const lo: u32 = <u32>(0 << 25) | (32 << 19) | (0 << 13) | (127 << 6) | 48;
                const out = decodeCompressed(RGB_ETC2_Format, etc(hi, lo), 4, 4, false);
                expect.that(px(out, 4, 0, 0)).is("130,129,65,255");
                expect.that(px(out, 4, 3, 0)).is("224,32,114,255");
                expect.that(px(out, 4, 0, 3)).is("33,224,163,255");
                expect.that(px(out, 4, 3, 3)).is("126,127,211,255");
            });
            test("RGB8A1: index 2 is transparent when not opaque", (expect) => {
                // The differential block above with its opaque bit clear:
                // index 0 takes no modifier, 1 and 3 +- the large step, 2 is
                // transparent black.
                const hi: u32 = <u32>(16 << 27) | (7 << 24) | (4 << 19) | (3 << 16) | (31 << 11) | (0 << 8) | (1 << 5) | (2 << 2) | 1;
                const out = decodeCompressed(RGB_ETC2_A1_Format, etc(hi, rowIndices()), 4, 4, false);
                expect.that(px(out, 4, 0, 0)).is("132,33,255,255");
                expect.that(px(out, 4, 1, 1)).is("149,50,255,255");
                expect.that(px(out, 4, 2, 2)).is("0,0,0,0");
                expect.that(px(out, 4, 3, 3)).is("94,28,226,255");
            });
            test("EAC alpha, R11 and signed R11", (expect) => {
                // Base 128, multiplier 3, table 13 (-1 -2 -3 -10 0 1 2 9);
                // pixel index i takes index i % 8: alpha 128 + 3 m. Texel (x,
                // y) is index 4 x + y.
                let ind: u64 = 0;
                for (let i = 0; i < 16; i++) ind |= <u64>(i % 8) << <u64>(45 - 3 * i);
                const alpha = etc(<u32>(128 << 24) | (3 << 20) | (13 << 16) | <u32>(ind >> 32), <u32>ind);
                const out = decodeCompressed(RGBA_ETC2_EAC_Format, concat(alpha, new Uint8Array(8)), 4, 4, false);
                let got = "";
                for (let y = 0; y < 4; y++) got += out![(y * 4) * 4 + 3].toString() + " " + out![(y * 4 + 1) * 4 + 3].toString() + " ";
                expect.that(got).is("125 128 122 131 119 134 98 155 ");
                // R11: base 100, multiplier 2, table 0, index 7 (+14): 100 * 8
                // + 4 + 14 * 2 * 8 = 1028 of 2047, 128 in 8 bits.
                const r = decodeCompressed(R11_EAC_Format, etc(<u32>((100 << 24) | (2 << 20) | 0xffff), 0xffffffff), 4, 4, false);
                expect.that(px(r, 4, 1, 1)).is("128,0,0,255");
                // Signed: base -50, multiplier 2, index 0 (-3): -400 - 48 =
                // -448 of 1023.
                const s = decodeCompressed(SIGNED_R11_EAC_Format, etc(<u32>((0xce << 24) | (2 << 20)), 0), 4, 4, false);
                expect.that(Math.abs(pxf(s, 4, 0, 0, 0) + 448.0 / 1023.0) < 1e-3).is(true);
            });
        });

        // ASTC: Khronos Data Format Specification 1.3, "ASTC". Each block
        // below is 4x4 with a 4x4 grid of 2-bit weights (0, 21, 43, 64)
        // and 8-bit colour values (unquantized as is) unless it says
        // otherwise; its parameters are tools/astc_encode.py's pack_block
        // arguments. Linear endpoints expand to e * 257 and the 16-bit
        // result rounds to 8 bits; sRGB ones to (e << 8) | 0x80, keeping the
        // top 8 bits.
        group("ASTC decoder", () => {
            test("void extent", (expect) => {
                // RGBA16 (0, 0x8000, 0xffff, 0x4040): linear rounds C / 257
                // (0, 127.5 -> 128, 255, 64); sRGB keeps C >> 8 (0, 128, 255,
                // 64).
                const b = new Uint8Array(16);
                put(b, 0, 12, 0xdfc);   // 0x1fc, LDR, the two reserved 1 bits
                for (let i = 0; i < 4; i++) put(b, 12 + i * 13, 13, 0x1fff);
                put(b, 64, 16, 0); put(b, 80, 16, 0x8000); put(b, 96, 16, 0xffff); put(b, 112, 16, 0x4040);
                expect.that(px(decodeCompressed(RGBA_ASTC_4x4_Format, b, 4, 4, false), 4, 3, 3)).is("0,128,255,64");
                expect.that(px(decodeCompressed(RGBA_ASTC_4x4_Format, b, 4, 4, true), 4, 0, 0)).is("0,128,255,64");
                // The HDR flag (bit 9) is the error colour in LDR.
                put(b, 9, 1, 1);
                expect.that(px(decodeCompressed(RGBA_ASTC_4x4_Format, b, 4, 4, false), 4, 0, 0)).is("255,0,255,255");
            });
            test("endpoint modes", (expect) => {
                // Weights 0 then 64, so the texels are e0 then e1.
                const a = RGBA_ASTC_4x4_Format;
                // CEM 0, luminance (40, 200): e = (L, L, L, 255).
                expect.that(halves(decodeCompressed(a, bytes(ASTC_CEM0), 4, 4, false)))
                    .is("40,40,40,255 40,40,40,255 | 200,200,200,255 200,200,200,255");
                // CEM 1, (85, 199): L0 = (85 >> 2) | (199 & 0xc0) = 213, L1 =
                // L0 + (199 & 0x3f) = 220.
                expect.that(halves(decodeCompressed(a, bytes(ASTC_CEM1), 4, 4, false)))
                    .is("213,213,213,255 213,213,213,255 | 220,220,220,255 220,220,220,255");
                // CEM 4, (10, 250, 30, 220): (L0, A0) = (10, 30), (L1, A1) = (250, 220).
                expect.that(halves(decodeCompressed(a, bytes(ASTC_CEM4), 4, 4, false)))
                    .is("10,10,10,30 10,10,10,30 | 250,250,250,220 250,250,250,220");
                // CEM 5, (100, 20, 200, 250): bit_transfer_signed gives L0 =
                // 50 + 10, A0 = (100 | 128) = 228 and offset (125 & 63) - 64 =
                // -3.
                expect.that(halves(decodeCompressed(a, bytes(ASTC_CEM5), 4, 4, false)))
                    .is("50,50,50,228 50,50,50,228 | 60,60,60,225 60,60,60,225");
                // CEM 6, (200, 100, 50, 128): e0 = (v * 128) >> 8, e1 = v.
                expect.that(halves(decodeCompressed(a, bytes(ASTC_CEM6), 4, 4, false)))
                    .is("100,50,25,255 100,50,25,255 | 200,100,50,255 200,100,50,255");
                // CEM 8, (10, 200, 20, 210, 30, 220): sum(e1) >= sum(e0).
                expect.that(halves(decodeCompressed(a, bytes(ASTC_CEM8), 4, 4, false)))
                    .is("10,20,30,255 10,20,30,255 | 200,210,220,255 200,210,220,255");
                // CEM 8, (200, 10, 210, 20, 220, 30): the sums are the other way:
                // blue contraction ((r + b) >> 1, (g + b) >> 1, b), swapped.
                expect.that(halves(decodeCompressed(a, bytes(ASTC_CEM8_BLUE), 4, 4, false)))
                    .is("20,25,30,255 20,25,30,255 | 210,215,220,255 210,215,220,255");
                // CEM 9, (60, 16, 80, 136, 100, 126): bases (30, 168, 50),
                // offsets (8, 4, -1), summing >= 0.
                expect.that(halves(decodeCompressed(a, bytes(ASTC_CEM9), 4, 4, false)))
                    .is("30,168,50,255 30,168,50,255 | 38,172,49,255 38,172,49,255");
                // CEM 10, (200, 100, 50, 128, 10, 240): CEM 6 with alphas 10, 240.
                expect.that(halves(decodeCompressed(a, bytes(ASTC_CEM10), 4, 4, false)))
                    .is("100,50,25,10 100,50,25,10 | 200,100,50,240 200,100,50,240");
                // CEM 12, (10, 200, 20, 210, 30, 220, 40, 230).
                expect.that(halves(decodeCompressed(a, bytes(ASTC_CEM12), 4, 4, false)))
                    .is("10,20,30,40 10,20,30,40 | 200,210,220,230 200,210,220,230");
                // CEM 13, (120, 124, 80, 124, 160, 124, 50, 20): bases (60, 40,
                // 80, 25), offsets (-2, -2, -2, +10) summing < 0: e0 =
                // blue_contract(base + offset) = (68, 58, 78, 35), e1 =
                // blue_contract(base) = (70, 60, 80, 25).
                expect.that(halves(decodeCompressed(a, bytes(ASTC_CEM13_BLUE), 4, 4, false)))
                    .is("68,58,78,35 68,58,78,35 | 70,60,80,25 70,60,80,25");
            });
            test("weights between the endpoints, linear and sRGB", (expect) => {
                // CEM 0 (40, 200), texel weights k % 4: 0, 21, 43, 64. Linear,
                // weight 21: (10280 * 43 + 51400 * 21 + 32) >> 6 = 23773,
                // 92.5 -> 93 (Apple's GPU, through 12 bits, says 92); weight
                // 43: 37908 -> 148. sRGB: (10368 * 43 + 51328 * 21 + 32) >> 6
                // = 23808, >> 8 = 93; 37888 >> 8 = 148.
                const lin = decodeCompressed(RGBA_ASTC_4x4_Format, bytes(ASTC_RAMP), 4, 4, false);
                expect.that(px(lin, 4, 1, 0) + " " + px(lin, 4, 2, 0)).is("93,93,93,255 148,148,148,255");
                const srgb = decodeCompressed(RGBA_ASTC_4x4_Format, bytes(ASTC_RAMP), 4, 4, true);
                expect.that(px(srgb, 4, 1, 0) + " " + px(srgb, 4, 2, 0)).is("93,93,93,255 148,148,148,255");
            });
            test("trit-encoded weights", (expect) => {
                // Weight range 3 (one trit each: 0, 32, 64), weights k % 3,
                // CEM 0 (0, 255): weight 32 is (65535 * 32 + 32) >> 6 = 32768,
                // 127.5 -> 128.
                const out = decodeCompressed(RGBA_ASTC_4x4_Format, bytes(ASTC_TRITS), 4, 4, false);
                expect.that(px(out, 4, 0, 0) + " " + px(out, 4, 1, 0) + " " + px(out, 4, 2, 0))
                    .is("0,0,0,255 128,128,128,255 255,255,255,255");
            });
            test("two partitions", (expect) => {
                // Partition index 7, CEM 8 in both: partition 0 red, 1 blue
                // (6-bit colour values, 63 -> 255), weights 0 (a 4x3 grid).
                // The specification's select_partition(7, x, y, 2, small
                // block) maps the rows to BBRR RRRB BRRB BRRB.
                const out = decodeCompressed(RGBA_ASTC_4x4_Format, bytes(ASTC_2PART), 4, 4, false);
                let map = "";
                for (let k = 0; k < 16; k++) map += out![k * 4] == 255 ? "R" : "B";
                expect.that(map).is("BBRRRRRBBRRBBRRB");
                expect.that(px(out, 4, 0, 0)).is("0,0,255,255");
            });
            test("dual plane", (expect) => {
                // CEM 12 (as above) with a second weight plane for alpha
                // (component 3); 3x3 grids, plane 0 weights 0, plane 1 64:
                // e0's colour with e1's alpha.
                const out = decodeCompressed(RGBA_ASTC_4x4_Format, bytes(ASTC_DUAL), 4, 4, false);
                expect.that(px(out, 4, 2, 1)).is("10,20,30,230");
            });
            test("weight grid infill", (expect) => {
                // 5x5 block, 3x3 grid in range 10 (quint and a bit): value 9
                // unquantizes to 36 at grid (2, 0) and (0, 2), 0 elsewhere;
                // CEM 0 (0, 255). Texel (4, 0) sits on grid (2, 0): (65535 *
                // 36 + 32) >> 6 = 36864 -> 143. Texel (3, 0): Ds = (1024 + 2)
                // / 4 = 256, gs = (256 * 3 * 2 + 32) >> 6 = 24: between grid 1
                // and 2 with fs = 8, so (0 * 8 + 36 * 8 + 8) >> 4 = 18 -> 18432
                // -> 72.
                const out = decodeCompressed(RGBA_ASTC_5x5_Format, bytes(ASTC_INFILL), 5, 5, false);
                expect.that(px(out, 5, 4, 0) + " " + px(out, 5, 3, 0) + " " + px(out, 5, 0, 4))
                    .is("143,143,143,255 72,72,72,255 143,143,143,255");
            });
            test("reserved and HDR encodings decode magenta", (expect) => {
                // Block mode 0 is reserved.
                expect.that(px(decodeCompressed(RGBA_ASTC_4x4_Format, new Uint8Array(16), 4, 4, false), 4, 1, 1))
                    .is("255,0,255,255");
                // CEM 2 (HDR luminance) in the CEM 0 block: its partition is
                // the error colour.
                const b = bytes(ASTC_CEM0);
                put(b, 13, 4, 2);
                expect.that(px(decodeCompressed(RGBA_ASTC_4x4_Format, b, 4, 4, false), 4, 0, 0)).is("255,0,255,255");
            });
            test("footprints", (expect) => {
                // Partial blocks crop: a 7x3 level of 6x5 blocks is 2 x 1 blocks.
                const two = concat(bytes(ASTC_CEM0), bytes(ASTC_CEM0));
                expect.that(compressedBlockWidth(RGBA_ASTC_6x5_Format)).is(6);
                expect.that(compressedBlockHeight(RGBA_ASTC_6x5_Format)).is(5);
                expect.that(decodeCompressed(RGBA_ASTC_6x5_Format, two, 7, 3, false)!.length).is(7 * 3 * 4);
                expect.that(compressedBlockWidth(RGBA_ASTC_12x12_Format)).is(12);
                expect.that(compressedBlockHeight(RGBA_ASTC_10x8_Format)).is(8);
            });
        });
    }
}
