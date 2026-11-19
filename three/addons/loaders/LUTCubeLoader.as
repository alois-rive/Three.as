// three.js examples/jsm/loaders/LUTCubeLoader.js: Adobe .cube 3D LUTs
// (https://wwwimages2.adobe.com/content/dam/acom/en/products/speedgrade/cc/pdfs/cube-lut-specification-1.0.pdf)
// as a Data3DTexture, for LUTPass.
//
//     const lut = new LUTCubeLoader(context).load("warm");   // a BlobAsset
//     if (lut != null) lutPass.lut = lut.texture3D;
//
// `load(name)` reads a BlobAsset (null when missing or malformed, with
// `error`; three.js throws), `loadAsync(url)` fetches, `parse(text)` parses.

import { Context } from "rive/host";
import { Promise } from "rive/promise";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { fetchBytes } from "../../loaders/FileLoader";
import { Data3DTexture } from "../../textures/DataArrayTexture";
import { Vector3 } from "../../math/Vector3";
import { ClampToEdgeWrapping, FloatType, LinearFilter, UnsignedByteType } from "../../constants";

/// What parse returns (three.js's { title, size, domainMin, domainMax,
/// texture3D }); `title` is "" when the file has none (three.js: null).
export class LUTCubeResult {
    title: string = "";
    size: i32 = 0;
    domainMin: Vector3 = new Vector3(0, 0, 0);
    domainMax: Vector3 = new Vector3(1, 1, 1);
    texture3D: Data3DTexture;

    constructor(texture3D: Data3DTexture) {
        this.texture3D = texture3D;
    }
}

export class LUTCubeLoader extends Loader {
    /// UnsignedByteType (the default) or FloatType texels.
    type: i32 = UnsignedByteType;
    /// Why the last parse failed ("" when it did not).
    error: string = "";

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    /// UnsignedByteType or FloatType (anything else is ignored, with
    /// `error` set; three.js throws).
    setType(type: i32): LUTCubeLoader {
        if (type != UnsignedByteType && type != FloatType) {
            this.error = "LUTCubeLoader: Unsupported type";
            return this;
        }
        this.type = type;
        return this;
    }

    /// The .cube BlobAsset `name`; null when missing or malformed.
    load(name: string): LUTCubeResult? {
        const context = this.context;
        const bytesAsset = context != null ? context.blob(this.path + name) : null;
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            this.error = "LUTCubeLoader: no blob asset named '" + this.path + name + "'";
            if (context != null) context.log("three: " + this.error);
            return null;
        }
        return this.parse(String.UTF8.decode(bytes!));
    }

    /// An https: url or a blob asset name.
    loadAsync(url: string): Promise<LUTCubeResult?> {
        return loadCube(this, url);
    }

    parse(input: string): LUTCubeResult? {
        this.error = "";
        let title = "";
        let size = -1;
        const domainMin = new Vector3(0, 0, 0);
        const domainMax = new Vector3(1, 1, 1);
        const points: Array<f64> = [];
        const lines = input.split("\n");
        for (let li = 0; li < lines.length; li++) {
            const line = lines[li].trim();
            if (line.length == 0 || line.charAt(0) == "#") continue;
            const tokens = splitSpaces(line);
            const key = tokens[0];
            if (key == "TITLE") {
                const a = line.indexOf("\"");
                const b = line.lastIndexOf("\"");
                if (a >= 0 && b > a) title = line.substring(a + 1, b);
            } else if (key == "LUT_3D_SIZE" && tokens.length > 1) {
                size = <i32>F64.parseFloat(tokens[1]);
            } else if (key == "DOMAIN_MIN" && tokens.length > 3) {
                domainMin.set(F64.parseFloat(tokens[1]), F64.parseFloat(tokens[2]), F64.parseFloat(tokens[3]));
            } else if (key == "DOMAIN_MAX" && tokens.length > 3) {
                domainMax.set(F64.parseFloat(tokens[1]), F64.parseFloat(tokens[2]), F64.parseFloat(tokens[3]));
            } else if (tokens.length == 3 && isNumber(tokens[0]) && isNumber(tokens[1]) && isNumber(tokens[2])) {
                points.push(F64.parseFloat(tokens[0]));
                points.push(F64.parseFloat(tokens[1]));
                points.push(F64.parseFloat(tokens[2]));
            }
        }
        if (size <= 0) {
            this.error = "LUTCubeLoader: Missing LUT_3D_SIZE information";
            return null;
        }
        if (domainMin.x > domainMax.x || domainMin.y > domainMax.y || domainMin.z > domainMax.z) {
            this.error = "LUTCubeLoader: Invalid input domain";
            return null;
        }
        const texture = makeTexture(points, size, this.type, 1);
        const result = new LUTCubeResult(texture);
        result.title = title;
        result.size = size;
        result.domainMin.copy(domainMin);
        result.domainMax.copy(domainMax);
        return result;
    }
}

