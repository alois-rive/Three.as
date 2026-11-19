// A CPU decoder for ASTC LDR 2D blocks, every footprint from 4x4 to 12x12:
// void-extent blocks, block modes and weight grids (with bilinear weight
// infill), the integer sequence encoding (bits, trits, quints), one to four
// partitions (the partition hash), dual weight planes, and the LDR colour
// endpoint modes (0, 1, 4, 5, 6, 8, 9, 10, 12, 13). Written from the
// Khronos Data Format Specification 1.3, section "ASTC" (its decoding
// procedure, tables and pseudocode: block modes, integer sequence
// encoding, unquantization, endpoint decoding, select_partition, weight
// infill), and checked texel for texel against a GPU's decoder
// (tools/make_texture_vectors.py). No astc-encoder code is used.
// TextureDecoders calls it when the device cannot sample ASTC (ThreeAS
// addition).
//
// Output is RGBA8, rows top first. With `srgb`, endpoints expand to 16 bits
// as (e << 8) | 0x80 and the result is its top 8 bits, as the
// specification's sRGB decode; otherwise they expand as e * 257 and the
// 16-bit result rounds to 8 bits (UNORM16 to UNORM8). Blocks the LDR
// profile cannot decode (HDR endpoint modes, HDR void extents, reserved or
// over-sized encodings) decode to the error colour, magenta. 3D footprints
// and the HDR profile are not supported.

// Integer sequence encoding: bits, trits and quints of each of the 21
// ranges (2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64, 80, 96,
// 128, 160, 192, 256).
const Q_BITS: StaticArray<i32> = [1, 0, 2, 0, 1, 3, 1, 2, 4, 2, 3, 5, 3, 4, 6, 4, 5, 7, 5, 6, 8];
const Q_TRITS: StaticArray<i32> = [0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0];
const Q_QUINTS: StaticArray<i32> = [0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0];
const QUANT_6 = 4;

/// Bits the integer sequence encoding of `count` values of range `q` takes.
export function iseBits(count: i32, q: i32): i32 {
    let bits = Q_BITS[q] * count;
    if (Q_TRITS[q] != 0) bits += (8 * count + 4) / 5;
    if (Q_QUINTS[q] != 0) bits += (7 * count + 2) / 3;
    return bits;
}

// Trit and quint tables: the five trits of each 8-bit T and the three
// quints of each 7-bit Q, from the specification's decoding procedure.
const TRITS = new StaticArray<u8>(256 * 5);
const QUINTS = new StaticArray<u8>(128 * 3);
// Unquantized colour values (0..255) per range, 256 entries a range, and
// weights (0..64) for the 12 weight ranges, 32 entries a range.
const COLOR_UNQ = new StaticArray<u8>(21 * 256);
const WEIGHT_UNQ = new StaticArray<u8>(12 * 32);
let tablesReady = false;

function tb(v: i32, i: i32): i32 { return (v >> i) & 1; }

