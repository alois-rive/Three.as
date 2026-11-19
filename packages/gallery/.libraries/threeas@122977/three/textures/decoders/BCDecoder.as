// CPU decoders for the BC formats (S3TC / DXT, RGTC, BPTC): BC1 (with or
// without its 1-bit alpha), BC2, BC3, BC4 and BC5 (unsigned and signed) and
// BC7, as Microsoft's Direct3D 11 block compression documentation and the
// Khronos Data Format Specification (sections "S3TC", "RGTC", "BPTC")
// describe them. BC6H (HDR) is not decoded. TextureDecoders calls
// them when the device cannot sample a format (ThreeAS addition; three.js
// has no CPU fallback for these formats).
//
// Unsigned formats decode to RGBA8 (`out`: 4 bytes a texel, rows top
// first), signed ones (BC4/BC5 SNORM) to float RGBA in [-1, 1]
// (`outf`). Interpolated colours round to nearest: (2 a + b) / 3 is
// (2 a + b + 1) / 3. GPUs may differ by a step or two there (Apple's
// interpolates with BC7's 6-bit weights; the formats allow it); BC7
// interpolation is exact ((64 - w) a + w b + 32) >> 6, as its
// specification requires. BC7's partition and anchor tables are the
// specification's: they were read back from a GPU decoder through
// tools/gpu_decode_reference.swift (blocks whose texels show each table
// entry), and tools/make_texture_vectors.py checks every decoder here
// against that GPU.

/// Expands 5-6-5 colour channels to 8 bits (bit replication).
@inline function expand5(v: i32): i32 { return (v << 3) | (v >> 2); }
@inline function expand6(v: i32): i32 { return (v << 2) | (v >> 4); }

/// Writes a decoded block (bw x bh texels of RGBA8 in `block`) into `out`,
/// clipped to the image.
export function storeBlock(out: Uint8Array, width: i32, height: i32, bx: i32, by: i32, bw: i32, bh: i32,
                           block: Uint8Array): void {
    const w = min<i32>(bw, width - bx), h = min<i32>(bh, height - by);
    for (let y = 0; y < h; y++) {
        let o = ((by + y) * width + bx) * 4;
        let s = y * bw * 4;
        for (let x = 0; x < w * 4; x++) out[o + x] = block[s + x];
    }
}

/// As storeBlock for float blocks.
export function storeBlockF(out: Float32Array, width: i32, height: i32, bx: i32, by: i32, bw: i32, bh: i32,
                            block: Float32Array): void {
    const w = min<i32>(bw, width - bx), h = min<i32>(bh, height - by);
    for (let y = 0; y < h; y++) {
        let o = ((by + y) * width + bx) * 4;
        let s = y * bw * 4;
        for (let x = 0; x < w * 4; x++) out[o + x] = block[s + x];
    }
}

