// meshoptimizer's decoder (three.js's libs/meshopt_decoder.module.js) for
// EXT_meshopt_compression, in AnimaScript instead of WebAssembly: the
// attribute, triangle and index codecs and the octahedral, quaternion and
// exponential filters, as the extension's specification describes them.
//
//     loader.setMeshoptDecoder(MeshoptDecoder);
//
// Decodes the attribute codec version 0 (header 0xa0), the triangle codec
// 0xe1 and the index codec 0xd1.

export class MeshoptDecoderModule {
    readonly supported: bool = true;
    /// The last failure, "" when none.
    error: string = "";

    /// Decodes `count` elements of `size` bytes from `source` into `target`
    /// (count * size bytes): mode "ATTRIBUTES", "TRIANGLES" or "INDICES",
    /// filter "NONE", "OCTAHEDRAL", "QUATERNION" or "EXPONENTIAL".
    decodeGltfBuffer(target: Uint8Array, count: i32, size: i32, source: Uint8Array, mode: string,
                     filter: string = "NONE"): bool {
        this.error = "";
        let ok: bool;
        if (mode == "ATTRIBUTES") ok = this.decodeVertexBuffer(target, count, size, source);
        else if (mode == "TRIANGLES") ok = this.decodeIndexBuffer(target, count, size, source);
        else if (mode == "INDICES") ok = this.decodeIndexSequence(target, count, size, source);
        else {
            this.error = "unknown mode " + mode;
            return false;
        }
        if (!ok) return false;
        if (filter == "OCTAHEDRAL") filterOct(target, count, size);
        else if (filter == "QUATERNION") filterQuat(target, count, size);
        else if (filter == "EXPONENTIAL") filterExp(target, count, size);
        else if (filter != "NONE" && filter.length > 0) {
            this.error = "unknown filter " + filter;
            return false;
        }
        return true;
    }

    // ------------------------------------------------------------ attributes

    decodeVertexBuffer(target: Uint8Array, count: i32, size: i32, source: Uint8Array): bool {
        if (size <= 0 || size > 256 || (size & 3) != 0) { this.error = "bad vertex size"; return false; }
        if (source.length < 1 || source[0] != 0xa0) { this.error = "unsupported attribute codec version"; return false; }
        const tail = max<i32>(32, size);
        if (source.length < 1 + tail) { this.error = "attribute stream too short"; return false; }
        const end = source.length - tail;
        // The baseline element: the stream's last `size` bytes.
        const last = new Uint8Array(size);
        for (let k = 0; k < size; k++) last[k] = source[source.length - size + k];
        const maxBlock = min<i32>((8192 / size) & ~15, 256);
        const deltas = new Uint8Array(256);
        let pos = 1;
        let done = 0;
        while (done < count) {
            const block = min<i32>(count - done, maxBlock);
            const groups = (block + 15) >> 4;
            for (let k = 0; k < size; k++) {
                const headerBytes = (groups + 3) >> 2;
                if (pos + headerBytes > end) { this.error = "attribute stream truncated"; return false; }
                const header = pos;
                pos += headerBytes;
                for (let g = 0; g < groups; g++) {
                    const bits = (source[header + (g >> 2)] >> <u8>((g & 3) * 2)) & 3;
                    pos = decodeGroup(source, pos, end, bits, deltas, g * 16);
                    if (pos < 0) { this.error = "attribute stream truncated"; return false; }
                }
                // Undo the deltas for this byte.
                let p = last[k];
                for (let i = 0; i < block; i++) {
                    const v = deltas[i];
                    const d = (v & 1) != 0 ? ~(v >> 1) : (v >> 1);
                    p = <u8>(p + d);
                    target[(done + i) * size + k] = p;
                }
                last[k] = p;
            }
            done += block;
        }
        if (pos != end) { this.error = "attribute stream has extra bytes"; return false; }
        return true;
    }

    // ------------------------------------------------------------ triangles