function buildTables(): void {
    for (let T = 0; T < 256; T++) {
        let C: i32, t4: i32, t3: i32, t2: i32, t1: i32, t0: i32;
        if (((T >> 2) & 7) == 7) {
            C = (((T >> 5) & 7) << 2) | (T & 3);
            t4 = 2;
            t3 = 2;
        } else {
            C = T & 31;
            if (((T >> 5) & 3) == 3) {
                t4 = 2;
                t3 = tb(T, 7);
            } else {
                t4 = tb(T, 7);
                t3 = (T >> 5) & 3;
            }
        }
        if ((C & 3) == 3) {
            t2 = 2;
            t1 = tb(C, 4);
            t0 = (tb(C, 3) << 1) | (tb(C, 2) & ~tb(C, 3) & 1);
        } else if (((C >> 2) & 3) == 3) {
            t2 = 2;
            t1 = 2;
            t0 = C & 3;
        } else {
            t2 = tb(C, 4);
            t1 = (C >> 2) & 3;
            t0 = (tb(C, 1) << 1) | (tb(C, 0) & ~tb(C, 1) & 1);
        }
        TRITS[T * 5] = <u8>t0; TRITS[T * 5 + 1] = <u8>t1; TRITS[T * 5 + 2] = <u8>t2;
        TRITS[T * 5 + 3] = <u8>t3; TRITS[T * 5 + 4] = <u8>t4;
    }
    for (let Q = 0; Q < 128; Q++) {
        let q2: i32, q1: i32, q0: i32;
        if (((Q >> 1) & 3) == 3 && ((Q >> 5) & 3) == 0) {
            q2 = (tb(Q, 0) << 2) | ((tb(Q, 4) & ~tb(Q, 0) & 1) << 1) | (tb(Q, 3) & ~tb(Q, 0) & 1);
            q1 = 4;
            q0 = 4;
        } else {
            let C: i32;
            if (((Q >> 1) & 3) == 3) {
                q2 = 4;
                C = (((Q >> 3) & 3) << 3) | ((~(Q >> 5) & 3) << 1) | (Q & 1);
            } else {
                q2 = (Q >> 5) & 3;
                C = Q & 31;
            }
            if ((C & 7) == 5) {
                q1 = 4;
                q0 = (C >> 3) & 3;
            } else {
                q1 = (C >> 3) & 3;
                q0 = C & 7;
            }
        }
        QUINTS[Q * 3] = <u8>q0; QUINTS[Q * 3 + 1] = <u8>q1; QUINTS[Q * 3 + 2] = <u8>q2;
    }
    // Colour unquantization.
    for (let q = 0; q < 21; q++) {
        const bits = Q_BITS[q], trits = Q_TRITS[q], quints = Q_QUINTS[q];
        const range = (trits != 0 ? 3 : quints != 0 ? 5 : 1) << bits;
        for (let v = 0; v < range; v++) {
            let out: i32;
            if (trits == 0 && quints == 0) {
                // Bit replication to 8 bits.
                out = 0;
                let filled = 0;
                while (filled < 8) {
                    out = (out << bits) | v;
                    filled += bits;
                }
                out >>= filled - 8;
            } else {
                const D = v >> bits, m = v & ((1 << bits) - 1);
                const A = (m & 1) != 0 ? 0x1ff : 0;
                let B = 0, C = 0;
                const x = m >> 1;
                if (trits != 0) {
                    if (bits == 1) { C = 204; }
                    else if (bits == 2) { C = 93; B = x * 0x116; }
                    else if (bits == 3) { C = 44; B = (x << 7) | (x << 2) | x; }
                    else if (bits == 4) { C = 22; B = (x << 6) | x; }
                    else if (bits == 5) { C = 11; B = (x << 5) | (x >> 2); }
                    else { C = 5; B = (x << 4) | (x >> 4); }
                } else {
                    if (bits == 1) { C = 113; }
                    else if (bits == 2) { C = 54; B = x * 0x10c; }
                    else if (bits == 3) { C = 26; B = (x << 7) | (x << 1) | (x >> 1); }
                    else if (bits == 4) { C = 13; B = (x << 6) | (x >> 1); }
                    else { C = 6; B = (x << 5) | (x >> 3); }
                }
                if (bits == 0) {
                    out = 0;   // ranges 3 and 5 hold no colours (a range of at least 6 is required)
                } else {
                    let T = D * C + B;
                    T ^= A;
                    out = (A & 0x80) | (T >> 2);
                }
            }
            COLOR_UNQ[q * 256 + v] = <u8>out;
        }
    }
    // Weight unquantization (ranges 2 to 32), to 0..64.
    for (let q = 0; q < 12; q++) {
        const bits = Q_BITS[q], trits = Q_TRITS[q], quints = Q_QUINTS[q];
        const range = (trits != 0 ? 3 : quints != 0 ? 5 : 1) << bits;
        for (let v = 0; v < range; v++) {
            let out: i32;
            if (trits == 0 && quints == 0) {
                out = 0;
                let filled = 0;
                while (filled < 6) {
                    out = (out << bits) | v;
                    filled += bits;
                }
                out >>= filled - 6;
            } else if (bits == 0) {
                // Ranges 3 and 5: 0 32 63 and 0 16 32 47 63.
                out = trits != 0 ? (v == 0 ? 0 : v == 1 ? 32 : 63) : (v == 3 ? 47 : v == 4 ? 63 : v * 16);
            } else {
                const D = v >> bits, m = v & ((1 << bits) - 1);
                const A = (m & 1) != 0 ? 0x7f : 0;
                let B = 0, C = 0;
                const x = m >> 1;
                if (trits != 0) {
                    if (bits == 1) { C = 50; }
                    else if (bits == 2) { C = 23; B = x * 0x45; }
                    else { C = 11; B = (x << 5) | x; }
                } else {
                    if (bits == 1) { C = 28; }
                    else { C = 13; B = x * 0x42; }
                }
                let T = D * C + B;
                T ^= A;
                out = (A & 0x20) | (T >> 2);
            }
            if (out > 32) out++;
            WEIGHT_UNQ[q * 32 + v] = <u8>out;
        }
    }
    tablesReady = true;
}

