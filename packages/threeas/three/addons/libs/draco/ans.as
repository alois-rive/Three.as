// Draco's entropy decoders (compression/entropy/ans.h,
// rans_symbol_decoder.h, rans_symbol_coding.h, symbol_decoding.cc), ported
// from Google's Draco decoder (Apache License 2.0,
// https://github.com/google/draco) to AnimaScript.

import { DecoderBuffer, DRACO_BITSTREAM_VERSION } from "./decoder_buffer";

const ANS_P8_PRECISION: u32 = 256;
const ANS_L_BASE: u32 = 4096;
const ANS_IO_BASE: u32 = 256;

/// AnsDecoder: a binary ANS (rABS) state reading bytes backwards from
/// `data[base + bufOffset - 1]`.
export class AnsDecoder {
    data: Uint8Array = new Uint8Array(0);
    base: i32 = 0;
    bufOffset: i32 = 0;
    state: u32 = 0;
}

function memGetLe16(d: Uint8Array, at: i32): u32 {
    return <u32>d[at] | (<u32>d[at + 1] << 8);
}

function memGetLe24(d: Uint8Array, at: i32): u32 {
    return <u32>d[at] | (<u32>d[at + 1] << 8) | (<u32>d[at + 2] << 16);
}

function memGetLe32(d: Uint8Array, at: i32): u32 {
    return <u32>d[at] | (<u32>d[at + 1] << 8) | (<u32>d[at + 2] << 16) | (<u32>d[at + 3] << 24);
}

/// ans_read_init: 0 on success.
export function ansReadInit(ans: AnsDecoder, data: Uint8Array, base: i32, offset: i32): i32 {
    if (offset < 1) return 1;
    ans.data = data;
    ans.base = base;
    const x = <u32>data[base + offset - 1] >> 6;
    if (x == 0) {
        ans.bufOffset = offset - 1;
        ans.state = <u32>data[base + offset - 1] & 0x3F;
    } else if (x == 1) {
        if (offset < 2) return 1;
        ans.bufOffset = offset - 2;
        ans.state = memGetLe16(data, base + offset - 2) & 0x3FFF;
    } else if (x == 2) {
        if (offset < 3) return 1;
        ans.bufOffset = offset - 3;
        ans.state = memGetLe24(data, base + offset - 3) & 0x3FFFFF;
    } else {
        return 1;
    }
    ans.state += ANS_L_BASE;
    if (ans.state >= ANS_L_BASE * ANS_IO_BASE) return 1;
    return 0;
}

/// rabs_desc_read (Draco's rabs_read): one bit, `p0` the probability of 0
/// out of 256.
export function rabsRead(ans: AnsDecoder, p0: u32): i32 {
    const p = ANS_P8_PRECISION - p0;
    if (ans.state < ANS_L_BASE && ans.bufOffset > 0) {
        ans.state = ans.state * ANS_IO_BASE + <u32>ans.data[ans.base + --ans.bufOffset];
    }
    const x = ans.state;
    const quot = x / ANS_P8_PRECISION;
    const rem = x % ANS_P8_PRECISION;
    const xn = quot * p;
    const val = rem < p;
    if (val) ans.state = xn + rem;
    else ans.state = x - xn - p;
    return val ? 1 : 0;
}

/// RAnsDecoder<precision_bits>: the multi-symbol rANS decoder.
export class RAnsDecoder {
    precision: u32;
    lRansBase: u32;
    lutTable: Uint32Array = new Uint32Array(0);
    probs: Uint32Array = new Uint32Array(0);
    cumProbs: Uint32Array = new Uint32Array(0);
    data: Uint8Array = new Uint8Array(0);
    base: i32 = 0;
    bufOffset: i32 = 0;
    state: u32 = 0;

    constructor(precisionBits: i32) {
        this.precision = <u32>1 << <u32>precisionBits;
        this.lRansBase = this.precision * 4;
    }

    /// read_init: 0 on success.
    readInit(data: Uint8Array, base: i32, offset: i32): i32 {
        if (offset < 1) return 1;
        this.data = data;
        this.base = base;
        const x = <u32>data[base + offset - 1] >> 6;
        if (x == 0) {
            this.bufOffset = offset - 1;
            this.state = <u32>data[base + offset - 1] & 0x3F;
        } else if (x == 1) {
            if (offset < 2) return 1;
            this.bufOffset = offset - 2;
            this.state = memGetLe16(data, base + offset - 2) & 0x3FFF;
        } else if (x == 2) {
            if (offset < 3) return 1;
            this.bufOffset = offset - 3;
            this.state = memGetLe24(data, base + offset - 3) & 0x3FFFFF;
        } else {
            if (offset < 4) return 1;
            this.bufOffset = offset - 4;
            this.state = memGetLe32(data, base + offset - 4) & 0x3FFFFFFF;
        }
        this.state += this.lRansBase;
        if (this.state >= this.lRansBase * ANS_IO_BASE) return 1;
        return 0;
    }

    readEnd(): bool { return this.state == this.lRansBase; }

    ransRead(): u32 {
        const d = this.data;
        while (this.state < this.lRansBase && this.bufOffset > 0) {
            this.state = this.state * ANS_IO_BASE + <u32>d[this.base + --this.bufOffset];
        }
        const quo = this.state / this.precision;
        const rem = this.state % this.precision;
        const symbol = this.lutTable[rem];
        this.state = quo * this.probs[symbol] + rem - this.cumProbs[symbol];
        return symbol;
    }

