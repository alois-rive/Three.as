// Draco's bit decoders (compression/bit_coders/rans_bit_decoder,
// direct_bit_decoder, folded_integer_bit_decoder), ported from Google's
// Draco decoder (Apache License 2.0, https://github.com/google/draco) to
// AnimaScript. The adaptive and symbol bit decoders only serve the
// pre-2.3 kd-tree coder, which is not ported.

import { DecoderBuffer, DRACO_BITSTREAM_VERSION } from "./decoder_buffer";
import { AnsDecoder, ansReadInit, rabsRead } from "./ans";

/// What the kd-tree decoder's policies pick from (Draco's templates).
export abstract class BitDecoder {
    /// Set when a read ran out of data (DirectBitDecoder returns false).
    failed: bool = false;
    abstract startDecoding(buffer: DecoderBuffer): bool;
    abstract decodeNextBit(): bool;
    abstract decodeLeastSignificantBits32(nbits: i32): u32;
    endDecoding(): void {}
}

/// RAnsBitDecoder: bits with a fixed probability of zero.
export class RAnsBitDecoder extends BitDecoder {
    ans: AnsDecoder = new AnsDecoder();
    probZero: u32 = 0;

    startDecoding(buffer: DecoderBuffer): bool {
        this.ans = new AnsDecoder();
        this.probZero = buffer.u8();
        let sizeInBytes: u32;
        if (buffer.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 2)) sizeInBytes = buffer.u32();
        else sizeInBytes = buffer.varintU32();
        if (buffer.failed) return false;
        if (<i64>sizeInBytes > <i64>buffer.remainingSize()) return false;
        if (ansReadInit(this.ans, buffer.data, buffer.head, <i32>sizeInBytes) != 0) return false;
        buffer.advance(<i32>sizeInBytes);
        return true;
    }

    decodeNextBit(): bool {
        return rabsRead(this.ans, this.probZero) > 0;
    }

    decodeLeastSignificantBits32(nbits: i32): u32 {
        let result: u32 = 0;
        while (nbits > 0) {
            result = (result << 1) + (this.decodeNextBit() ? 1 : 0);
            --nbits;
        }
        return result;
    }
}

/// DirectBitDecoder: raw bits, most significant first, in 32-bit words.
export class DirectBitDecoder extends BitDecoder {
    bits: Uint32Array = new Uint32Array(0);
    pos: i32 = 0;
    numUsedBits: u32 = 0;

    startDecoding(buffer: DecoderBuffer): bool {
        const sizeInBytes = buffer.u32();
        if (buffer.failed) return false;
        if (sizeInBytes == 0 || (sizeInBytes & 3) != 0) return false;
        if (<i64>sizeInBytes > <i64>buffer.remainingSize()) return false;
        const n = <i32>(sizeInBytes / 4);
        this.bits = new Uint32Array(n);
        for (let i = 0; i < n; i++) this.bits[i] = buffer.u32();
        this.pos = 0;
        this.numUsedBits = 0;
        return !buffer.failed;
    }

    decodeNextBit(): bool {
        if (this.pos >= this.bits.length) {
            this.failed = true;
            return false;
        }
        const selector: u32 = <u32>1 << (31 - this.numUsedBits);
        const bit = (this.bits[this.pos] & selector) != 0;
        ++this.numUsedBits;
        if (this.numUsedBits == 32) {
            ++this.pos;
            this.numUsedBits = 0;
        }
        return bit;
    }

    decodeLeastSignificantBits32(nbits: i32): u32 {
        const remaining = 32 - <i32>this.numUsedBits;
        if (nbits <= remaining) {
            if (this.pos >= this.bits.length) {
                this.failed = true;
                return 0;
            }
            // nbits == 0 reads nothing (a 32-bit shift is a no-op in wasm).
            const value = nbits == 0 ? 0 : (this.bits[this.pos] << this.numUsedBits) >> <u32>(32 - nbits);
            this.numUsedBits += <u32>nbits;
            if (this.numUsedBits == 32) {
                ++this.pos;
                this.numUsedBits = 0;
            }
            return value;
        }
        if (this.pos + 1 >= this.bits.length) {
            this.failed = true;
            return 0;
        }
        const valueL = this.bits[this.pos] << this.numUsedBits;
        this.numUsedBits = <u32>(nbits - remaining);
        ++this.pos;
        const valueR = this.bits[this.pos] >> (32 - this.numUsedBits);
        return (valueL >> <u32>(32 - <i32>this.numUsedBits - remaining)) | valueR;
    }
}

/// FoldedBit32Decoder<RAnsBitDecoder>: one bit decoder per bit position.
export class FoldedBit32Decoder extends BitDecoder {
    folded: Array<RAnsBitDecoder> = [];
    bitDecoder: RAnsBitDecoder = new RAnsBitDecoder();

    constructor() {
        super();
        for (let i = 0; i < 32; i++) this.folded.push(new RAnsBitDecoder());
    }

    startDecoding(buffer: DecoderBuffer): bool {
        for (let i = 0; i < 32; i++) {
            if (!this.folded[i].startDecoding(buffer)) return false;
        }
        return this.bitDecoder.startDecoding(buffer);
    }

    decodeNextBit(): bool { return this.bitDecoder.decodeNextBit(); }

    decodeLeastSignificantBits32(nbits: i32): u32 {
        let result: u32 = 0;
        for (let i = 0; i < nbits; ++i) {
            result = (result << 1) + (this.folded[i].decodeNextBit() ? 1 : 0);
        }
        return result;
    }
}