/// The unquantized colour value `v` of range `q` (0..255).
export function unquantizeColor(q: i32, v: i32): i32 {
    if (!tablesReady) buildTables();
    return <i32>COLOR_UNQ[q * 256 + v];
}

/// The unquantized weight `v` of range `q` (0..64).
export function unquantizeWeight(q: i32, v: i32): i32 {
    if (!tablesReady) buildTables();
    return <i32>WEIGHT_UNQ[q * 32 + v];
}

// ------------------------------------------------------------ bit streams

/// `count` (at most 32) bits of the 128-bit value (lo, hi) from `pos`; bits
/// at or past `end` read as 0.
@inline function readBits(lo: u64, hi: u64, pos: i32, count: i32, end: i32): i32 {
    if (count <= 0 || pos >= end) return 0;
    if (pos + count > end) count = end - pos;
    let v: u64;
    if (pos >= 64) v = hi >> <u64>(pos - 64);
    else if (pos + count <= 64) v = lo >> <u64>pos;
    else v = (lo >> <u64>pos) | (hi << <u64>(64 - pos));
    return <i32>(v & ((<u64>1 << <u64>count) - 1));
}

function reverse64(v: u64): u64 {
    v = ((v >> 1) & 0x5555555555555555) | ((v & 0x5555555555555555) << 1);
    v = ((v >> 2) & 0x3333333333333333) | ((v & 0x3333333333333333) << 2);
    v = ((v >> 4) & 0x0f0f0f0f0f0f0f0f) | ((v & 0x0f0f0f0f0f0f0f0f) << 4);
    v = ((v >> 8) & 0x00ff00ff00ff00ff) | ((v & 0x00ff00ff00ff00ff) << 8);
    v = ((v >> 16) & 0x0000ffff0000ffff) | ((v & 0x0000ffff0000ffff) << 16);
    return (v >> 32) | (v << 32);
}

/// Decodes `count` values of range `q` from bit `start` of (lo, hi) into
/// `out` (each value is trit-or-quint << bits | bits).
function decodeISE(lo: u64, hi: u64, start: i32, count: i32, q: i32, out: StaticArray<i32>): void {
    const bits = Q_BITS[q];
    const end = start + iseBits(count, q);
    let pos = start;
    if (Q_TRITS[q] != 0) {
        for (let i = 0; i < count; i += 5) {
            const m0 = readBits(lo, hi, pos, bits, end); pos += bits;
            let T = readBits(lo, hi, pos, 2, end); pos += 2;
            const m1 = readBits(lo, hi, pos, bits, end); pos += bits;
            T |= readBits(lo, hi, pos, 2, end) << 2; pos += 2;
            const m2 = readBits(lo, hi, pos, bits, end); pos += bits;
            T |= readBits(lo, hi, pos, 1, end) << 4; pos += 1;
            const m3 = readBits(lo, hi, pos, bits, end); pos += bits;
            T |= readBits(lo, hi, pos, 2, end) << 5; pos += 2;
            const m4 = readBits(lo, hi, pos, bits, end); pos += bits;
            T |= readBits(lo, hi, pos, 1, end) << 7; pos += 1;
            const t = T * 5;
            if (i < count) out[i] = (<i32>TRITS[t] << bits) | m0;
            if (i + 1 < count) out[i + 1] = (<i32>TRITS[t + 1] << bits) | m1;
            if (i + 2 < count) out[i + 2] = (<i32>TRITS[t + 2] << bits) | m2;
            if (i + 3 < count) out[i + 3] = (<i32>TRITS[t + 3] << bits) | m3;
            if (i + 4 < count) out[i + 4] = (<i32>TRITS[t + 4] << bits) | m4;
        }
    } else if (Q_QUINTS[q] != 0) {
        for (let i = 0; i < count; i += 3) {
            const m0 = readBits(lo, hi, pos, bits, end); pos += bits;
            let Q = readBits(lo, hi, pos, 3, end); pos += 3;
            const m1 = readBits(lo, hi, pos, bits, end); pos += bits;
            Q |= readBits(lo, hi, pos, 2, end) << 3; pos += 2;
            const m2 = readBits(lo, hi, pos, bits, end); pos += bits;
            Q |= readBits(lo, hi, pos, 2, end) << 5; pos += 2;
            const t = Q * 3;
            if (i < count) out[i] = (<i32>QUINTS[t] << bits) | m0;
            if (i + 1 < count) out[i + 1] = (<i32>QUINTS[t + 1] << bits) | m1;
            if (i + 2 < count) out[i + 2] = (<i32>QUINTS[t + 2] << bits) | m2;
        }
    } else {
        for (let i = 0; i < count; i++) {
            out[i] = readBits(lo, hi, pos, bits, end);
            pos += bits;
        }
    }
}

