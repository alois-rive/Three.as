// three.js examples/jsm/loaders/EXRLoader.js, for scanline OpenEXR files
// from a BlobAsset: NO, RLE, ZIPS and ZIP compression; HALF, FLOAT and
// UINT channels; RGB(A) or luminance (Y). PIZ, PXR24, B44 and DWA
// compression, tiled, deep and multi-part files are not read. Returns a
// DataTexture of linear RGBA, HalfFloatType by default
// (setDataType(FloatType) keeps 32-bit floats on the CPU), top row first
// (flipY true), linear filters, no mipmaps.

import { Context } from "rive/host";
import { Jobs } from "rive/jobs";
import { Promise } from "rive/promise";
import { Blob } from "rive/shared";
import { BinaryReader } from "rive/binary_reader";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { fetchBytes } from "../../loaders/FileLoader";
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

/// What `decodeEXR` hands back from a Rive job: pixel data in a shared Blob.
export class EXRDecoded {
    width: i32 = 0;
    height: i32 = 0;
    type: i32 = HalfFloatType;
    compression: i32 = 0;
    blob: Blob? = null;
    error: string = "";
}

class EXRParseResult {
    data: EXRData? = null;
    error: string = "";
}

/// Decodes an OpenEXR file off the main lane (the job behind loadAsync /
/// parseAsync).
@job export function decodeEXR(data: ArrayBuffer, type: i32 = HalfFloatType): EXRDecoded {
    const res = parseEXRCore(Uint8Array.wrap(data), type);
    const out = new EXRDecoded();
    if (res.data == null) {
        out.error = res.error;
        return out;
    }
    const d = res.data!;
    out.width = d.width;
    out.height = d.height;
    out.type = d.type;
    out.compression = d.compression;
    const view = d.data;
    if (view.byteLength > 0) {
        out.blob = Blob.from(view.buffer, view.byteOffset, view.byteLength);
    }
    return out;
}

export function buildEXRData(decoded: EXRDecoded): EXRData? {
    if (decoded.error.length > 0 || decoded.width <= 0 || decoded.height <= 0) return null;
    const out = new EXRData();
    out.width = decoded.width;
    out.height = decoded.height;
    out.type = decoded.type;
    out.compression = decoded.compression;
    const blob = decoded.blob;
    const count = decoded.width * decoded.height * 4;
    if (decoded.type == FloatType) {
        const f = new Float32Array(count);
        if (blob != null && blob.id != 0) blob.readInto(0, f);
        out.data = f;
    } else {
        const h = new Uint16Array(count);
        if (blob != null && blob.id != 0) blob.readInto(0, h);
        out.data = h;
    }
    return out;
}

export class EXRLoader extends Loader {
    type: i32 = HalfFloatType;
    error: string = "";

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
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
        const bytesAsset = context.blob(this.path + name);
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            context.log("three: EXRLoader: no blob asset named '" + this.path + name + "'");
            return null;
        }
        const d = this.parse(Uint8Array.wrap(bytes));
        if (d == null) {
            context.log("three: EXRLoader: " + this.error);
            return null;
        }
        return makeEXRTexture(d, name);
    }

    /// An https: url or a blob asset name, decoded in a Rive job.
    loadAsync(url: string): Promise<DataTexture> {
        return loadEXRAsync(this, url);
    }

    /// As `parse`, decoding in a Rive job off the main lane.
    parseAsync(data: ArrayBuffer): Promise<EXRData> {
        return parseEXRAsync(this, data);
    }

    parse(buffer: Uint8Array): EXRData? {
        const res = parseEXRCore(buffer, this.type);
        this.error = res.error;
        return res.data;
    }
}

function makeEXRTexture(d: EXRData, name: string): DataTexture {
    const t = new DataTexture(d.data, <u32>d.width, <u32>d.height, RGBAFormat, d.type);
    t.name = name;
    t.colorSpace = LinearSRGBColorSpace;
    t.minFilter = LinearFilter;
    t.magFilter = LinearFilter;
    t.generateMipmaps = false;
    t.flipY = true;
    return t;
}

async function loadEXRAsync(loader: EXRLoader, url: string): Promise<DataTexture> {
    const bytes = await fetchBytes(loader, url);
    const data = await parseEXRAsync(loader, bytes);
    return makeEXRTexture(data, url);
}

async function parseEXRAsync(loader: EXRLoader, data: ArrayBuffer): Promise<EXRData> {
    const job = Jobs.run(decodeEXR, data, loader.type);
    const settled = await job.promise().settled();
    job.release();
    if (!settled.ok) return await Promise.reject<EXRData>(settled.error);
    const decoded = settled.value;
    loader.error = decoded.error;
    const out = buildEXRData(decoded);
    if (out == null) return await Promise.reject<EXRData>("EXRLoader: " + decoded.error);
    return out;
}