    decodeIndexBuffer(target: Uint8Array, count: i32, size: i32, source: Uint8Array): bool {
        if ((size != 2 && size != 4) || count % 3 != 0) { this.error = "bad index size"; return false; }
        if (source.length < 1 + count / 3 + 16 || source[0] != 0xe1) { this.error = "unsupported triangle codec"; return false; }
        const edgeA = new Int32Array(16), edgeB = new Int32Array(16);
        const vertices = new Int32Array(16);
        let edgeOffset = 0, vertexOffset = 0;
        let next = 0, last = 0;
        const codeauxAt = source.length - 16;
        let codePos = 1;
        let dataPos = 1 + count / 3;
        const state = new Int32Array(2);   // data position, last
        for (let t = 0; t < count; t += 3) {
            const code = <i32>source[codePos++];
            const hi = code >> 4, lo = code & 15;
            let a = 0, b = 0, c = 0;
            if (hi < 0xf) {
                const e = (edgeOffset - 1 - hi) & 15;
                a = edgeA[e];
                b = edgeB[e];
                if (lo == 0) {
                    c = next++;
                    vertices[vertexOffset] = c; vertexOffset = (vertexOffset + 1) & 15;
                } else if (lo < 0xd) {
                    c = vertices[(vertexOffset - 1 - lo) & 15];
                } else if (lo < 0xf) {
                    c = lo == 0xd ? last - 1 : last + 1;
                    last = c;
                    vertices[vertexOffset] = c; vertexOffset = (vertexOffset + 1) & 15;
                } else {
                    state[0] = dataPos; state[1] = last;
                    c = decodeIndex(source, state);
                    dataPos = state[0]; last = state[1];
                    vertices[vertexOffset] = c; vertexOffset = (vertexOffset + 1) & 15;
                }
                edgeA[edgeOffset] = c; edgeB[edgeOffset] = b; edgeOffset = (edgeOffset + 1) & 15;
                edgeA[edgeOffset] = a; edgeB[edgeOffset] = c; edgeOffset = (edgeOffset + 1) & 15;
            } else {
                let z: i32, w: i32;
                let explicit = false;
                if (lo < 0xe) {
                    const aux = <i32>source[codeauxAt + lo];
                    z = aux >> 4; w = aux & 15;
                    a = next++;
                } else {
                    explicit = true;
                    const zw = <i32>source[dataPos++];
                    if (zw == 0) next = 0;
                    z = zw >> 4; w = zw & 15;
                    if (lo == 0xe) a = next++;
                    else {
                        state[0] = dataPos; state[1] = last;
                        a = decodeIndex(source, state);
                        dataPos = state[0]; last = state[1];
                    }
                }
                if (z == 0) b = next++;
                else if (z < 0xf || !explicit) b = vertices[(vertexOffset - z) & 15];
                else {
                    state[0] = dataPos; state[1] = last;
                    b = decodeIndex(source, state);
                    dataPos = state[0]; last = state[1];
                }
                if (w == 0) c = next++;
                else if (w < 0xf || !explicit) c = vertices[(vertexOffset - w) & 15];
                else {
                    state[0] = dataPos; state[1] = last;
                    c = decodeIndex(source, state);
                    dataPos = state[0]; last = state[1];
                }
                vertices[vertexOffset] = a; vertexOffset = (vertexOffset + 1) & 15;
                if (z == 0 || z == 0xf) { vertices[vertexOffset] = b; vertexOffset = (vertexOffset + 1) & 15; }
                if (w == 0 || w == 0xf) { vertices[vertexOffset] = c; vertexOffset = (vertexOffset + 1) & 15; }
                edgeA[edgeOffset] = b; edgeB[edgeOffset] = a; edgeOffset = (edgeOffset + 1) & 15;
                edgeA[edgeOffset] = c; edgeB[edgeOffset] = b; edgeOffset = (edgeOffset + 1) & 15;
                edgeA[edgeOffset] = a; edgeB[edgeOffset] = c; edgeOffset = (edgeOffset + 1) & 15;
            }
            writeIndex(target, size, t, a);
            writeIndex(target, size, t + 1, b);
            writeIndex(target, size, t + 2, c);
            if (dataPos > codeauxAt) { this.error = "triangle stream truncated"; return false; }
        }
        if (dataPos != codeauxAt) { this.error = "triangle stream has extra bytes"; return false; }
        return true;
    }

    // ------------------------------------------------------------ indices

    decodeIndexSequence(target: Uint8Array, count: i32, size: i32, source: Uint8Array): bool {
        if (size != 2 && size != 4) { this.error = "bad index size"; return false; }
        if (source.length < 5 || source[0] != 0xd1) { this.error = "unsupported index codec"; return false; }
        const end = source.length - 4;
        let pos = 1;
        let last0 = 0, last1 = 0;
        for (let i = 0; i < count; i++) {
            let v: u32 = 0, shift: u32 = 0;
            while (true) {
                if (pos >= end) { this.error = "index stream truncated"; return false; }
                const byte = <u32>source[pos++];
                v |= (byte & 127) << shift;
                shift += 7;
                if (byte < 128) break;
            }
            const delta = (v & 2) != 0 ? ~<i32>(v >> 2) : <i32>(v >> 2);
            let value: i32;
            if ((v & 1) != 0) { last1 += delta; value = last1; }
            else { last0 += delta; value = last0; }
            writeIndex(target, size, i, value);
        }
        if (pos != end) { this.error = "index stream has extra bytes"; return false; }
        return true;
    }
}

/// The decoder to pass to GLTFLoader.setMeshoptDecoder, as three.js's.
export const MeshoptDecoder: MeshoptDecoderModule = new MeshoptDecoderModule();

/// One group of 16 byte deltas (still zigzag-coded) into `out` at `at`;
/// the new stream position, or -1 past `end`.
function decodeGroup(src: Uint8Array, pos: i32, end: i32, bits: i32, out: Uint8Array, at: i32): i32 {
    if (bits == 0) {
        for (let i = 0; i < 16; i++) out[at + i] = 0;
        return pos;
    }
    if (bits == 3) {
        if (pos + 16 > end) return -1;
        for (let i = 0; i < 16; i++) out[at + i] = src[pos + i];
        return pos + 16;
    }
    const width = bits == 1 ? 2 : 4;
    const packed = width * 2;   // bytes of packed deltas
    if (pos + packed > end) return -1;
    const sentinel = (1 << width) - 1;
    let extra = pos + packed;
    for (let i = 0; i < 16; i++) {
        const bitPos = i * width;
        const byte = <i32>src[pos + (bitPos >> 3)];
        // Most significant first inside each byte.
        const v = (byte >> (8 - width - (bitPos & 7))) & sentinel;
        if (v == sentinel) {
            if (extra >= end) return -1;
            out[at + i] = src[extra++];
        } else {
            out[at + i] = <u8>v;
        }
    }
    return extra;
}