// ------------------------------------------------------------ partitions

function hash52(p: u32): u32 {
    p ^= p >> 15;
    p -= p << 17;
    p += p << 7;
    p += p << 4;
    p ^= p >> 5;
    p += p << 16;
    p ^= p >> 7;
    p ^= p >> 3;
    p ^= p << 6;
    p ^= p >> 17;
    return p;
}

// The specification's select_partition, split in two: the per-block part
// (the hash of the seed: four multipliers pairs and offsets) and the
// per-texel part.
const partitionCoeffs = new StaticArray<i32>(12);   // (x, y multipliers, offset) for a, b, c, d

function preparePartition(seed: i32, partitions: i32): void {
    seed += (partitions - 1) * 1024;
    const rnum = hash52(<u32>seed);
    let s1 = <i32>(rnum & 0xf), s2 = <i32>((rnum >> 4) & 0xf), s3 = <i32>((rnum >> 8) & 0xf);
    let s4 = <i32>((rnum >> 12) & 0xf), s5 = <i32>((rnum >> 16) & 0xf), s6 = <i32>((rnum >> 20) & 0xf);
    let s7 = <i32>((rnum >> 24) & 0xf), s8 = <i32>((rnum >> 28) & 0xf);
    // The z multipliers (seeds 9 to 12) only matter in 3D blocks.
    s1 *= s1; s2 *= s2; s3 *= s3; s4 *= s4; s5 *= s5; s6 *= s6; s7 *= s7; s8 *= s8;
    let sh1: i32, sh2: i32;
    if ((seed & 1) != 0) {
        sh1 = (seed & 2) != 0 ? 4 : 5;
        sh2 = partitions == 3 ? 6 : 5;
    } else {
        sh1 = partitions == 3 ? 6 : 5;
        sh2 = (seed & 2) != 0 ? 4 : 5;
    }
    const k = partitionCoeffs;
    k[0] = s1 >> sh1; k[1] = s2 >> sh2; k[2] = <i32>(rnum >> 14);
    k[3] = s3 >> sh1; k[4] = s4 >> sh2; k[5] = <i32>(rnum >> 10);
    k[6] = s5 >> sh1; k[7] = s6 >> sh2; k[8] = <i32>(rnum >> 6);
    k[9] = s7 >> sh1; k[10] = s8 >> sh2; k[11] = <i32>(rnum >> 2);
}

@inline function partitionOf(x: i32, y: i32, partitions: i32): i32 {
    const k = partitionCoeffs;
    const a = (k[0] * x + k[1] * y + k[2]) & 0x3f;
    const b = (k[3] * x + k[4] * y + k[5]) & 0x3f;
    const c = partitions < 3 ? 0 : (k[6] * x + k[7] * y + k[8]) & 0x3f;
    const d = partitions < 4 ? 0 : (k[9] * x + k[10] * y + k[11]) & 0x3f;
    if (a >= b && a >= c && a >= d) return 0;
    if (b >= c && b >= d) return 1;
    if (c >= d) return 2;
    return 3;
}

