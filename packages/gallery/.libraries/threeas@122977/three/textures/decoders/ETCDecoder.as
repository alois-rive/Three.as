// CPU decoders for ETC1, ETC2 (RGB8, RGB8 with punch-through alpha, RGBA8
// with EAC alpha) and EAC (R11, RG11, unsigned and signed), as the Khronos
// Data Format Specification (sections "ETC1", "ETC2", "EAC") and OpenGL
// ES 3.0's appendix C describe them. ETC1 is ETC2 RGB8's individual and
// differential modes, so the ETC2 decoder reads it. TextureDecoders
// calls them when the device cannot sample a format (ThreeAS addition).
//
// Blocks are 64-bit big-endian words; texel (x, y) of a block is pixel
// index x * 4 + y (columns first). Unsigned formats decode to RGBA8, signed
// EAC to float RGBA in [-1, 1]. R11 / RG11 decode to (r, 0, 0, 1) and
// (r, g, 0, 1); unsigned 11-bit values round to 8 bits.

import { storeBlock, storeBlockF } from "./BCDecoder";

// Intensity modifiers of the individual and differential modes, per table
// codeword: the small and large step (pixel indices 0 / 2 and 1 / 3).
const ETC_MODIFIERS: StaticArray<i32> = [2, 8, 5, 17, 9, 29, 13, 42, 18, 60, 24, 80, 33, 106, 47, 183];
// T and H modes' distances.
const ETC_DISTANCES: StaticArray<i32> = [3, 6, 11, 16, 23, 32, 41, 64];
// EAC modifiers: 16 tables of 8.
const EAC_MODIFIERS: StaticArray<i32> = [
    -3, -6, -9, -15, 2, 5, 8, 14,
    -3, -7, -10, -13, 2, 6, 9, 12,
    -2, -5, -8, -13, 1, 4, 7, 12,
    -2, -4, -6, -13, 1, 3, 5, 12,
    -3, -6, -8, -12, 2, 5, 7, 11,
    -3, -7, -9, -11, 2, 6, 8, 10,
    -4, -7, -8, -11, 3, 6, 7, 10,
    -3, -5, -8, -11, 2, 4, 7, 10,
    -2, -6, -8, -10, 1, 5, 7, 9,
    -2, -5, -8, -10, 1, 4, 7, 9,
    -2, -4, -8, -10, 1, 3, 7, 9,
    -2, -5, -7, -10, 1, 4, 6, 9,
    -3, -4, -7, -10, 2, 3, 6, 9,
    -1, -2, -3, -10, 0, 1, 2, 9,
    -4, -6, -8, -9, 3, 5, 7, 8,
    -3, -5, -7, -9, 2, 4, 6, 8,
];

@inline function clamp255(v: i32): i32 { return v < 0 ? 0 : v > 255 ? 255 : v; }
@inline function bit(w: u32, i: i32): i32 { return <i32>((w >> <u32>i) & 1); }
@inline function field(w: u32, hi: i32, lo: i32): i32 { return <i32>((w >> <u32>lo) & ((<u32>1 << <u32>(hi - lo + 1)) - 1)); }
@inline function ext4(v: i32): i32 { return v * 17; }
@inline function ext5(v: i32): i32 { return (v << 3) | (v >> 2); }
@inline function ext6(v: i32): i32 { return (v << 2) | (v >> 4); }
@inline function ext7(v: i32): i32 { return (v << 1) | (v >> 6); }

function readBE(data: Uint8Array, o: i32): u32 {
    return (<u32>data[o] << 24) | (<u32>data[o + 1] << 16) | (<u32>data[o + 2] << 8) | <u32>data[o + 3];
}

const paint = new StaticArray<i32>(16);   // four RGBA paint colours (T and H modes)

