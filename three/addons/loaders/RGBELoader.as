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

export class RGBELoader {
    /// Needed by `load` (BlobAssets and log lines); `parse` works without.
    context: Context?;
    type: i32 = HalfFloatType;
    /// Why the last parse failed ("" when it did not).
    error: string = "";

    constructor(context: Context? = null) {
        this.context = context;
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
        const bytes = context.blob(name);
        if (bytes == null) {
            context.log("three: RGBELoader: no blob asset named '" + name + "'");
            return null;
        }
        const d = this.parse(Uint8Array.wrap(bytes));
        if (d == null) {
            context.log("three: RGBELoader: " + this.error);
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

    parse(buffer: Uint8Array): RGBEData? {
        this.error = "";
        let pos = 0;
        // Header lines, up to the blank line.
        let header = "";
        let format = false;
        let gamma: f64 = 1, exposure: f64 = 1;
        let first = true;
        while (pos < buffer.length) {
            const line = readLine(buffer, pos);
            pos += line.length + 1;
            if (first) {
                if (!line.startsWith("#?")) {
                    this.error = "not a Radiance file (no #? magic)";
                    return null;
                }
                first = false;
            }
            header += line + "\n";
            if (line.length == 0) break;
            if (line.startsWith("FORMAT=")) {
                format = line == "FORMAT=32-bit_rle_rgbe";
                if (!format) {
                    this.error = "unsupported " + line;
                    return null;
                }
            } else if (line.startsWith("GAMMA=")) {
                gamma = parseFloat(line.substring(6));
            } else if (line.startsWith("EXPOSURE=")) {
                exposure = parseFloat(line.substring(9));
            }
        }
        // The resolution: -Y height +X width.
        const res = readLine(buffer, pos);
        pos += res.length + 1;
        const parts = res.split(" ");
        if (parts.length != 4 || parts[0] != "-Y" || parts[2] != "+X") {
            this.error = "unsupported resolution line '" + res + "'";
            return null;
        }
        const height = I32.parseInt(parts[1]);
        const width = I32.parseInt(parts[3]);
        if (width <= 0 || height <= 0) {
            this.error = "bad size";
            return null;
        }
        const rgbe = new Uint8Array(width * height * 4);
        if (!readPixels(buffer, pos, width, height, rgbe)) {
            this.error = "truncated or corrupt pixel data";
            return null;
        }
        const out = new RGBEData();
        out.width = width;
        out.height = height;
        out.header = header;
        out.gamma = gamma;
        out.exposure = exposure;
        out.type = this.type == FloatType ? FloatType : HalfFloatType;
        const count = width * height;
        if (out.type == FloatType) {
            const f = new Float32Array(count * 4);
            for (let i = 0; i < count; i++) {
                const s = rgbeScale(rgbe[i * 4 + 3]);
                f[i * 4] = <f32>(<f64>rgbe[i * 4] * s);
                f[i * 4 + 1] = <f32>(<f64>rgbe[i * 4 + 1] * s);
                f[i * 4 + 2] = <f32>(<f64>rgbe[i * 4 + 2] * s);
                f[i * 4 + 3] = 1;
            }
            out.data = f;
        } else {
            const h = new Uint16Array(count * 4);
            for (let i = 0; i < count; i++) {
                const s = rgbeScale(rgbe[i * 4 + 3]);
                h[i * 4] = toHalf(<f32>(<f64>rgbe[i * 4] * s));
                h[i * 4 + 1] = toHalf(<f32>(<f64>rgbe[i * 4 + 1] * s));
                h[i * 4 + 2] = toHalf(<f32>(<f64>rgbe[i * 4 + 2] * s));
                h[i * 4 + 3] = 0x3c00;
            }
            out.data = h;
        }
        return out;
    }
}

/// three.js's HDRLoader is the same loader.
export { RGBELoader as HDRLoader };

function rgbeScale(e: u8): f64 {
    return e == 0 ? 0 : Math.pow(2, <f64>e - 136);   // 2^(e - 128) / 256
}

function readLine(b: Uint8Array, start: i32): string {
    let end = start;
    while (end < b.length && b[end] != 10) end++;
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