/// The partition of texel (x, y) in a block of `partitions` partitions
/// with partition index `seed` (the specification's select_partition, 2D).
export function selectPartition(seed: i32, x: i32, y: i32, partitions: i32, smallBlock: bool): i32 {
    preparePartition(seed, partitions);
    return smallBlock ? partitionOf(x << 1, y << 1, partitions) : partitionOf(x, y, partitions);
}

// ------------------------------------------------------------ endpoints

@inline function clampByte(v: i32): i32 { return v < 0 ? 0 : v > 255 ? 255 : v; }

/// Writes endpoint pair `p` (8 values: e0 rgba, e1 rgba) of colour
/// endpoint mode `cem` from the unquantized values v[o..]. An HDR mode
/// gives both endpoints the error colour: the texels of that partition
/// decode magenta, the others as usual.
function decodeEndpoints(cem: i32, v: StaticArray<i32>, o: i32, e: StaticArray<i32>, p: i32): void {
    const b = p * 8;
    let v0 = v[o], v1 = v[o + 1], v2 = 0, v3 = 0, v4 = 0, v5 = 0, v6 = 0, v7 = 0;
    if (cem >= 4) { v2 = v[o + 2]; v3 = v[o + 3]; }
    if (cem >= 8) { v4 = v[o + 4]; v5 = v[o + 5]; }
    if (cem >= 12) { v6 = v[o + 6]; v7 = v[o + 7]; }
    let r0 = 0, g0 = 0, b0 = 0, a0 = 255, r1 = 0, g1 = 0, b1 = 0, a1 = 255;
    switch (cem) {
        case 0: {   // luminance, direct
            r0 = g0 = b0 = v0;
            r1 = g1 = b1 = v1;
            break;
        }
        case 1: {   // luminance, base + offset
            const l0 = (v0 >> 2) | (v1 & 0xc0);
            const l1 = min<i32>(l0 + (v1 & 0x3f), 255);
            r0 = g0 = b0 = l0;
            r1 = g1 = b1 = l1;
            break;
        }
        case 4: {   // luminance + alpha, direct
            r0 = g0 = b0 = v0;
            r1 = g1 = b1 = v1;
            a0 = v2;
            a1 = v3;
            break;
        }
        case 5: {   // luminance + alpha, base + offset
            const t0 = transferBase(v1, v0), d0 = transferOffset(v1);
            const t2 = transferBase(v3, v2), d2 = transferOffset(v3);
            r0 = g0 = b0 = t0;
            r1 = g1 = b1 = clampByte(t0 + d0);
            a0 = t2;
            a1 = clampByte(t2 + d2);
            break;
        }
        case 6: {   // RGB, base + scale
            r0 = (v0 * v3) >> 8; g0 = (v1 * v3) >> 8; b0 = (v2 * v3) >> 8;
            r1 = v0; g1 = v1; b1 = v2;
            break;
        }
        case 10: {   // RGB base + scale, plus two alphas
            r0 = (v0 * v3) >> 8; g0 = (v1 * v3) >> 8; b0 = (v2 * v3) >> 8;
            r1 = v0; g1 = v1; b1 = v2;
            a0 = v4;
            a1 = v5;
            break;
        }
        case 8:
        case 12: {   // RGB(A), direct
            if (cem == 12) { a0 = v6; a1 = v7; }
            if (v1 + v3 + v5 >= v0 + v2 + v4) {
                r0 = v0; g0 = v2; b0 = v4;
                r1 = v1; g1 = v3; b1 = v5;
            } else {
                // Blue contraction, endpoints swapped.
                r0 = (v1 + v5) >> 1; g0 = (v3 + v5) >> 1; b0 = v5;
                r1 = (v0 + v4) >> 1; g1 = (v2 + v4) >> 1; b1 = v4;
                const t = a0; a0 = a1; a1 = t;
            }
            break;
        }
        case 9:
        case 13: {   // RGB(A), base + offset
            const br = transferBase(v1, v0), dr = transferOffset(v1);
            const bg = transferBase(v3, v2), dg = transferOffset(v3);
            const bb = transferBase(v5, v4), db = transferOffset(v5);
            let ba = 255, da = 0;
            if (cem == 13) { ba = transferBase(v7, v6); da = transferOffset(v7); }
            if (dr + dg + db >= 0) {
                r0 = br; g0 = bg; b0 = bb; a0 = ba;
                r1 = br + dr; g1 = bg + dg; b1 = bb + db; a1 = ba + da;
            } else {
                r0 = (br + dr + bb + db) >> 1; g0 = (bg + dg + bb + db) >> 1; b0 = bb + db; a0 = ba + da;
                r1 = (br + bb) >> 1; g1 = (bg + bb) >> 1; b1 = bb; a1 = ba;
            }
            r0 = clampByte(r0); g0 = clampByte(g0); b0 = clampByte(b0); a0 = clampByte(a0);
            r1 = clampByte(r1); g1 = clampByte(g1); b1 = clampByte(b1); a1 = clampByte(a1);
            break;
        }
        default:   // 2, 3, 7, 11, 14, 15: HDR, the error colour in the LDR profile
            r0 = r1 = 255; g0 = g1 = 0; b0 = b1 = 255; a0 = a1 = 255;
    }
    e[b] = r0; e[b + 1] = g0; e[b + 2] = b0; e[b + 3] = a0;
    e[b + 4] = r1; e[b + 5] = g1; e[b + 6] = b1; e[b + 7] = a1;
}

