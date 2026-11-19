// Draco's DecoderBuffer (core/decoder_buffer.h, core/varint_decoding.h),
// ported from Google's Draco decoder (Apache License 2.0,
// https://github.com/google/draco) to AnimaScript.
//
// A window over bytes: typed reads, varints and a bit reader. Reads past
// the end return 0 and set `failed` (Draco returns false); decoders check
// `failed` before they use what they read. Copies (`clone`) share the
// bytes, as Draco's buffers share the data pointer.

/// DRACO_BITSTREAM_VERSION(major, minor).
export function DRACO_BITSTREAM_VERSION(major: i32, minor: i32): i32 {
    return (major << 8) | minor;
}

export class DecoderBuffer {
    data: Uint8Array = new Uint8Array(0);
    /// The window: [base, base + size) of `data`.
    base: i32 = 0;
    size: i32 = 0;
    /// The read position, from `base`.
    pos: i32 = 0;
    bitstreamVersion: i32 = 0;
    /// Set by a read past the end.
    failed: bool = false;
    // The bit decoder (Draco's BitDecoder): absolute byte range and bit offset.
    bitMode: bool = false;
    bitStart: i32 = 0;
    bitEnd: i32 = 0;
    bitOffset: i32 = 0;

    /// Points the buffer at `size` bytes of `data` from `start`.
    init(data: Uint8Array, start: i32, size: i32, version: i32): DecoderBuffer {
        this.data = data;
        this.base = start;
        this.size = size;
        this.pos = 0;
        this.bitstreamVersion = version;
        this.bitMode = false;
        this.failed = false;
        return this;
    }

    clone(): DecoderBuffer {
        const b = new DecoderBuffer();
        b.copyFrom(this);
        return b;
    }

    copyFrom(o: DecoderBuffer): void {
        this.data = o.data;
        this.base = o.base;
        this.size = o.size;
        this.pos = o.pos;
        this.bitstreamVersion = o.bitstreamVersion;
        this.failed = o.failed;
        this.bitMode = o.bitMode;
        this.bitStart = o.bitStart;
        this.bitEnd = o.bitEnd;
        this.bitOffset = o.bitOffset;
    }

    /// Absolute offset of the read position in `data` (Draco's data_head()).
    get head(): i32 { return this.base + this.pos; }
    remainingSize(): i32 { return this.size - this.pos; }
    decodedSize(): i32 { return this.pos; }
    advance(bytes: i32): void { this.pos += bytes; }
    startDecodingFrom(offset: i32): void { this.pos = offset; }

    private need(n: i32): bool {
        if (n < 0 || this.pos + n > this.size) {
            this.failed = true;
            return false;
        }
        return true;
    }

    u8(): u32 {
        if (!this.need(1)) return 0;
        return <u32>this.data[this.base + this.pos++];
    }

    i8(): i32 {
        return <i32><i8>this.u8();
    }

    u16(): u32 {
        if (!this.need(2)) return 0;
        const at = this.base + this.pos;
        this.pos += 2;
        const d = this.data;
        return <u32>d[at] | (<u32>d[at + 1] << 8);
    }

    u32(): u32 {
        if (!this.need(4)) return 0;
        const at = this.base + this.pos;
        this.pos += 4;
        const d = this.data;
        return <u32>d[at] | (<u32>d[at + 1] << 8) | (<u32>d[at + 2] << 16) | (<u32>d[at + 3] << 24);
    }

    i32(): i32 { return <i32>this.u32(); }

    u64(): u64 {
        const lo = this.u32();
        const hi = this.u32();
        return <u64>lo | (<u64>hi << 32);
    }

    f32(): f32 { return reinterpret<f32>(this.u32()); }

    /// Copies `n` bytes into `out` at `offset`.
    bytes(out: Uint8Array, offset: i32, n: i32): bool {
        if (!this.need(n)) return false;
        const at = this.base + this.pos;
        for (let i = 0; i < n; i++) out[offset + i] = this.data[at + i];
        this.pos += n;
        return true;
    }

    /// DecodeVarint<uint32_t> (at most 5 bytes, low groups first).
    varintU32(): u32 {
        let value: u32 = 0;
        for (let i = 0; i < 5; i++) {
            const b = this.u8();
            if (this.failed) return 0;
            value |= (b & 0x7F) << <u32>(7 * i);
            if ((b & 0x80) == 0) return value;
        }
        this.failed = true;   // deeper than Draco's max_depth
        return 0;
    }

    /// DecodeVarint<uint64_t> (at most 10 bytes).
    varintU64(): u64 {
        let value: u64 = 0;
        for (let i = 0; i < 10; i++) {
            const b = this.u8();
            if (this.failed) return 0;
            value |= (<u64>(b & 0x7F)) << <u64>(7 * i);
            if ((b & 0x80) == 0) return value;
        }
        this.failed = true;
        return 0;
    }

    /// DecodeVarint<int32_t>: a zigzag-coded uint32.
    varintI32(): i32 {
        return convertSymbolToSignedInt(this.varintU32());
    }

    /// StartBitDecoding: the size of the bit data first when `decodeSize`
    /// (returned; 0 otherwise), then bits from the read position.
    startBitDecoding(decodeSize: bool): u64 {
        let size: u64 = 0;
        if (decodeSize) {
            if (this.bitstreamVersion < DRACO_BITSTREAM_VERSION(2, 2)) size = this.u64();
            else size = this.varintU64();
            if (this.failed) return 0;
        }
        this.bitMode = true;
        this.bitStart = this.base + this.pos;
        this.bitEnd = this.base + this.size;
        this.bitOffset = 0;
        return size;
    }

    endBitDecoding(): void {
        this.bitMode = false;
        this.pos += (this.bitOffset + 7) >> 3;
    }

    /// Up to 32 bits, least significant first (Draco's BitDecoder::GetBits).
    /// Bits past the end read as 0.
    decodeLeastSignificantBits32(nbits: i32): u32 {
        if (!this.bitMode || nbits > 32) {
            this.failed = true;
            return 0;
        }
        let value: u32 = 0;
        const d = this.data;
        for (let bit = 0; bit < nbits; bit++) {
            const off = this.bitOffset;
            const at = this.bitStart + (off >> 3);
            if (at < this.bitEnd) {
                value |= (<u32>(d[at] >> <u8>(off & 7)) & 1) << <u32>bit;
                this.bitOffset = off + 1;
            }
        }
        return value;
    }
}

/// ConvertSymbolToSignedInt: even symbols are positive, odd negative.
export function convertSymbolToSignedInt(val: u32): i32 {
    const positive = (val & 1) == 0;
    const v = <i32>(val >> 1);
    return positive ? v : -v - 1;
}

/// MostSignificantBit: the index of the highest set bit (n > 0).
export function mostSignificantBit(n: u32): i32 {
    return 31 - <i32>clz<u32>(n);
}
