// three.js examples/jsm/loaders/RGBELoader.js (HDRLoader in newer three.js):
// Radiance .hdr images (RGBE, flat or run-length encoded) from a BlobAsset,
// as a DataTexture of linear HDR colour: HalfFloatType by default
// (setDataType(FloatType) keeps 32-bit floats on the CPU; both upload as
// half floats). Rows are top first, so flipY is true; filters are linear,
// no mipmaps, as three.js.
//
//     const hdr = new RGBELoader(context).load("studio");   // studio.hdr
//     hdr.mapping = THREE.EquirectangularReflectionMapping;
//     scene.environment = hdr;

import { Context } from "rive/host";
import { Jobs } from "rive/jobs";
import { Promise } from "rive/promise";
import { Blob } from "rive/shared";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { fetchBytes } from "../../loaders/FileLoader";
import { DataTexture } from "../../textures/DataTexture";
import { toHalf } from "../../textures/DataUpload";
import { HalfFloatType, FloatType, LinearFilter, RGBAFormat, LinearSRGBColorSpace } from "../../constants";

/// What `parse` returns (three.js's texData).
export class RGBEData {
    width: i32 = 0;
    height: i32 = 0;
    /// RGBA, top row first: Float32Array or Uint16Array (half floats).
    data: ArrayBufferView = new Uint8Array(0);
    header: string = "";
    gamma: f64 = 1;
    exposure: f64 = 1;
    type: i32 = HalfFloatType;
}

/// What `decodeRGBE` hands back from a Rive job: pixel data in a shared Blob.
export class RGBEDecoded {
    width: i32 = 0;
    height: i32 = 0;
    header: string = "";
    gamma: f64 = 1;
    exposure: f64 = 1;
    type: i32 = HalfFloatType;
    blob: Blob? = null;
    error: string = "";
}

class RGBEParseResult {
    data: RGBEData? = null;
    error: string = "";
}

/// Decodes a Radiance .hdr file off the main lane (the job behind loadAsync /
/// parseAsync).
@job export function decodeRGBE(data: ArrayBuffer, type: i32 = HalfFloatType): RGBEDecoded {
    const res = parseRGBECore(Uint8Array.wrap(data), type);
    const out = new RGBEDecoded();
    if (res.data == null) {
        out.error = res.error;
        return out;
    }
    const d = res.data!;
    out.width = d.width;
    out.height = d.height;
    out.header = d.header;
    out.gamma = d.gamma;
    out.exposure = d.exposure;
    out.type = d.type;
    const view = d.data;
    if (view.byteLength > 0) {
        out.blob = Blob.from(view.buffer, view.byteOffset, view.byteLength);
    }
    return out;
}

export function buildRGBEData(decoded: RGBEDecoded): RGBEData? {
    if (decoded.error.length > 0 || decoded.width <= 0 || decoded.height <= 0) return null;
    const out = new RGBEData();
    out.width = decoded.width;
    out.height = decoded.height;
    out.header = decoded.header;
    out.gamma = decoded.gamma;
    out.exposure = decoded.exposure;
    out.type = decoded.type;
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

export class RGBELoader extends Loader {
    type: i32 = HalfFloatType;
    /// Why the last parse failed ("" when it did not).
    error: string = "";

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    setDataType(value: i32): RGBELoader {
        this.type = value;
        return this;
    }

    /// The .hdr BlobAsset called `name` as a texture; null (and a log line)
    /// when it is missing or unreadable.
    load(name: string): DataTexture? {
        const context = this.context;
        if (context == null) return null;
        const bytesAsset = context.blob(this.path + name);
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            context.log("three: RGBELoader: no blob asset named '" + this.path + name + "'");
            return null;
        }
        const d = this.parse(Uint8Array.wrap(bytes));
        if (d == null) {
            context.log("three: RGBELoader: " + this.error);
            return null;
        }
        return makeRGBETexture(d, name);
    }

    /// An https: url or a blob asset name, decoded in a Rive job.
    loadAsync(url: string): Promise<DataTexture> {
        return loadRGBEAsync(this, url);
    }

    /// As `parse`, decoding in a Rive job off the main lane.
    parseAsync(data: ArrayBuffer): Promise<RGBEData> {
        return parseRGBEAsync(this, data);
    }

    parse(buffer: Uint8Array): RGBEData? {
        const res = parseRGBECore(buffer, this.type);
        this.error = res.error;
        return res.data;
    }
}

function makeRGBETexture(d: RGBEData, name: string): DataTexture {
    const t = new DataTexture(d.data, <u32>d.width, <u32>d.height, RGBAFormat, d.type);
    t.name = name;
    t.colorSpace = LinearSRGBColorSpace;
    t.minFilter = LinearFilter;
    t.magFilter = LinearFilter;
    t.generateMipmaps = false;
    t.flipY = true;
    return t;
}

async function loadRGBEAsync(loader: RGBELoader, url: string): Promise<DataTexture> {
    const bytes = await fetchBytes(loader, url);
    const data = await parseRGBEAsync(loader, bytes);
    return makeRGBETexture(data, url);
}

async function parseRGBEAsync(loader: RGBELoader, data: ArrayBuffer): Promise<RGBEData> {
    const job = Jobs.run(decodeRGBE, data, loader.type);
    const settled = await job.promise().settled();
    job.release();
    if (!settled.ok) return await Promise.reject<RGBEData>(settled.error);
    const decoded = settled.value;
    loader.error = decoded.error;
    const out = buildRGBEData(decoded);
    if (out == null) return await Promise.reject<RGBEData>("RGBELoader: " + decoded.error);
    return out;
}