/// Decodes the ETC2 RGB block at `data[o]` into `block` (16 RGBA8 texels,
/// rows first). `punchthrough` reads the RGB8A1 variant: the
/// differential bit is the opaque bit, and when it is 0 pixel index 2 is
/// transparent black (planar blocks stay opaque).
export function decodeETC2Block(data: Uint8Array, o: i32, block: Uint8Array, punchthrough: bool): void {
    const hiw = readBE(data, o), low = readBE(data, o + 4);
    const diffBit = bit(hiw, 1);
    const opaque = !punchthrough || diffBit == 1;
    const differential = punchthrough || diffBit == 1;
    if (differential) {
        const r = field(hiw, 31, 27), g = field(hiw, 23, 19), b = field(hiw, 15, 11);
        const dr = (field(hiw, 26, 24) << 29) >> 29, dg = (field(hiw, 18, 16) << 29) >> 29;
        const db = (field(hiw, 10, 8) << 29) >> 29;
        if (r + dr < 0 || r + dr > 31) { decodeTH(hiw, low, block, false, opaque); return; }
        if (g + dg < 0 || g + dg > 31) { decodeTH(hiw, low, block, true, opaque); return; }
        if (b + db < 0 || b + db > 31) { decodePlanar(hiw, low, block); return; }
        decodeSubblocks(hiw, low, block, ext5(r), ext5(g), ext5(b), ext5(r + dr), ext5(g + dg), ext5(b + db),
            opaque);
        return;
    }
    decodeSubblocks(hiw, low, block, ext4(field(hiw, 31, 28)), ext4(field(hiw, 23, 20)), ext4(field(hiw, 15, 12)),
        ext4(field(hiw, 27, 24)), ext4(field(hiw, 19, 16)), ext4(field(hiw, 11, 8)), true);
}

function decodeSubblocks(hiw: u32, low: u32, block: Uint8Array, r1: i32, g1: i32, b1: i32, r2: i32, g2: i32, b2: i32,
                         opaque: bool): void {
    const cw1 = field(hiw, 7, 5), cw2 = field(hiw, 4, 2);
    const flip = bit(hiw, 0) == 1;
    for (let x = 0; x < 4; x++) {
        for (let y = 0; y < 4; y++) {
            const i = x * 4 + y;
            const index = (bit(low, i + 16) << 1) | bit(low, i);
            const second = flip ? y >= 2 : x >= 2;
            const cw = second ? cw2 : cw1;
            const t = (y * 4 + x) * 4;
            if (!opaque && index == 2) {
                block[t] = 0; block[t + 1] = 0; block[t + 2] = 0; block[t + 3] = 0;
                continue;
            }
            let m = ETC_MODIFIERS[cw * 2 + (index & 1)];
            if (!opaque && index == 0) m = 0;
            if (index >= 2) m = -m;
            block[t] = <u8>clamp255((second ? r2 : r1) + m);
            block[t + 1] = <u8>clamp255((second ? g2 : g1) + m);
            block[t + 2] = <u8>clamp255((second ? b2 : b1) + m);
            block[t + 3] = 255;
        }
    }
}