/// Decodes the BC1 colour block at `data[o]` into `block` (16 RGBA8
/// texels). `fourColors` forces the four-colour palette (BC2 and BC3
/// colour blocks); `alpha1` makes the three-colour palette's fourth entry
/// transparent black (RGBA_S3TC_DXT1), else opaque black.
export function decodeBC1Block(data: Uint8Array, o: i32, block: Uint8Array, fourColors: bool, alpha1: bool): void {
    const c0 = <i32>data[o] | (<i32>data[o + 1] << 8);
    const c1 = <i32>data[o + 2] | (<i32>data[o + 3] << 8);
    const bits = <u32>data[o + 4] | (<u32>data[o + 5] << 8) | (<u32>data[o + 6] << 16) | (<u32>data[o + 7] << 24);
    const r0 = expand5(c0 >> 11), g0 = expand6((c0 >> 5) & 63), b0 = expand5(c0 & 31);
    const r1 = expand5(c1 >> 11), g1 = expand6((c1 >> 5) & 63), b1 = expand5(c1 & 31);
    const pal = palette;
    pal[0] = r0; pal[1] = g0; pal[2] = b0; pal[3] = 255;
    pal[4] = r1; pal[5] = g1; pal[6] = b1; pal[7] = 255;
    if (fourColors || c0 > c1) {
        pal[8] = (2 * r0 + r1 + 1) / 3; pal[9] = (2 * g0 + g1 + 1) / 3; pal[10] = (2 * b0 + b1 + 1) / 3; pal[11] = 255;
        pal[12] = (r0 + 2 * r1 + 1) / 3; pal[13] = (g0 + 2 * g1 + 1) / 3; pal[14] = (b0 + 2 * b1 + 1) / 3; pal[15] = 255;
    } else {
        pal[8] = (r0 + r1 + 1) >> 1; pal[9] = (g0 + g1 + 1) >> 1; pal[10] = (b0 + b1 + 1) >> 1; pal[11] = 255;
        pal[12] = 0; pal[13] = 0; pal[14] = 0; pal[15] = alpha1 ? 0 : 255;
    }
    for (let k = 0; k < 16; k++) {
        const p = <i32>((bits >> <u32>(2 * k)) & 3) * 4;
        block[k * 4] = <u8>pal[p];
        block[k * 4 + 1] = <u8>pal[p + 1];
        block[k * 4 + 2] = <u8>pal[p + 2];
        block[k * 4 + 3] = <u8>pal[p + 3];
    }
}

const palette = new StaticArray<i32>(16);
const values = new StaticArray<i32>(8);
const valuesF = new StaticArray<f32>(8);

/// The eight values of a BC3 alpha / BC4 block (unsigned), from its two
/// endpoint bytes.
function unsignedPalette(a0: i32, a1: i32): void {
    const v = values;
    v[0] = a0;
    v[1] = a1;
    if (a0 > a1) {
        for (let i = 1; i < 7; i++) v[i + 1] = ((7 - i) * a0 + i * a1 + 3) / 7;
    } else {
        for (let i = 1; i < 5; i++) v[i + 1] = ((5 - i) * a0 + i * a1 + 2) / 5;
        v[6] = 0;
        v[7] = 255;
    }
}

/// Decodes the 8-byte BC3 alpha / BC4 block at `data[o]` into channel `c`
/// of `block` (16 RGBA8 texels).
export function decodeAlphaBlock(data: Uint8Array, o: i32, block: Uint8Array, c: i32): void {
    unsignedPalette(<i32>data[o], <i32>data[o + 1]);
    const lo = <u32>data[o + 2] | (<u32>data[o + 3] << 8) | (<u32>data[o + 4] << 16);
    const hi = <u32>data[o + 5] | (<u32>data[o + 6] << 8) | (<u32>data[o + 7] << 16);
    for (let k = 0; k < 8; k++) block[k * 4 + c] = <u8>values[<i32>((lo >> <u32>(3 * k)) & 7)];
    for (let k = 0; k < 8; k++) block[(k + 8) * 4 + c] = <u8>values[<i32>((hi >> <u32>(3 * k)) & 7)];
}

/// As decodeAlphaBlock for a signed BC4 block: values in [-1, 1].
export function decodeSignedBlock(data: Uint8Array, o: i32, block: Float32Array, c: i32): void {
    let a0 = <i32><i8>data[o], a1 = <i32><i8>data[o + 1];
    if (a0 == -128) a0 = -127;
    if (a1 == -128) a1 = -127;
    const v = valuesF;
    v[0] = <f32>a0;
    v[1] = <f32>a1;
    if (a0 > a1) {
        for (let i = 1; i < 7; i++) v[i + 1] = <f32>((7 - i) * a0 + i * a1) / 7;
    } else {
        for (let i = 1; i < 5; i++) v[i + 1] = <f32>((5 - i) * a0 + i * a1) / 5;
        v[6] = -127;
        v[7] = 127;
    }
    const lo = <u32>data[o + 2] | (<u32>data[o + 3] << 8) | (<u32>data[o + 4] << 16);
    const hi = <u32>data[o + 5] | (<u32>data[o + 6] << 8) | (<u32>data[o + 7] << 16);
    for (let k = 0; k < 8; k++) block[k * 4 + c] = v[<i32>((lo >> <u32>(3 * k)) & 7)] / 127;
    for (let k = 0; k < 8; k++) block[(k + 8) * 4 + c] = v[<i32>((hi >> <u32>(3 * k)) & 7)] / 127;
}

