// three.js examples/jsm/loaders/EXRLoader.js, for scanline OpenEXR files
// from a BlobAsset: NO, RLE, ZIPS and ZIP compression; HALF, FLOAT and
// UINT channels; RGB(A) or luminance (Y). PIZ, PXR24, B44 and DWA
// compression, tiled, deep and multi-part files are not read. Returns a
// DataTexture of linear RGBA, HalfFloatType by default
// (setDataType(FloatType) keeps 32-bit floats on the CPU), top row first
// (flipY true), linear filters, no mipmaps.

import { Context } from "rive/host";
import { DataTexture } from "../../textures/DataTexture";
import { toHalf, fromHalf } from "../../textures/DataUpload";
import { HalfFloatType, FloatType, LinearFilter, RGBAFormat, LinearSRGBColorSpace } from "../../constants";
import { unzlibSync } from "../libs/fflate";

const NO_COMPRESSION = 0;
const RLE_COMPRESSION = 1;
const ZIPS_COMPRESSION = 2;
const ZIP_COMPRESSION = 3;

const UINT = 0;
const HALF = 1;
const FLOAT = 2;

class EXRChannel {
    name: string;
    pixelType: i32;
    constructor(name: string, pixelType: i32) {
        this.name = name;
        this.pixelType = pixelType;
    }
    get bytes(): i32 { return this.pixelType == HALF ? 2 : 4; }
}

/// What `parse` returns (three.js's texData).
export class EXRData {
    width: i32 = 0;
    height: i32 = 0;
    /// RGBA, top row first: Float32Array or Uint16Array (half floats).
    data: ArrayBufferView = new Uint8Array(0);
    type: i32 = HalfFloatType;
    compression: i32 = 0;
}

export class EXRLoader {
    /// Needed by `load` (BlobAssets and log lines); `parse` works without.
    context: Context?;
    type: i32 = HalfFloatType;
    error: string = "";

    constructor(context: Context? = null) {
        this.context = context;
    }

    setDataType(value: i32): EXRLoader {
        this.type = value;
        return this;
    }

    /// The .exr BlobAsset called `name` as a texture; null (and a log line)
    /// when it is missing or not readable here.
    load(name: string): DataTexture? {
        const context = this.context;
        if (context == null) return null;
        const bytes = context.blob(name);
        if (bytes == null) {
            context.log("three: EXRLoader: no blob asset named '" + name + "'");
            return null;
        }
        const d = this.parse(Uint8Array.wrap(bytes));
        if (d == null) {
            context.log("three: EXRLoader: " + this.error);
            return null;
        }
        const t = new DataTexture(d.data, <u32>d.width, <u32>d.height, RGBAFormat, d.type);
        t.name = name;
        t.colorSpace = LinearSRGBColorSpace;
        t.minFilter = LinearFilter;
        t.magFilter = LinearFilter;
        t.generateMipmaps = false;
        t.flipY = true;
        return t;
    }