// T mode (`h` false) and H mode.
function decodeTH(hiw: u32, low: u32, block: Uint8Array, h: bool, opaque: bool): void {
    let r1: i32, g1: i32, b1: i32, r2: i32, g2: i32, b2: i32, d: i32;
    const p = paint;
    if (!h) {
        r1 = ext4((field(hiw, 28, 27) << 2) | field(hiw, 25, 24));
        g1 = ext4(field(hiw, 23, 20));
        b1 = ext4(field(hiw, 19, 16));
        r2 = ext4(field(hiw, 15, 12));
        g2 = ext4(field(hiw, 11, 8));
        b2 = ext4(field(hiw, 7, 4));
        d = ETC_DISTANCES[(field(hiw, 3, 2) << 1) | bit(hiw, 0)];
        p[0] = r1; p[1] = g1; p[2] = b1;
        p[4] = clamp255(r2 + d); p[5] = clamp255(g2 + d); p[6] = clamp255(b2 + d);
        p[8] = r2; p[9] = g2; p[10] = b2;
        p[12] = clamp255(r2 - d); p[13] = clamp255(g2 - d); p[14] = clamp255(b2 - d);
    } else {
        const R1 = field(hiw, 30, 27), G1 = (field(hiw, 26, 24) << 1) | bit(hiw, 20);
        const B1 = (bit(hiw, 19) << 3) | field(hiw, 17, 15);
        const R2 = field(hiw, 14, 11), G2 = field(hiw, 10, 7), B2 = field(hiw, 6, 3);
        const order = ((R1 << 8) | (G1 << 4) | B1) >= ((R2 << 8) | (G2 << 4) | B2) ? 1 : 0;
        d = ETC_DISTANCES[(bit(hiw, 2) << 2) | (bit(hiw, 0) << 1) | order];
        r1 = ext4(R1); g1 = ext4(G1); b1 = ext4(B1);
        r2 = ext4(R2); g2 = ext4(G2); b2 = ext4(B2);
        p[0] = clamp255(r1 + d); p[1] = clamp255(g1 + d); p[2] = clamp255(b1 + d);
        p[4] = clamp255(r1 - d); p[5] = clamp255(g1 - d); p[6] = clamp255(b1 - d);
        p[8] = clamp255(r2 + d); p[9] = clamp255(g2 + d); p[10] = clamp255(b2 + d);
        p[12] = clamp255(r2 - d); p[13] = clamp255(g2 - d); p[14] = clamp255(b2 - d);
    }
    p[3] = 255; p[7] = 255; p[11] = 255; p[15] = 255;
    if (!opaque) { p[8] = 0; p[9] = 0; p[10] = 0; p[11] = 0; }
    for (let x = 0; x < 4; x++) {
        for (let y = 0; y < 4; y++) {
            const i = x * 4 + y;
            const index = ((bit(low, i + 16) << 1) | bit(low, i)) * 4;
            const t = (y * 4 + x) * 4;
            block[t] = <u8>p[index]; block[t + 1] = <u8>p[index + 1];
            block[t + 2] = <u8>p[index + 2]; block[t + 3] = <u8>p[index + 3];
        }
    }
}

function decodePlanar(hiw: u32, low: u32, block: Uint8Array): void {
    const ro = ext6(field(hiw, 30, 25));
    const go = ext7((bit(hiw, 24) << 6) | field(hiw, 22, 17));
    const bo = ext6((bit(hiw, 16) << 5) | (field(hiw, 12, 11) << 3) | field(hiw, 9, 7));
    const rh = ext6((field(hiw, 6, 2) << 1) | bit(hiw, 0));
    const gh = ext7(field(low, 31, 25));
    const bh = ext6(field(low, 24, 19));
    const rv = ext6(field(low, 18, 13));
    const gv = ext7(field(low, 12, 6));
    const bv = ext6(field(low, 5, 0));
    for (let y = 0; y < 4; y++) {
        for (let x = 0; x < 4; x++) {
            const t = (y * 4 + x) * 4;
            block[t] = <u8>clamp255((x * (rh - ro) + y * (rv - ro) + 4 * ro + 2) >> 2);
            block[t + 1] = <u8>clamp255((x * (gh - go) + y * (gv - go) + 4 * go + 2) >> 2);
            block[t + 2] = <u8>clamp255((x * (bh - bo) + y * (bv - bo) + 4 * bo + 2) >> 2);
            block[t + 3] = 255;
        }
    }
}

/// Decodes the EAC block at `data[o]` as 8-bit alpha into channel `c` of
/// `block` (ETC2 RGBA8's alpha).
export function decodeEACAlphaBlock(data: Uint8Array, o: i32, block: Uint8Array, c: i32): void {
    const base = <i32>data[o];
    const mult = <i32>data[o + 1] >> 4;
    const table = (<i32>data[o + 1] & 15) * 8;
    let bits: u64 = 0;
    for (let i = 2; i < 8; i++) bits = (bits << 8) | <u64>data[o + i];
    for (let i = 0; i < 16; i++) {
        const index = <i32>((bits >> <u64>(45 - 3 * i)) & 7);
        const x = i >> 2, y = i & 3;
        block[(y * 4 + x) * 4 + c] = <u8>clamp255(base + EAC_MODIFIERS[table + index] * mult);
    }
}