/// BC1 (RGB_S3TC_DXT1 / RGBA_S3TC_DXT1 with `alpha1`), 8 bytes a block.
export function decodeBC1(data: Uint8Array, width: i32, height: i32, out: Uint8Array, alpha1: bool): void {
    const block = new Uint8Array(64);
    let o = 0;
    for (let by = 0; by < height; by += 4) {
        for (let bx = 0; bx < width; bx += 4) {
            decodeBC1Block(data, o, block, false, alpha1);
            storeBlock(out, width, height, bx, by, 4, 4, block);
            o += 8;
        }
    }
}

/// BC2 (RGBA_S3TC_DXT3): explicit 4-bit alpha, then a BC1 colour block.
export function decodeBC2(data: Uint8Array, width: i32, height: i32, out: Uint8Array): void {
    const block = new Uint8Array(64);
    let o = 0;
    for (let by = 0; by < height; by += 4) {
        for (let bx = 0; bx < width; bx += 4) {
            decodeBC1Block(data, o + 8, block, true, false);
            for (let k = 0; k < 16; k++) {
                const a = (<i32>data[o + (k >> 1)] >> ((k & 1) * 4)) & 15;
                block[k * 4 + 3] = <u8>(a * 17);
            }
            storeBlock(out, width, height, bx, by, 4, 4, block);
            o += 16;
        }
    }
}

/// BC3 (RGBA_S3TC_DXT5): a BC4-style alpha block, then a BC1 colour block.
export function decodeBC3(data: Uint8Array, width: i32, height: i32, out: Uint8Array): void {
    const block = new Uint8Array(64);
    let o = 0;
    for (let by = 0; by < height; by += 4) {
        for (let bx = 0; bx < width; bx += 4) {
            decodeBC1Block(data, o + 8, block, true, false);
            decodeAlphaBlock(data, o, block, 3);
            storeBlock(out, width, height, bx, by, 4, 4, block);
            o += 16;
        }
    }
}

/// BC4 (RED_RGTC1) and BC5 (RED_GREEN_RGTC2), unsigned: (r, 0, 0, 1) and
/// (r, g, 0, 1).
export function decodeBC4BC5(data: Uint8Array, width: i32, height: i32, out: Uint8Array, channels: i32): void {
    const block = new Uint8Array(64);
    for (let k = 0; k < 16; k++) {
        block[k * 4 + 1] = 0;
        block[k * 4 + 2] = 0;
        block[k * 4 + 3] = 255;
    }
    const stride = channels * 8;
    let o = 0;
    for (let by = 0; by < height; by += 4) {
        for (let bx = 0; bx < width; bx += 4) {
            for (let c = 0; c < channels; c++) decodeAlphaBlock(data, o + c * 8, block, c);
            storeBlock(out, width, height, bx, by, 4, 4, block);
            o += stride;
        }
    }
}

/// BC4 / BC5 signed (SIGNED_RED_RGTC1, SIGNED_RED_GREEN_RGTC2): floats.
export function decodeBC4BC5Signed(data: Uint8Array, width: i32, height: i32, out: Float32Array, channels: i32): void {
    const block = new Float32Array(64);
    for (let k = 0; k < 16; k++) block[k * 4 + 3] = 1;
    const stride = channels * 8;
    let o = 0;
    for (let by = 0; by < height; by += 4) {
        for (let bx = 0; bx < width; bx += 4) {
            for (let c = 0; c < channels; c++) decodeSignedBlock(data, o + c * 8, block, c);
            storeBlockF(out, width, height, bx, by, 4, 4, block);
            o += stride;
        }
    }
}

