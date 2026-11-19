// DEFLATE decompression (RFC 1951) and the zlib wrapper (RFC 1950), under
// fflate's names, as three.js's addons import them from libs/fflate:
// `inflateSync(raw)`, `unzlibSync(zlib)`, `decompressSync` (either). A
// compact table-driven decoder (in the style of tinf); no compression.

class Tree {
    counts: Uint16Array = new Uint16Array(16);
    symbols: Uint16Array = new Uint16Array(288);
}

class Inflater {
    src: Uint8Array;
    pos: i32 = 0;
    bitBuf: u32 = 0;
    bitCount: i32 = 0;
    out: Uint8Array;
    outLen: i32 = 0;
    lt: Tree = new Tree();
    dt: Tree = new Tree();

    constructor(src: Uint8Array, start: i32, sizeHint: i32) {
        this.src = src;
        this.pos = start;
        this.out = new Uint8Array(max<i32>(sizeHint, 1024));
    }

    bits(n: i32): u32 {
        while (this.bitCount < n) {
            const b: u32 = this.pos < this.src.length ? <u32>this.src[this.pos] : 0;
            this.pos++;
            this.bitBuf |= b << <u32>this.bitCount;
            this.bitCount += 8;
        }
        const v = this.bitBuf & ((<u32>1 << <u32>n) - 1);
        this.bitBuf >>= <u32>n;
        this.bitCount -= n;
        return v;
    }

    emit(b: u8): void {
        if (this.outLen >= this.out.length) {
            const bigger = new Uint8Array(this.out.length * 2);
            bigger.set(this.out);
            this.out = bigger;
        }
        this.out[this.outLen++] = b;
    }

    decodeSymbol(t: Tree): i32 {
        let sum = 0, cur = 0, len = 0;
        do {
            cur = 2 * cur + <i32>this.bits(1);
            len++;
            sum += <i32>t.counts[len];
            cur -= <i32>t.counts[len];
        } while (cur >= 0 && len < 15);
        return <i32>t.symbols[sum + cur];
    }
}

const LENGTH_BASE: StaticArray<u16> = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
    67, 83, 99, 115, 131, 163, 195, 227, 258];
const LENGTH_BITS: StaticArray<u8> = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
    5, 5, 5, 5, 0];
const DIST_BASE: StaticArray<u16> = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513,
    769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
const DIST_BITS: StaticArray<u8> = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
    11, 11, 12, 12, 13, 13];
const CLEN_ORDER: StaticArray<u8> = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

function buildTree(t: Tree, lengths: Uint8Array, offset: i32, num: i32): void {
    for (let i = 0; i < 16; i++) t.counts[i] = 0;
    for (let i = 0; i < num; i++) t.counts[lengths[offset + i]]++;
    t.counts[0] = 0;
    const offs = new Uint16Array(16);
    let sum: u16 = 0;
    for (let i = 0; i < 16; i++) {
        offs[i] = sum;
        sum += t.counts[i];
    }
    for (let i = 0; i < num; i++) {
        const l = lengths[offset + i];
        if (l != 0) t.symbols[offs[l]++] = <u16>i;
    }
}

function fixedTrees(d: Inflater): void {
    const lengths = new Uint8Array(320);
    for (let i = 0; i < 144; i++) lengths[i] = 8;
    for (let i = 144; i < 256; i++) lengths[i] = 9;
    for (let i = 256; i < 280; i++) lengths[i] = 7;
    for (let i = 280; i < 288; i++) lengths[i] = 8;
    buildTree(d.lt, lengths, 0, 288);
    for (let i = 0; i < 30; i++) lengths[i] = 5;
    buildTree(d.dt, lengths, 0, 30);
}