/// A varint-7 zigzag delta from state[1] (last), read at state[0].
function decodeIndex(src: Uint8Array, state: Int32Array): i32 {
    let pos = state[0];
    let v: u32 = 0, shift: u32 = 0;
    while (pos < src.length) {
        const byte = <u32>src[pos++];
        v |= (byte & 127) << shift;
        shift += 7;
        if (byte < 128) break;
    }
    const delta = (v & 1) != 0 ? ~<i32>(v >> 1) : <i32>(v >> 1);
    state[0] = pos;
    state[1] = state[1] + delta;
    return state[1];
}

function writeIndex(target: Uint8Array, size: i32, i: i32, value: i32): void {
    const u = <u32>value;
    if (size == 2) {
        target[i * 2] = <u8>(u & 255);
        target[i * 2 + 1] = <u8>((u >> 8) & 255);
    } else {
        target[i * 4] = <u8>(u & 255);
        target[i * 4 + 1] = <u8>((u >> 8) & 255);
        target[i * 4 + 2] = <u8>((u >> 16) & 255);
        target[i * 4 + 3] = <u8>(u >> 24);
    }
}

function readS(b: Uint8Array, at: i32, bytes: i32): i32 {
    if (bytes == 1) return <i32><i8>b[at];
    return <i32><i16>(<u16>b[at] | (<u16>b[at + 1] << 8));
}

function writeS(b: Uint8Array, at: i32, bytes: i32, v: i32): void {
    if (bytes == 1) { b[at] = <u8>(v & 255); return; }
    b[at] = <u8>(v & 255);
    b[at + 1] = <u8>((v >> 8) & 255);
}

function filterOct(b: Uint8Array, count: i32, stride: i32): void {
    const bytes = stride == 4 ? 1 : 2;
    const maxInt: f64 = bytes == 1 ? 127 : 32767;
    for (let i = 0; i < count; i++) {
        const at = i * stride;
        const one = <f64>readS(b, at + 2 * bytes, bytes);
        let x = <f64>readS(b, at, bytes) / one;
        let y = <f64>readS(b, at + bytes, bytes) / one;
        const z = 1.0 - Math.abs(x) - Math.abs(y);
        const t = Math.min(z, 0.0);
        x -= x >= 0 ? t : -t;
        y -= y >= 0 ? t : -t;
        const len = Math.sqrt(x * x + y * y + z * z);
        writeS(b, at, bytes, <i32>Math.round(x / len * maxInt));
        writeS(b, at + bytes, bytes, <i32>Math.round(y / len * maxInt));
        writeS(b, at + 2 * bytes, bytes, <i32>Math.round(z / len * maxInt));
    }
}

function filterQuat(b: Uint8Array, count: i32, stride: i32): void {
    const range = 1.0 / Math.sqrt(2.0);
    for (let i = 0; i < count; i++) {
        const at = i * stride;
        const w3 = readS(b, at + 6, 2);
        const one = <f64>(w3 | 3);
        const x = <f64>readS(b, at, 2) / one * range;
        const y = <f64>readS(b, at + 2, 2) / one * range;
        const z = <f64>readS(b, at + 4, 2) / one * range;
        const w = Math.sqrt(Math.max(0.0, 1.0 - x * x - y * y - z * z));
        const maxComp = w3 & 3;
        writeS(b, at + ((maxComp + 1) & 3) * 2, 2, <i32>Math.round(x * 32767.0));
        writeS(b, at + ((maxComp + 2) & 3) * 2, 2, <i32>Math.round(y * 32767.0));
        writeS(b, at + ((maxComp + 3) & 3) * 2, 2, <i32>Math.round(z * 32767.0));
        writeS(b, at + maxComp * 2, 2, <i32>Math.round(w * 32767.0));
    }
}

function filterExp(b: Uint8Array, count: i32, stride: i32): void {
    const n = count * stride / 4;
    const f = new Float32Array(1);
    const fb = Uint8Array.wrap(f.buffer);
    for (let i = 0; i < n; i++) {
        const at = i * 4;
        const v = <i32>(<u32>b[at] | (<u32>b[at + 1] << 8) | (<u32>b[at + 2] << 16) | (<u32>b[at + 3] << 24));
        const e = v >> 24;
        const m = (v << 8) >> 8;
        f[0] = <f32>(Math.pow(2.0, <f64>e) * <f64>m);
        b[at] = fb[0]; b[at + 1] = fb[1]; b[at + 2] = fb[2]; b[at + 3] = fb[3];
    }
}