// ------------------------------------------------------------------ BC7

// Per mode: subsets, partition bits, rotation bits, index selection bits,
// colour bits, alpha bits, per-endpoint p-bits, per-subset p-bits, index
// bits, second index bits.
const BC7_SUBSETS: StaticArray<u8> = [3, 2, 3, 2, 1, 1, 1, 2];
const BC7_PART_BITS: StaticArray<u8> = [4, 6, 6, 6, 0, 0, 0, 6];
const BC7_ROT_BITS: StaticArray<u8> = [0, 0, 0, 0, 2, 2, 0, 0];
const BC7_ISEL_BITS: StaticArray<u8> = [0, 0, 0, 0, 1, 0, 0, 0];
const BC7_COLOR_BITS: StaticArray<u8> = [4, 6, 5, 7, 5, 7, 7, 5];
const BC7_ALPHA_BITS: StaticArray<u8> = [0, 0, 0, 0, 6, 8, 7, 5];
const BC7_EP_PBITS: StaticArray<u8> = [1, 0, 0, 1, 0, 0, 1, 1];
const BC7_SP_PBITS: StaticArray<u8> = [0, 1, 0, 0, 0, 0, 0, 0];
const BC7_INDEX_BITS: StaticArray<u8> = [3, 3, 2, 2, 2, 2, 4, 2];
const BC7_INDEX2_BITS: StaticArray<u8> = [0, 0, 0, 0, 3, 2, 0, 0];

const BC7_W2: StaticArray<i32> = [0, 21, 43, 64];
const BC7_W3: StaticArray<i32> = [0, 9, 18, 27, 37, 46, 55, 64];
const BC7_W4: StaticArray<i32> = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64];

@inline function bc7Weight(bits: i32, index: i32): i32 {
    return bits == 2 ? BC7_W2[index] : bits == 3 ? BC7_W3[index] : BC7_W4[index];
}

/// `count` bits of the 128-bit block (lo, hi) from bit `pos`.
@inline function bits128(lo: u64, hi: u64, pos: i32, count: i32): i32 {
    if (count == 0) return 0;
    let v: u64;
    if (pos >= 64) v = hi >> <u64>(pos - 64);
    else if (pos + count <= 64) v = lo >> <u64>pos;
    else v = (lo >> <u64>pos) | (hi << <u64>(64 - pos));
    return <i32>(v & ((<u64>1 << <u64>count) - 1));
}

const bc7Endpoints = new StaticArray<i32>(6 * 4 * 2);   // [endpoint][channel]
const bc7Index = new StaticArray<i32>(16);
const bc7Index2 = new StaticArray<i32>(16);