function dynamicTrees(d: Inflater): void {
    const hlit = <i32>d.bits(5) + 257;
    const hdist = <i32>d.bits(5) + 1;
    const hclen = <i32>d.bits(4) + 4;
    const lengths = new Uint8Array(320);
    for (let i = 0; i < hclen; i++) lengths[CLEN_ORDER[i]] = <u8>d.bits(3);
    const codeTree = new Tree();
    buildTree(codeTree, lengths, 0, 19);
    for (let i = 0; i < 19; i++) lengths[i] = 0;
    let num = 0;
    while (num < hlit + hdist) {
        const sym = d.decodeSymbol(codeTree);
        if (sym < 16) {
            lengths[num++] = <u8>sym;
        } else {
            let len: u8 = 0;
            let repeat = 0;
            if (sym == 16) {
                len = num > 0 ? lengths[num - 1] : 0;
                repeat = 3 + <i32>d.bits(2);
            } else if (sym == 17) {
                repeat = 3 + <i32>d.bits(3);
            } else {
                repeat = 11 + <i32>d.bits(7);
            }
            while (repeat-- > 0 && num < 320) lengths[num++] = len;
        }
    }
    buildTree(d.lt, lengths, 0, hlit);
    buildTree(d.dt, lengths, hlit, hdist);
}

function inflateBlock(d: Inflater): void {
    while (true) {
        const sym = d.decodeSymbol(d.lt);
        if (sym < 256) {
            d.emit(<u8>sym);
        } else if (sym == 256) {
            return;
        } else {
            const li = sym - 257;
            if (li >= 29) return;
            const length = <i32>LENGTH_BASE[li] + <i32>d.bits(<i32>LENGTH_BITS[li]);
            const di = d.decodeSymbol(d.dt);
            if (di >= 30) return;
            const dist = <i32>DIST_BASE[di] + <i32>d.bits(<i32>DIST_BITS[di]);
            let from = d.outLen - dist;
            for (let i = 0; i < length; i++) d.emit(from >= 0 ? d.out[from++] : 0);
        }
    }
}

function storedBlock(d: Inflater): void {
    d.bitBuf = 0;
    d.bitCount = 0;   // align to a byte
    const p = d.pos;
    if (p + 4 > d.src.length) return;
    const len = <i32>d.src[p] | (<i32>d.src[p + 1] << 8);
    d.pos = p + 4;
    for (let i = 0; i < len && d.pos < d.src.length; i++) d.emit(d.src[d.pos++]);
}

function run(src: Uint8Array, start: i32, sizeHint: i32): Uint8Array {
    const d = new Inflater(src, start, sizeHint);
    let last: u32 = 0;
    do {
        last = d.bits(1);
        const type = d.bits(2);
        if (type == 0) storedBlock(d);
        else if (type == 1) { fixedTrees(d); inflateBlock(d); }
        else if (type == 2) { dynamicTrees(d); inflateBlock(d); }
        else break;
    } while (last == 0 && d.pos <= d.src.length);
    return d.out.slice(0, d.outLen);
}

/// Inflates raw DEFLATE data. `size`, when known, avoids regrowing.
export function inflateSync(data: Uint8Array, size: i32 = 0): Uint8Array {
    return run(data, 0, size > 0 ? size : data.length * 4);
}

/// Inflates zlib data (a 2-byte header, DEFLATE, an Adler-32 not checked).
export function unzlibSync(data: Uint8Array, size: i32 = 0): Uint8Array {
    if (data.length < 2) return new Uint8Array(0);
    const flags = data[1];
    const start = (flags & 0x20) != 0 ? 6 : 2;   // skip a preset dictionary id
    return run(data, start, size > 0 ? size : data.length * 4);
}

/// zlib or raw DEFLATE, by the header (gzip is not handled).
export function decompressSync(data: Uint8Array, size: i32 = 0): Uint8Array {
    if (data.length >= 2 && (data[0] & 0x0f) == 8 && ((<i32>data[0] << 8) | <i32>data[1]) % 31 == 0) {
        return unzlibSync(data, size);
    }
    return inflateSync(data, size);
}