function parseRGBECore(buffer: Uint8Array, targetType: i32): RGBEParseResult {
    const res = new RGBEParseResult();
    let pos = 0;
    // Header lines, up to the blank line.
    let header = "";
    let format = false;
    let gamma: f64 = 1, exposure: f64 = 1;
    let first = true;
    while (pos < buffer.length) {
        const end = lineEnd(buffer, pos);
        const line = readLineSlice(buffer, pos, end);
        pos = end < buffer.length ? end + 1 : buffer.length;
        if (first) {
            if (!line.startsWith("#?")) {
                res.error = "not a Radiance file (no #? magic)";
                return res;
            }
            first = false;
        }
        header += line + "\n";
        if (line.length == 0) break;
        if (line.startsWith("FORMAT=")) {
            format = line == "FORMAT=32-bit_rle_rgbe";
            if (!format) {
                res.error = "unsupported " + line;
                return res;
            }
        } else if (line.startsWith("GAMMA=")) {
            gamma = parseFloat(line.substring(6));
        } else if (line.startsWith("EXPOSURE=")) {
            exposure = parseFloat(line.substring(9));
        }
    }
    // The resolution: -Y height +X width.
    const resEnd = lineEnd(buffer, pos);
    const resLine = readLineSlice(buffer, pos, resEnd);
    pos = resEnd < buffer.length ? resEnd + 1 : buffer.length;
    const parts = resLine.split(" ");
    if (parts.length != 4 || parts[0] != "-Y" || parts[2] != "+X") {
        res.error = "unsupported resolution line '" + resLine + "'";
        return res;
    }
    const height = I32.parseInt(parts[1]);
    const width = I32.parseInt(parts[3]);
    if (width <= 0 || height <= 0 || <i64>width * <i64>height > 67108864 || pos >= buffer.length) {
        res.error = "bad size";
        return res;
    }
    const rgbe = new Uint8Array(width * height * 4);
    if (!readPixels(buffer, pos, width, height, rgbe)) {
        res.error = "truncated or corrupt pixel data";
        return res;
    }
    const out = new RGBEData();
    out.width = width;
    out.height = height;
    out.header = header;
    out.gamma = gamma;
    out.exposure = exposure;
    out.type = targetType == FloatType ? FloatType : HalfFloatType;
    // Precompute 256-entry 2^(e - 136) LUT (local for @job safety).
    const scales = new Float64Array(256);
    scales[0] = 0;
    let scaleVal: f64 = Math.pow(2, -135);
    for (let e = 1; e < 256; e++) {
        scales[e] = scaleVal;
        scaleVal *= 2.0;
    }
    const count = width * height;
    if (out.type == FloatType) {
        const f = new Float32Array(count * 4);
        for (let i = 0; i < count; i++) {
            const s = scales[rgbe[i * 4 + 3]];
            f[i * 4] = <f32>(<f64>rgbe[i * 4] * s);
            f[i * 4 + 1] = <f32>(<f64>rgbe[i * 4 + 1] * s);
            f[i * 4 + 2] = <f32>(<f64>rgbe[i * 4 + 2] * s);
            f[i * 4 + 3] = 1;
        }
        out.data = f;
    } else {
        const h = new Uint16Array(count * 4);
        for (let i = 0; i < count; i++) {
            const s = scales[rgbe[i * 4 + 3]];
            h[i * 4] = toHalf(<f32>(<f64>rgbe[i * 4] * s));
            h[i * 4 + 1] = toHalf(<f32>(<f64>rgbe[i * 4 + 1] * s));
            h[i * 4 + 2] = toHalf(<f32>(<f64>rgbe[i * 4 + 2] * s));
            h[i * 4 + 3] = 0x3c00;
        }
        out.data = h;
    }
    res.data = out;
    return res;
}

/// three.js's HDRLoader is the same loader.
export { RGBELoader as HDRLoader };

function lineEnd(b: Uint8Array, start: i32): i32 {
    let end = start;
    while (end < b.length && b[end] != 10) end++;
    return end;
}

function readLineSlice(b: Uint8Array, start: i32, end: i32): string {
    if (end > start && b[end - 1] == 13) end--;   // strip trailing \r (CRLF)
    let s = "";
    for (let i = start; i < end; i++) s += String.fromCharCode(<i32>b[i]);
    return s;
}

/// RGBE scanlines: new-style run-length encoded (per channel), or flat.
function readPixels(b: Uint8Array, start: i32, width: i32, height: i32, out: Uint8Array): bool {
    let pos = start;
    const line = new Uint8Array(width * 4);
    for (let y = 0; y < height; y++) {
        const o = y * width * 4;
        const rle = width >= 8 && width < 32768 && pos + 4 <= b.length && b[pos] == 2 && b[pos + 1] == 2
            && (b[pos + 2] & 0x80) == 0 && ((<i32>b[pos + 2] << 8) | <i32>b[pos + 3]) == width;
        if (!rle) {
            // Flat (or old-style) pixels: the rest of the image as is.
            const n = (height - y) * width * 4;
            if (pos + n > b.length) return false;
            for (let i = 0; i < n; i++) out[o + i] = b[pos + i];
            return true;
        }
        pos += 4;
        for (let c = 0; c < 4; c++) {
            let x = 0;
            while (x < width) {
                if (pos >= b.length) return false;
                let count = <i32>b[pos++];
                if (count > 128) {
                    count -= 128;
                    if (count == 0 || x + count > width || pos >= b.length) return false;
                    const v = b[pos++];
                    for (let i = 0; i < count; i++) line[(x++) * 4 + c] = v;
                } else {
                    if (count == 0 || x + count > width || pos + count > b.length) return false;
                    for (let i = 0; i < count; i++) line[(x++) * 4 + c] = b[pos++];
                }
            }
        }
        for (let i = 0; i < width * 4; i++) out[o + i] = line[i];
    }
    return true;
}