    parse(buffer: Uint8Array): EXRData? {
        this.error = "";
        const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
        if (buffer.length < 8 || view.getUint32(0, true) != 20000630) {
            this.error = "not an OpenEXR file";
            return null;
        }
        const flags = view.getUint32(4, true);
        if ((flags & 0x1e00) != 0) {
            this.error = "tiled, deep or multi-part files are not supported";
            return null;
        }
        let pos = 8;
        const channels: Array<EXRChannel> = [];
        let compression = -1;
        let x0 = 0, y0 = 0, x1 = -1, y1 = -1;
        let lineOrder = 0;
        // Attributes, up to an empty name.
        while (pos < buffer.length) {
            const name = cstring(buffer, pos);
            pos += name.length + 1;
            if (name.length == 0) break;
            const type = cstring(buffer, pos);
            pos += type.length + 1;
            const size = view.getInt32(pos, true);
            pos += 4;
            const start = pos;
            if (name == "channels" && type == "chlist") {
                let p = pos;
                while (p < start + size) {
                    const cname = cstring(buffer, p);
                    p += cname.length + 1;
                    if (cname.length == 0) break;
                    const pixelType = view.getInt32(p, true);
                    p += 16;   // pixelType, pLinear + reserved, xSampling, ySampling
                    channels.push(new EXRChannel(cname, pixelType));
                }
            } else if (name == "compression") {
                compression = <i32>buffer[pos];
            } else if (name == "dataWindow") {
                x0 = view.getInt32(pos, true); y0 = view.getInt32(pos + 4, true);
                x1 = view.getInt32(pos + 8, true); y1 = view.getInt32(pos + 12, true);
            } else if (name == "lineOrder") {
                lineOrder = <i32>buffer[pos];
            }
            pos = start + size;
        }
        const width = x1 - x0 + 1, height = y1 - y0 + 1;
        if (width <= 0 || height <= 0 || channels.length == 0) {
            this.error = "missing channels or dataWindow";
            return null;
        }
        let linesPerBlock = 0;
        if (compression == NO_COMPRESSION || compression == RLE_COMPRESSION || compression == ZIPS_COMPRESSION) {
            linesPerBlock = 1;
        } else if (compression == ZIP_COMPRESSION) {
            linesPerBlock = 16;
        } else {
            this.error = "compression " + compression.toString() + " is not supported (NO, RLE, ZIPS, ZIP are)";
            return null;
        }
        // Skip the offset table; chunks follow in file order.
        const blocks = (height + linesPerBlock - 1) / linesPerBlock;
        pos += blocks * 8;
        // Channel slots: R G B A, or Y for luminance.
        let ri = -1, gi = -1, bi = -1, ai = -1, yi = -1;
        for (let i = 0; i < channels.length; i++) {
            const n = channels[i].name;
            if (n == "R") ri = i; else if (n == "G") gi = i; else if (n == "B") bi = i;
            else if (n == "A") ai = i; else if (n == "Y") yi = i;
        }
        let lineBytes = 0;
        for (let i = 0; i < channels.length; i++) lineBytes += channels[i].bytes * width;
        const rgba = new Float32Array(width * height * 4);
        for (let i = 3; i < rgba.length; i += 4) rgba[i] = 1;
        for (let b = 0; b < blocks; b++) {
            if (pos + 8 > buffer.length) {
                this.error = "truncated";
                return null;
            }
            const yStart = view.getInt32(pos, true) - y0;
            const dataSize = view.getInt32(pos + 4, true);
            pos += 8;
            const lines = min<i32>(linesPerBlock, height - yStart);
            const expected = lines * lineBytes;
            let raw: Uint8Array;
            const chunk = buffer.subarray(pos, pos + dataSize);
            if (dataSize >= expected) {
                raw = chunk;
            } else if (compression == ZIP_COMPRESSION || compression == ZIPS_COMPRESSION) {
                raw = unpredictAndInterleave(unzlibSync(chunk, expected));
            } else if (compression == RLE_COMPRESSION) {
                raw = unpredictAndInterleave(unRLE(chunk, expected));
            } else {
                this.error = "bad chunk size";
                return null;
            }
            pos += dataSize;
            if (raw.length < expected) {
                this.error = "chunk decoded short";
                return null;
            }
            const rv = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
            let p = 0;
            for (let l = 0; l < lines; l++) {
                const y = yStart + l;
                for (let c = 0; c < channels.length; c++) {
                    const ch = channels[c];
                    let slot = -1;
                    if (c == ri) slot = 0; else if (c == gi) slot = 1; else if (c == bi) slot = 2; else if (c == ai) slot = 3;
                    const lum = c == yi;
                    for (let x = 0; x < width; x++) {
                        let v: f32;
                        if (ch.pixelType == HALF) v = fromHalf(rv.getUint16(p, true));
                        else if (ch.pixelType == FLOAT) v = rv.getFloat32(p, true);
                        else if (ch.pixelType == UINT) v = <f32>rv.getUint32(p, true);
                        else v = 0;
                        p += ch.bytes;
                        const o = (y * width + x) * 4;
                        if (slot >= 0) rgba[o + slot] = v;
                        else if (lum) { rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; }
                    }
                }
            }
        }
        const out = new EXRData();
        out.width = width;
        out.height = height;
        out.compression = compression;
        out.type = this.type == FloatType ? FloatType : HalfFloatType;
        if (lineOrder == 1) flipRows(rgba, width, height);   // DECREASING_Y
        if (out.type == FloatType) {
            out.data = rgba;
        } else {
            const h = new Uint16Array(rgba.length);
            for (let i = 0; i < rgba.length; i++) h[i] = toHalf(rgba[i]);
            out.data = h;
        }
        return out;
    }
}

function cstring(b: Uint8Array, start: i32): string {
    let s = "";
    for (let i = start; i < b.length && b[i] != 0; i++) s += String.fromCharCode(<i32>b[i]);
    return s;
}

/// EXR's RLE: a negative count copies that many bytes, a positive one
/// repeats the next byte count + 1 times.
function unRLE(src: Uint8Array, size: i32): Uint8Array {
    const out = new Uint8Array(size);
    let o = 0, p = 0;
    while (p < src.length && o < size) {
        const count = <i32><i8>src[p++];
        if (count < 0) {
            for (let i = 0; i < -count && o < size && p < src.length; i++) out[o++] = src[p++];
        } else {
            const v = p < src.length ? src[p++] : 0;
            for (let i = 0; i <= count && o < size; i++) out[o++] = v;
        }
    }
    return out;
}

/// Undoes ZIP/RLE's byte predictor, then interleaves the two halves.
function unpredictAndInterleave(t: Uint8Array): Uint8Array {
    for (let i = 1; i < t.length; i++) t[i] = <u8>((<i32>t[i - 1] + <i32>t[i] - 128) & 0xff);
    const out = new Uint8Array(t.length);
    const half = (t.length + 1) / 2;
    let a = 0, b = half, o = 0;
    while (o < t.length) {
        if (a < half) out[o++] = t[a++];
        if (o < t.length) out[o++] = t[b++];
    }
    return out;
}

function flipRows(rgba: Float32Array, width: i32, height: i32): void {
    const row = width * 4;
    for (let y = 0; y < height / 2; y++) {
        const a = y * row, b = (height - 1 - y) * row;
        for (let i = 0; i < row; i++) {
            const t = rgba[a + i];
            rgba[a + i] = rgba[b + i];
            rgba[b + i] = t;
        }
    }
}