/// Decodes the EAC R11 block at `data[o]` into channel `c` of `out`, an
/// 8-bit block (unsigned, `fblock` null) or a float block (`signed`).
function decodeEAC11Block(data: Uint8Array, o: i32, block: Uint8Array, fblock: Float32Array, c: i32,
                          signed: bool): void {
    let base = signed ? <i32><i8>data[o] : <i32>data[o];
    if (signed && base == -128) base = -127;
    const mult = <i32>data[o + 1] >> 4;
    const table = (<i32>data[o + 1] & 15) * 8;
    let bits: u64 = 0;
    for (let i = 2; i < 8; i++) bits = (bits << 8) | <u64>data[o + i];
    for (let i = 0; i < 16; i++) {
        const index = <i32>((bits >> <u64>(45 - 3 * i)) & 7);
        const m = EAC_MODIFIERS[table + index];
        const x = i >> 2, y = i & 3;
        const t = (y * 4 + x) * 4 + c;
        if (signed) {
            let v = base * 8 + (mult != 0 ? m * mult * 8 : m);
            v = v < -1023 ? -1023 : v > 1023 ? 1023 : v;
            fblock[t] = <f32>v / 1023;
        } else {
            let v = base * 8 + 4 + (mult != 0 ? m * mult * 8 : m);
            v = v < 0 ? 0 : v > 2047 ? 2047 : v;
            block[t] = <u8>((v * 255 + 1023) / 2047);
        }
    }
}

/// ETC1 / ETC2 RGB8 (`punchthrough` for RGB8A1), 8 bytes a block.
export function decodeETC2(data: Uint8Array, width: i32, height: i32, out: Uint8Array, punchthrough: bool): void {
    const block = new Uint8Array(64);
    let o = 0;
    for (let by = 0; by < height; by += 4) {
        for (let bx = 0; bx < width; bx += 4) {
            decodeETC2Block(data, o, block, punchthrough);
            storeBlock(out, width, height, bx, by, 4, 4, block);
            o += 8;
        }
    }
}

/// ETC2 RGBA8: an EAC alpha block, then an ETC2 RGB block.
export function decodeETC2RGBA(data: Uint8Array, width: i32, height: i32, out: Uint8Array): void {
    const block = new Uint8Array(64);
    let o = 0;
    for (let by = 0; by < height; by += 4) {
        for (let bx = 0; bx < width; bx += 4) {
            decodeETC2Block(data, o + 8, block, false);
            decodeEACAlphaBlock(data, o, block, 3);
            storeBlock(out, width, height, bx, by, 4, 4, block);
            o += 16;
        }
    }
}

/// EAC R11 (`channels` 1) and RG11 (2), unsigned: RGBA8.
export function decodeEAC(data: Uint8Array, width: i32, height: i32, out: Uint8Array, channels: i32): void {
    const block = new Uint8Array(64);
    const unused = new Float32Array(0);
    for (let k = 0; k < 16; k++) {
        block[k * 4 + 1] = 0;
        block[k * 4 + 2] = 0;
        block[k * 4 + 3] = 255;
    }
    let o = 0;
    for (let by = 0; by < height; by += 4) {
        for (let bx = 0; bx < width; bx += 4) {
            for (let c = 0; c < channels; c++) decodeEAC11Block(data, o + c * 8, block, unused, c, false);
            storeBlock(out, width, height, bx, by, 4, 4, block);
            o += channels * 8;
        }
    }
}

/// EAC R11 / RG11 signed: floats in [-1, 1].
export function decodeEACSigned(data: Uint8Array, width: i32, height: i32, out: Float32Array, channels: i32): void {
    const block = new Float32Array(64);
    const unused = new Uint8Array(0);
    for (let k = 0; k < 16; k++) block[k * 4 + 3] = 1;
    let o = 0;
    for (let by = 0; by < height; by += 4) {
        for (let bx = 0; bx < width; bx += 4) {
            for (let c = 0; c < channels; c++) decodeEAC11Block(data, o + c * 8, unused, block, c, true);
            storeBlockF(out, width, height, bx, by, 4, 4, block);
            o += channels * 8;
        }
    }
}