// bit_transfer_signed(a, b): the base takes a's top bit under b's top 7;
// the offset is a's next 6 bits, signed.
@inline function transferBase(a: i32, b: i32): i32 { return (b >> 1) | (a & 0x80); }
@inline function transferOffset(a: i32): i32 {
    const d = (a >> 1) & 0x3f;
    return (d & 0x20) != 0 ? d - 0x40 : d;
}

// ------------------------------------------------------------ blocks

/// What a block mode says: weight grid size, dual plane, weight range.
class BlockMode {
    xw: i32 = 0;
    yw: i32 = 0;
    dual: bool = false;
    q: i32 = 0;
}

const mode = new BlockMode();

/// Reads the 11-bit block mode into `mode`; false when reserved.
function decodeBlockMode(bm: i32, m: BlockMode): bool {
    let r = (bm >> 4) & 1;
    let h = (bm >> 9) & 1;
    let d = (bm >> 10) & 1;
    const a = (bm >> 5) & 3;
    let x = 0, y = 0;
    if ((bm & 3) != 0) {
        r |= (bm & 3) << 1;
        let b = (bm >> 7) & 3;
        switch ((bm >> 2) & 3) {
            case 0: x = b + 4; y = a + 2; break;
            case 1: x = b + 8; y = a + 2; break;
            case 2: x = a + 2; y = b + 8; break;
            default:
                b &= 1;
                if ((bm & 0x100) != 0) { x = b + 2; y = a + 2; }
                else { x = a + 2; y = b + 6; }
        }
    } else {
        r |= ((bm >> 2) & 3) << 1;
        if (((bm >> 2) & 3) == 0) return false;
        const b = (bm >> 9) & 3;
        switch ((bm >> 7) & 3) {
            case 0: x = 12; y = a + 2; break;
            case 1: x = a + 2; y = 12; break;
            case 2:
                x = a + 6;
                y = b + 6;
                d = 0;
                h = 0;
                break;
            default:
                if (a == 0) { x = 6; y = 10; }
                else if (a == 1) { x = 10; y = 6; }
                else return false;
        }
    }
    m.xw = x;
    m.yw = y;
    m.dual = d != 0;
    m.q = r - 2 + 6 * h;
    return true;
}

const ERROR_R = 255, ERROR_G = 0, ERROR_B = 255, ERROR_A = 255;

function errorBlock(block: Uint8Array, n: i32): void {
    for (let i = 0; i < n; i++) {
        block[i * 4] = <u8>ERROR_R;
        block[i * 4 + 1] = <u8>ERROR_G;
        block[i * 4 + 2] = <u8>ERROR_B;
        block[i * 4 + 3] = <u8>ERROR_A;
    }
}

/// A UNORM16 value as the 8-bit result: its top 8 bits for sRGB, else
/// rounded.
@inline function to8(c: i32, srgb: bool): i32 {
    return srgb ? c >> 8 : (c * 255 + 32767) / 65535;
}

const iseValues = new StaticArray<i32>(64);
const colorValues = new StaticArray<i32>(18);
const endpoints = new StaticArray<i32>(32);
const endpoints16 = new StaticArray<i32>(32);
const gridWeights = new StaticArray<i32>(64 * 2 + 32);   // padded: infill may read one past the grid
const cems = new StaticArray<i32>(4);