/// Decodes the BC7 block at `data[o]` into `block` (16 RGBA8 texels).
export function decodeBC7Block(data: Uint8Array, o: i32, block: Uint8Array): void {
    let lo: u64 = 0, hi: u64 = 0;
    for (let i = 0; i < 8; i++) {
        lo |= <u64>data[o + i] << <u64>(i * 8);
        hi |= <u64>data[o + 8 + i] << <u64>(i * 8);
    }
    let mode = 0;
    while (mode < 8 && ((lo >> <u64>mode) & 1) == 0) mode++;
    if (mode == 8) {   // reserved: transparent black
        for (let k = 0; k < 64; k++) block[k] = 0;
        return;
    }
    let pos = mode + 1;
    const subsets = <i32>BC7_SUBSETS[mode];
    const partition = bits128(lo, hi, pos, <i32>BC7_PART_BITS[mode]);
    pos += <i32>BC7_PART_BITS[mode];
    const rotation = bits128(lo, hi, pos, <i32>BC7_ROT_BITS[mode]);
    pos += <i32>BC7_ROT_BITS[mode];
    const isel = bits128(lo, hi, pos, <i32>BC7_ISEL_BITS[mode]);
    pos += <i32>BC7_ISEL_BITS[mode];
    const colorBits = <i32>BC7_COLOR_BITS[mode], alphaBits = <i32>BC7_ALPHA_BITS[mode];
    const n = subsets * 2;
    const ep = bc7Endpoints;
    for (let c = 0; c < 3; c++) {
        for (let i = 0; i < n; i++) {
            ep[i * 4 + c] = bits128(lo, hi, pos, colorBits);
            pos += colorBits;
        }
    }
    for (let i = 0; i < n; i++) {
        if (alphaBits > 0) {
            ep[i * 4 + 3] = bits128(lo, hi, pos, alphaBits);
            pos += alphaBits;
        } else {
            ep[i * 4 + 3] = 255;
        }
    }
    // P-bits widen each channel by one bit, then everything expands to 8.
    let cb = colorBits, ab = alphaBits;
    if (BC7_EP_PBITS[mode] != 0 || BC7_SP_PBITS[mode] != 0) {
        const shared = BC7_SP_PBITS[mode] != 0;
        let p = 0;
        for (let i = 0; i < n; i++) {
            if (!shared || (i & 1) == 0) {
                p = bits128(lo, hi, pos, 1);
                pos++;
            }
            for (let c = 0; c < 3; c++) ep[i * 4 + c] = (ep[i * 4 + c] << 1) | p;
            if (alphaBits > 0) ep[i * 4 + 3] = (ep[i * 4 + 3] << 1) | p;
        }
        cb++;
        if (alphaBits > 0) ab++;
    }
    for (let i = 0; i < n; i++) {
        for (let c = 0; c < 3; c++) {
            const v = ep[i * 4 + c] << (8 - cb);
            ep[i * 4 + c] = v | (v >> cb);
        }
        if (alphaBits > 0) {
            const v = ep[i * 4 + 3] << (8 - ab);
            ep[i * 4 + 3] = v | (v >> ab);
        }
    }
    // Indices: each subset's anchor texel has one bit fewer.
    let anchor1 = 16, anchor2 = 16;
    if (subsets == 2) anchor1 = <i32>BC7_A2[partition];
    else if (subsets == 3) {
        anchor1 = <i32>BC7_A3A[partition];
        anchor2 = <i32>BC7_A3B[partition];
    }
    const ib = <i32>BC7_INDEX_BITS[mode];
    for (let k = 0; k < 16; k++) {
        const count = k == 0 || k == anchor1 || k == anchor2 ? ib - 1 : ib;
        bc7Index[k] = bits128(lo, hi, pos, count);
        pos += count;
    }
    const ib2 = <i32>BC7_INDEX2_BITS[mode];
    if (ib2 > 0) {
        for (let k = 0; k < 16; k++) {
            const count = k == 0 ? ib2 - 1 : ib2;
            bc7Index2[k] = bits128(lo, hi, pos, count);
            pos += count;
        }
    }
    for (let k = 0; k < 16; k++) {
        const s = subsets == 1 ? 0 : subsets == 2 ? <i32>BC7_P2[partition * 16 + k] : <i32>BC7_P3[partition * 16 + k];
        const e0 = s * 8, e1 = s * 8 + 4;
        let wc: i32, wa: i32;
        if (ib2 == 0) {
            wc = bc7Weight(ib, bc7Index[k]);
            wa = wc;
        } else if (isel == 0) {
            wc = bc7Weight(ib, bc7Index[k]);
            wa = bc7Weight(ib2, bc7Index2[k]);
        } else {
            wc = bc7Weight(ib2, bc7Index2[k]);
            wa = bc7Weight(ib, bc7Index[k]);
        }
        let r = ((64 - wc) * ep[e0] + wc * ep[e1] + 32) >> 6;
        let g = ((64 - wc) * ep[e0 + 1] + wc * ep[e1 + 1] + 32) >> 6;
        let b = ((64 - wc) * ep[e0 + 2] + wc * ep[e1 + 2] + 32) >> 6;
        let a = ((64 - wa) * ep[e0 + 3] + wa * ep[e1 + 3] + 32) >> 6;
        if (rotation == 1) { const t = r; r = a; a = t; }
        else if (rotation == 2) { const t = g; g = a; a = t; }
        else if (rotation == 3) { const t = b; b = a; a = t; }
        block[k * 4] = <u8>r;
        block[k * 4 + 1] = <u8>g;
        block[k * 4 + 2] = <u8>b;
        block[k * 4 + 3] = <u8>a;
    }
}