function parseEXRCore(buffer: Uint8Array, targetType: i32): EXRParseResult {
    const res = new EXRParseResult();
    const reader = new BinaryReader(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    if (buffer.length < 8 || reader.readUint32() != 20000630) {
        res.error = "not an OpenEXR file";
        return res;
    }
    const flags = reader.readUint32();
    if ((flags & 0x1e00) != 0) {
        res.error = "tiled, deep or multi-part files are not supported";
        return res;
    }
    const channels: Array<EXRChannel> = [];
    let compression = -1;
    let x0 = 0, y0 = 0, x1 = -1, y1 = -1;
    let lineOrder = 0;
    // Attributes, up to an empty name.
    while (!reader.reachedEnd && !reader.didOverflow) {
        const name = readCString(reader, buffer);
        if (name.length == 0) break;
        const type = readCString(reader, buffer);
        const size = reader.read<i32>();
        if (reader.didOverflow || size < 0 || <u32>size > reader.remaining) {
            res.error = "truncated header";
            return res;
        }
        const start = reader.position;
        if (name == "channels" && type == "chlist") {
            const end = start + <u32>size;
            while (reader.position < end && !reader.didOverflow) {
                const cname = readCString(reader, buffer);
                if (cname.length == 0) break;
                const pixelType = reader.read<i32>();
                reader.skip(12);   // pLinear + reserved, xSampling, ySampling
                channels.push(new EXRChannel(cname, pixelType));
            }
        } else if (name == "compression" && size >= 1) {
            compression = <i32>reader.readByte();
        } else if (name == "dataWindow" && size >= 16) {
            x0 = reader.read<i32>(); y0 = reader.read<i32>();
            x1 = reader.read<i32>(); y1 = reader.read<i32>();
        } else if (name == "lineOrder" && size >= 1) {
            lineOrder = <i32>reader.readByte();
        }
        reader.position = start + <u32>size;
    }
    const width = x1 - x0 + 1, height = y1 - y0 + 1;
    if (width <= 0 || height <= 0 || channels.length == 0) {
        res.error = "missing channels or dataWindow";
        return res;
    }
    let linesPerBlock = 0;
    if (compression == NO_COMPRESSION || compression == RLE_COMPRESSION || compression == ZIPS_COMPRESSION) {
        linesPerBlock = 1;
    } else if (compression == ZIP_COMPRESSION) {
        linesPerBlock = 16;
    } else {
        res.error = "compression " + compression.toString() + " is not supported (NO, RLE, ZIPS, ZIP are)";
        return res;
    }
    // Skip the offset table; chunks follow in file order.
    const blocks = (height + linesPerBlock - 1) / linesPerBlock;
    reader.skip(<u32>(blocks * 8));
    if (reader.didOverflow) {
        res.error = "truncated";
        return res;
    }
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
        if (reader.remaining < 8) {
            res.error = "truncated";
            return res;
        }
        const yStart = reader.read<i32>() - y0;
        const dataSize = reader.read<i32>();
        if (dataSize < 0 || <u32>dataSize > reader.remaining || yStart < 0 || yStart >= height) {
            res.error = "bad chunk size";
            return res;
        }
        const lines = min<i32>(linesPerBlock, height - yStart);
        const expected = lines * lineBytes;
        const chunkPos = <i32>reader.position;
        const chunk = buffer.subarray(chunkPos, chunkPos + dataSize);
        reader.skip(<u32>dataSize);
        let raw: Uint8Array;
        if (dataSize >= expected) {
            raw = chunk;
        } else if (compression == ZIP_COMPRESSION || compression == ZIPS_COMPRESSION) {
            raw = unpredictAndInterleave(unzlibSync(chunk, expected));
        } else if (compression == RLE_COMPRESSION) {
            raw = unpredictAndInterleave(unRLE(chunk, expected));
        } else {
            res.error = "bad chunk size";
            return res;
        }
        if (raw.length < expected) {
            res.error = "chunk decoded short";
            return res;
        }
        const rr = new BinaryReader(raw.buffer, raw.byteOffset, raw.byteLength);
        for (let l = 0; l < lines; l++) {
            const y = yStart + l;
            for (let c = 0; c < channels.length; c++) {
                const ch = channels[c];
                let slot = -1;
                if (c == ri) slot = 0; else if (c == gi) slot = 1; else if (c == bi) slot = 2; else if (c == ai) slot = 3;
                const lum = c == yi;
                for (let x = 0; x < width; x++) {
                    let v: f32;
                    if (ch.pixelType == HALF) v = fromHalf(rr.readUint16());
                    else if (ch.pixelType == FLOAT) v = rr.readFloat32();
                    else if (ch.pixelType == UINT) v = <f32>rr.readUint32();
                    else { rr.skip(<u32>ch.bytes); v = 0; }
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
    out.type = targetType == FloatType ? FloatType : HalfFloatType;
    if (lineOrder == 1) flipRows(rgba, width, height);   // DECREASING_Y
    if (out.type == FloatType) {
        out.data = rgba;
    } else {
        const h = new Uint16Array(rgba.length);
        for (let i = 0; i < rgba.length; i++) h[i] = toHalf(rgba[i]);
        out.data = h;
    }
    res.data = out;
    return res;
}

function readCString(reader: BinaryReader, b: Uint8Array): string {
    const start = <i32>reader.position;
    let i = start;
    while (i < b.length && b[i] != 0) i++;
    let s = "";
    for (let j = start; j < i; j++) s += String.fromCharCode(<i32>b[j]);
    reader.position = <u32>(i < b.length ? i + 1 : b.length);
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