/// Decodes the ASTC block at `data[o]` (bw x bh texels) into `block`
/// (bw * bh RGBA8 texels, rows first).
export function decodeASTCBlock(data: Uint8Array, o: i32, bw: i32, bh: i32, srgb: bool, block: Uint8Array): void {
    if (!tablesReady) buildTables();
    const texels = bw * bh;
    let lo: u64 = 0, hi: u64 = 0;
    for (let i = 0; i < 8; i++) {
        lo |= <u64>data[o + i] << <u64>(i * 8);
        hi |= <u64>data[o + 8 + i] << <u64>(i * 8);
    }
    // Void extent: one colour for the whole block.
    if ((lo & 0x1ff) == 0x1fc) {
        const hdr = ((lo >> 9) & 1) != 0;
        const s0 = <i32>((lo >> 12) & 0x1fff), s1 = <i32>((lo >> 25) & 0x1fff);
        const t0 = <i32>((lo >> 38) & 0x1fff), t1 = <i32>((lo >> 51) & 0x1fff);
        const allOnes = s0 == 0x1fff && s1 == 0x1fff && t0 == 0x1fff && t1 == 0x1fff;
        if (hdr || ((lo >> 10) & 3) != 3 || (!allOnes && (s0 >= s1 || t0 >= t1))) {
            errorBlock(block, texels);
            return;
        }
        const r = to8(<i32>(hi & 0xffff), srgb), g = to8(<i32>((hi >> 16) & 0xffff), srgb);
        const b = to8(<i32>((hi >> 32) & 0xffff), srgb), a = to8(<i32>((hi >> 48) & 0xffff), srgb);
        for (let i = 0; i < texels; i++) {
            block[i * 4] = <u8>r; block[i * 4 + 1] = <u8>g; block[i * 4 + 2] = <u8>b; block[i * 4 + 3] = <u8>a;
        }
        return;
    }
    const m = mode;
    if (!decodeBlockMode(<i32>(lo & 0x7ff), m) || m.xw > bw || m.yw > bh) {
        errorBlock(block, texels);
        return;
    }
    const partitions = <i32>((lo >> 11) & 3) + 1;
    const dual = m.dual;
    const weightCount = m.xw * m.yw * (dual ? 2 : 1);
    const weightBits = iseBits(weightCount, m.q);
    if (weightCount > 64 || weightBits < 24 || weightBits > 96 || (dual && partitions == 4)) {
        errorBlock(block, texels);
        return;
    }
    // Colour endpoint modes.
    let below = 128 - weightBits;   // where the bits under the weights end
    let extraCemBits = 0;
    let seed = 0;
    let colorStart = 17;
    if (partitions == 1) {
        cems[0] = <i32>((lo >> 13) & 0xf);
    } else {
        seed = <i32>((lo >> 13) & 0x3ff);
        colorStart = 29;
        const sel = <i32>((lo >> 23) & 3);
        if (sel == 0) {
            const cem = <i32>((lo >> 25) & 0xf);
            for (let p = 0; p < partitions; p++) cems[p] = cem;
        } else {
            extraCemBits = 3 * partitions - 4;
            below -= extraCemBits;
            const encoded = <i32>((lo >> 25) & 0xf) | (readBits(lo, hi, below, extraCemBits, 128) << 4);
            const base = sel - 1;
            for (let p = 0; p < partitions; p++) cems[p] = (((encoded >> p) & 1) + base) << 2;
            for (let p = 0; p < partitions; p++) cems[p] |= (encoded >> (partitions + 2 * p)) & 3;
        }
    }
    let plane2 = -1;
    if (dual) {
        below -= 2;
        plane2 = readBits(lo, hi, below, 2, 128);
    }
    let valueCount = 0;
    for (let p = 0; p < partitions; p++) valueCount += ((cems[p] >> 2) + 1) * 2;
    const colorBits = below - colorStart;
    if (valueCount > 18 || colorBits < 0) {
        errorBlock(block, texels);
        return;
    }
    let cq = 20;
    while (cq > 0 && iseBits(valueCount, cq) > colorBits) cq--;
    if (cq < QUANT_6) {
        errorBlock(block, texels);
        return;
    }
    decodeISE(lo, hi, colorStart, valueCount, cq, iseValues);
    for (let i = 0; i < valueCount; i++) colorValues[i] = <i32>COLOR_UNQ[cq * 256 + iseValues[i]];
    let vo = 0;
    for (let p = 0; p < partitions; p++) {
        decodeEndpoints(cems[p], colorValues, vo, endpoints, p);
        vo += ((cems[p] >> 2) + 1) * 2;
    }
    // Weights: read from the top of the block down.
    decodeISE(reverse64(hi), reverse64(lo), 0, weightCount, m.q, iseValues);
    const gw = gridWeights;
    for (let i = 0; i < weightCount; i++) gw[i] = <i32>WEIGHT_UNQ[m.q * 32 + iseValues[i]];
    for (let i = weightCount; i < weightCount + 32; i++) gw[i] = 0;
    // Endpoints as UNORM16.
    const e16 = endpoints16;
    for (let i = 0; i < partitions * 8; i++) {
        e16[i] = srgb ? (endpoints[i] << 8) | 0x80 : endpoints[i] * 257;
    }
    // Texels: infill the weight grid, pick the partition, interpolate.
    const xw = m.xw, yw = m.yw;
    const fullGrid = xw == bw && yw == bh;
    const ds = (1024 + (bw >> 1)) / (bw - 1), dt = (1024 + (bh >> 1)) / (bh - 1);
    const planes = dual ? 2 : 1;
    const shift = texels < 31 ? 1 : 0;   // small blocks double the coordinates
    if (partitions > 1) preparePartition(seed, partitions);
    for (let y = 0; y < bh; y++) {
        const gt = ((dt * y) * (yw - 1) + 32) >> 6;
        const jt = gt >> 4, ft = gt & 0xf;
        for (let x = 0; x < bw; x++) {
            let wp0 = 0, wp1 = 0;
            if (fullGrid) {
                // The grid is the block: the infill below gives each texel its own weight.
                const v = (y * bw + x) * planes;
                wp0 = gw[v];
                if (dual) wp1 = gw[v + 1];
            } else {
                const gs = ((ds * x) * (xw - 1) + 32) >> 6;
                const js = gs >> 4, fs = gs & 0xf;
                const v0 = js + jt * xw;
                const w11 = (fs * ft + 8) >> 4;
                const w10 = ft - w11;
                const w01 = fs - w11;
                const w00 = 16 - fs - ft + w11;
                for (let pl = 0; pl < planes; pl++) {
                    const p00 = gw[v0 * planes + pl];
                    const p01 = gw[(v0 + 1) * planes + pl];
                    const p10 = gw[(v0 + xw) * planes + pl];
                    const p11 = gw[(v0 + xw + 1) * planes + pl];
                    const w = (p00 * w00 + p01 * w01 + p10 * w10 + p11 * w11 + 8) >> 4;
                    if (pl == 0) wp0 = w; else wp1 = w;
                }
            }
            const e = partitions > 1 ? partitionOf(x << shift, y << shift, partitions) * 8 : 0;
            const t = (y * bw + x) * 4;
            for (let c = 0; c < 4; c++) {
                const w = c == plane2 ? wp1 : wp0;
                const v = (e16[e + c] * (64 - w) + e16[e + 4 + c] * w + 32) >> 6;
                block[t + c] = <u8>to8(v, srgb);
            }
        }
    }
}

/// ASTC with `bw` x `bh` blocks, 16 bytes a block.
export function decodeASTC(data: Uint8Array, width: i32, height: i32, bw: i32, bh: i32, srgb: bool,
                           out: Uint8Array): void {
    const block = new Uint8Array(bw * bh * 4);
    let o = 0;
    for (let by = 0; by < height; by += bh) {
        for (let bx = 0; bx < width; bx += bw) {
            decodeASTCBlock(data, o, bw, bh, srgb, block);
            const w = min<i32>(bw, width - bx), h = min<i32>(bh, height - by);
            for (let y = 0; y < h; y++) {
                const d = ((by + y) * width + bx) * 4, s = y * bw * 4;
                for (let x = 0; x < w * 4; x++) out[d + x] = block[s + x];
            }
            o += 16;
        }
    }
}