/// BC7 (RGBA_BPTC), 16 bytes a block.
export function decodeBC7(data: Uint8Array, width: i32, height: i32, out: Uint8Array): void {
    const block = new Uint8Array(64);
    let o = 0;
    for (let by = 0; by < height; by += 4) {
        for (let bx = 0; bx < width; bx += 4) {
            decodeBC7Block(data, o, block);
            storeBlock(out, width, height, bx, by, 4, 4, block);
            o += 16;
        }
    }
}

// The subset of each texel, for the 64 two-subset and 64 three-subset
// partitions, and the anchor texel of subset 1 (two subsets) and of
// subsets 1 and 2 (three subsets); subset 0's anchor is texel 0.
const BC7_P2: StaticArray<u8> = [
    0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1,
    0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1,
    0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1,
    0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1,
    0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1,
    0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 1,
    0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0,
    0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0,
    0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0,
    0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1,
    0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0,
    0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0,
    0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0,
    0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0,
    0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0,
    0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0,
    0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0,
    0, 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
    0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1,
    0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0,
    0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0,
    0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0,
    0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0,
    0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1,
    0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1,
    0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 1, 0,
    0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 0, 0, 0,
    0, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0, 0,
    0, 0, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0, 0,
    0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0,
    0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1,
    0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1,
    0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0,
    0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
    0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0,
    0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0,
    0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1,
    0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0,
    0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0,
    0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 1,
    0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1,
    0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1,
    0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1,
    0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0,
    0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0,
    0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1,
];
const BC7_P3: StaticArray<u8> = [
    0, 0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 1, 2, 2, 2, 2,
    0, 0, 0, 1, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 2, 1,
    0, 0, 0, 0, 2, 0, 0, 1, 2, 2, 1, 1, 2, 2, 1, 1,
    0, 2, 2, 2, 0, 0, 2, 2, 0, 0, 1, 1, 0, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2,
    0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 2, 2, 0, 0, 2, 2,
    0, 0, 2, 2, 0, 0, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2,
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2,
    0, 1, 1, 2, 0, 1, 1, 2, 0, 1, 1, 2, 0, 1, 1, 2,
    0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 2,
    0, 0, 1, 1, 0, 1, 1, 2, 1, 1, 2, 2, 1, 2, 2, 2,
    0, 0, 1, 1, 2, 0, 0, 1, 2, 2, 0, 0, 2, 2, 2, 0,
    0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 2, 1, 1, 2, 2,
    0, 1, 1, 1, 0, 0, 1, 1, 2, 0, 0, 1, 2, 2, 0, 0,
    0, 0, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2,
    0, 0, 2, 2, 0, 0, 2, 2, 0, 0, 2, 2, 1, 1, 1, 1,
    0, 1, 1, 1, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2,
    0, 0, 0, 1, 0, 0, 0, 1, 2, 2, 2, 1, 2, 2, 2, 1,
    0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 2, 2, 0, 1, 2, 2,
    0, 0, 0, 0, 1, 1, 0, 0, 2, 2, 1, 0, 2, 2, 1, 0,
    0, 1, 2, 2, 0, 1, 2, 2, 0, 0, 1, 1, 0, 0, 0, 0,
    0, 0, 1, 2, 0, 0, 1, 2, 1, 1, 2, 2, 2, 2, 2, 2,
    0, 1, 1, 0, 1, 2, 2, 1, 1, 2, 2, 1, 0, 1, 1, 0,
    0, 0, 0, 0, 0, 1, 1, 0, 1, 2, 2, 1, 1, 2, 2, 1,
    0, 0, 2, 2, 1, 1, 0, 2, 1, 1, 0, 2, 0, 0, 2, 2,
    0, 1, 1, 0, 0, 1, 1, 0, 2, 0, 0, 2, 2, 2, 2, 2,
    0, 0, 1, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 0, 1, 1,
    0, 0, 0, 0, 2, 0, 0, 0, 2, 2, 1, 1, 2, 2, 2, 1,
    0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 2, 2, 2,
    0, 2, 2, 2, 0, 0, 2, 2, 0, 0, 1, 2, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 0, 1, 2, 0, 0, 2, 2, 0, 2, 2, 2,
    0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0,
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 0, 0, 0, 0,
    0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0,
    0, 1, 2, 0, 2, 0, 1, 2, 1, 2, 0, 1, 0, 1, 2, 0,
    0, 0, 1, 1, 2, 2, 0, 0, 1, 1, 2, 2, 0, 0, 1, 1,
    0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 0, 0, 0, 0, 1, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 2, 1, 2, 1, 2, 1,
    0, 0, 2, 2, 1, 1, 2, 2, 0, 0, 2, 2, 1, 1, 2, 2,
    0, 0, 2, 2, 0, 0, 1, 1, 0, 0, 2, 2, 0, 0, 1, 1,
    0, 2, 2, 0, 1, 2, 2, 1, 0, 2, 2, 0, 1, 2, 2, 1,
    0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 0, 1, 0, 1,
    0, 0, 0, 0, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2,
    0, 2, 2, 2, 0, 1, 1, 1, 0, 2, 2, 2, 0, 1, 1, 1,
    0, 0, 0, 2, 1, 1, 1, 2, 0, 0, 0, 2, 1, 1, 1, 2,
    0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2,
    0, 2, 2, 2, 0, 1, 1, 1, 0, 1, 1, 1, 0, 2, 2, 2,
    0, 0, 0, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0, 0, 2,
    0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 1, 2,
    0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 2, 2, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 2, 2,
    0, 0, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2, 0, 0, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2,
    0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1,
    0, 2, 2, 2, 1, 2, 2, 2, 0, 2, 2, 2, 1, 2, 2, 2,
    0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 1, 1, 1, 2, 0, 1, 1, 2, 2, 0, 1, 2, 2, 2, 0,
];
const BC7_A2: StaticArray<u8> = [
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2,
    15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6,
    6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15,
];
const BC7_A3A: StaticArray<u8> = [
    3, 3, 15, 15, 8, 3, 15, 15, 8, 8, 6, 6, 6, 5, 3, 3,
    3, 3, 8, 15, 3, 3, 6, 10, 5, 8, 8, 6, 8, 5, 15, 15,
    8, 15, 3, 5, 6, 10, 8, 15, 15, 3, 15, 5, 15, 15, 15, 15,
    3, 15, 5, 5, 5, 8, 5, 10, 5, 10, 8, 13, 15, 12, 3, 3,
];
const BC7_A3B: StaticArray<u8> = [
    15, 8, 8, 3, 15, 15, 3, 8, 15, 15, 15, 15, 15, 15, 15, 8,
    15, 8, 15, 3, 15, 8, 15, 8, 3, 15, 6, 10, 15, 15, 10, 8,
    15, 3, 15, 10, 10, 8, 9, 10, 6, 15, 8, 15, 3, 6, 6, 8,
    15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3, 15, 15, 8,
];