    ransBuildLookUpTable(tokenProbs: Uint32Array, numSymbols: u32): bool {
        this.lutTable = new Uint32Array(<i32>this.precision);
        this.probs = new Uint32Array(<i32>numSymbols);
        this.cumProbs = new Uint32Array(<i32>numSymbols);
        let cumProb: u32 = 0;
        let actProb: u32 = 0;
        for (let i: u32 = 0; i < numSymbols; ++i) {
            const p = tokenProbs[i];
            this.probs[i] = p;
            this.cumProbs[i] = cumProb;
            cumProb += p;
            if (cumProb > this.precision) return false;
            for (let j = actProb; j < cumProb; ++j) this.lutTable[j] = i;
            actProb = cumProb;
        }
        return cumProb == this.precision;
    }
}

/// ComputeRAnsPrecisionFromUniqueSymbolsBitLength.
export function ransPrecisionBits(symbolsBitLength: i32): i32 {
    const p = (3 * symbolsBitLength) / 2;
    return p < 12 ? 12 : p > 20 ? 20 : p;
}

/// RAnsSymbolDecoder<unique_symbols_bit_length>.
export class RAnsSymbolDecoder {
    numSymbols: u32 = 0;
    ans: RAnsDecoder;

    constructor(uniqueSymbolsBitLength: i32) {
        this.ans = new RAnsDecoder(ransPrecisionBits(uniqueSymbolsBitLength));
    }

    create(buffer: DecoderBuffer): bool {
        if (buffer.bitstreamVersion == 0) return false;
        if (buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 0)) this.numSymbols = buffer.u32();
        else this.numSymbols = buffer.varintU32();
        if (buffer.failed) return false;
        const n = this.numSymbols;
        if (<i64>(n / 64) > <i64>buffer.remainingSize()) return false;
        if (n == 0) return true;
        const table = new Uint32Array(<i32>n);
        for (let i: u32 = 0; i < n; ++i) {
            const probData = buffer.u8();
            if (buffer.failed) return false;
            const token = probData & 3;
            if (token == 3) {
                const offset = probData >> 2;
                if (i + offset >= n) return false;
                for (let j: u32 = 0; j < offset + 1; ++j) table[i + j] = 0;
                i += offset;
            } else {
                let prob = probData >> 2;
                for (let b: u32 = 0; b < token; ++b) {
                    const eb = buffer.u8();
                    if (buffer.failed) return false;
                    prob |= eb << (8 * (b + 1) - 2);
                }
                table[i] = prob;
            }
        }
        return this.ans.ransBuildLookUpTable(table, n);
    }

    startDecoding(buffer: DecoderBuffer): bool {
        let bytesEncoded: u64;
        if (buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 0)) bytesEncoded = buffer.u64();
        else bytesEncoded = buffer.varintU64();
        if (buffer.failed) return false;
        if (bytesEncoded > <u64>buffer.remainingSize()) return false;
        const head = buffer.head;
        buffer.advance(<i32>bytesEncoded);
        return this.ans.readInit(buffer.data, head, <i32>bytesEncoded) == 0;
    }

    decodeSymbol(): u32 { return this.ans.ransRead(); }

    endDecoding(): void { this.ans.readEnd(); }
}

const SYMBOL_CODING_TAGGED: u32 = 0;
const SYMBOL_CODING_RAW: u32 = 1;

/// DecodeSymbols: `numValues` symbols into `out` from `outOffset` (as
/// uint32 bits in an Int32Array).
export function decodeSymbols(numValues: u32, numComponents: i32, buffer: DecoderBuffer,
                              out: Int32Array, outOffset: i32 = 0): bool {
    if (numValues == 0) return true;
    const scheme = buffer.u8();
    if (buffer.failed) return false;
    if (scheme == SYMBOL_CODING_TAGGED) return decodeTaggedSymbols(numValues, numComponents, buffer, out, outOffset);
    if (scheme == SYMBOL_CODING_RAW) return decodeRawSymbols(numValues, buffer, out, outOffset);
    return false;
}

function decodeTaggedSymbols(numValues: u32, numComponents: i32, buffer: DecoderBuffer,
                             out: Int32Array, outOffset: i32): bool {
    const tagDecoder = new RAnsSymbolDecoder(5);
    if (!tagDecoder.create(buffer)) return false;
    if (!tagDecoder.startDecoding(buffer)) return false;
    if (numValues > 0 && tagDecoder.numSymbols == 0) return false;
    buffer.startBitDecoding(false);
    let valueId = outOffset;
    for (let i: u32 = 0; i < numValues; i += <u32>numComponents) {
        const bitLength = tagDecoder.decodeSymbol();
        if (bitLength > 32) return false;
        for (let j = 0; j < numComponents; ++j) {
            out[valueId++] = <i32>buffer.decodeLeastSignificantBits32(<i32>bitLength);
        }
    }
    tagDecoder.endDecoding();
    buffer.endBitDecoding();
    return !buffer.failed;
}

function decodeRawSymbols(numValues: u32, buffer: DecoderBuffer, out: Int32Array, outOffset: i32): bool {
    const maxBitLength = <i32>buffer.u8();
    if (buffer.failed || maxBitLength < 1 || maxBitLength > 18) return false;
    const decoder = new RAnsSymbolDecoder(maxBitLength);
    if (!decoder.create(buffer)) return false;
    if (numValues > 0 && decoder.numSymbols == 0) return false;
    if (!decoder.startDecoding(buffer)) return false;
    for (let i: u32 = 0; i < numValues; ++i) out[outOffset + <i32>i] = <i32>decoder.decodeSymbol();
    decoder.endDecoding();
    return true;
}