async function loadCube(loader: LUTCubeLoader, url: string): Promise<LUTCubeResult?> {
    const bytes = await fetchBytes(loader, url);
    return loader.parse(String.UTF8.decode(bytes));
}

/// A size^3 RGBA Data3DTexture of `points` (r, g, b triples, red fastest)
/// divided by `divisor`, alpha 1 (internal: the LUT loaders).
export function makeTexture(points: Array<f64>, size: i32, type: i32, divisor: f64): Data3DTexture {
    const n = size * size * size;
    const length = n * 4;
    const scale: f64 = type == UnsignedByteType ? 255 : 1;
    let texture: Data3DTexture;
    if (type == UnsignedByteType) {
        const data = new Uint8Array(length);
        for (let i = 0; i < n && i * 3 + 2 < points.length; i++) {
            for (let c = 0; c < 3; c++) {
                const v = points[i * 3 + c] / divisor * scale;
                data[i * 4 + c] = <u8>Math.max(0, Math.min(255, Math.floor(v)));
            }
        }
        for (let i = 0; i < n; i++) data[i * 4 + 3] = 255;
        texture = new Data3DTexture(data, <u32>size, <u32>size, <u32>size);
    } else {
        const data = new Float32Array(length);
        for (let i = 0; i < n && i * 3 + 2 < points.length; i++) {
            for (let c = 0; c < 3; c++) data[i * 4 + c] = <f32>(points[i * 3 + c] / divisor);
        }
        for (let i = 0; i < n; i++) data[i * 4 + 3] = 1;
        texture = new Data3DTexture(data, <u32>size, <u32>size, <u32>size);
    }
    texture.type = type;
    texture.magFilter = LinearFilter;
    texture.minFilter = LinearFilter;
    texture.wrapS = ClampToEdgeWrapping;
    texture.wrapT = ClampToEdgeWrapping;
    texture.wrapR = ClampToEdgeWrapping;
    texture.generateMipmaps = false;
    texture.needsUpdate = true;
    return texture;
}

/// Whether `s` is made of digits, '.', 'e', '+' and '-' only (three.js's
/// data point pattern).
export function isNumber(s: string): bool {
    if (s.length == 0) return false;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        const digit = c >= 48 && c <= 57;
        if (!digit && c != 46 && c != 101 && c != 69 && c != 43 && c != 45) return false;
    }
    return true;
}

/// The whitespace-separated tokens of a line.
export function splitSpaces(line: string): Array<string> {
    const out: Array<string> = [];
    let start = -1;
    for (let i = 0; i <= line.length; i++) {
        const c = i < line.length ? line.charCodeAt(i) : 32;
        const space = c == 32 || c == 9 || c == 13;
        if (space) {
            if (start >= 0) out.push(line.substring(start, i));
            start = -1;
        } else if (start < 0) {
            start = i;
        }
    }
    return out;
}
