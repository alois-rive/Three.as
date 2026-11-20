// three.js examples/jsm/loaders/LUT3dlLoader.js: Autodesk / Lustre .3dl
// 3D LUTs as a Data3DTexture, for LUTPass.
//
//     const lut = new LUT3dlLoader(context).load("warm_3dl");   // a BlobAsset
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
import { FloatType, UnsignedByteType } from "../../constants";
import { makeTexture, isNumber, splitSpaces } from "./LUTCubeLoader";

/// What parse returns (three.js's { size, texture3D }).
export class LUT3dlResult {
    size: i32 = 0;
    texture3D: Data3DTexture;

    constructor(texture3D: Data3DTexture) {
        this.texture3D = texture3D;
    }
}

export class LUT3dlLoader extends Loader {
    /// UnsignedByteType (the default) or FloatType texels.
    type: i32 = UnsignedByteType;
    /// Why the last parse failed ("" when it did not).
    error: string = "";

    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    /// UnsignedByteType or FloatType (anything else is ignored, with
    /// `error` set; three.js throws).
    setType(type: i32): LUT3dlLoader {
        if (type != UnsignedByteType && type != FloatType) {
            this.error = "LUT3dlLoader: Unsupported type";
            return this;
        }
        this.type = type;
        return this;
    }

    /// The .3dl BlobAsset `name`; null when missing or malformed.
    load(name: string): LUT3dlResult? {
        const context = this.context;
        const bytesAsset = context != null ? context.blob(this.path + name) : null;
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            this.error = "LUT3dlLoader: no blob asset named '" + this.path + name + "'";
            if (context != null) context.log("three: " + this.error);
            return null;
        }
        return this.parse(String.UTF8.decode(bytes!));
    }

    /// An https: url or a blob asset name.
    loadAsync(url: string): Promise<LUT3dlResult?> {
        return load3dl(this, url);
    }

    parse(input: string): LUT3dlResult? {
        this.error = "";
        const lines = input.split("\n");
        // The first line of only digits and spaces: the grid positions.
        let gridLine = -1;
        for (let li = 0; li < lines.length && gridLine < 0; li++) {
            const line = lines[li].trim();
            if (line.length == 0) continue;
            let ok = true;
            for (let i = 0; i < line.length && ok; i++) {
                const c = line.charCodeAt(i);
                ok = (c >= 48 && c <= 57) || c == 32 || c == 9 || c == 13;
            }
            if (ok) gridLine = li;
        }
        if (gridLine < 0) {
            this.error = "LUT3dlLoader: Missing grid information";
            return null;
        }
        const grid = splitSpaces(lines[gridLine].trim());
        const size = grid.length;
        if (size < 2) {
            this.error = "LUT3dlLoader: Missing grid information";
            return null;
        }
        const gridStep = F64.parseFloat(grid[1]) - F64.parseFloat(grid[0]);
        for (let i = 1; i < size; i++) {
            if (gridStep != F64.parseFloat(grid[i]) - F64.parseFloat(grid[i - 1])) {
                this.error = "LUT3dlLoader: Inconsistent grid size";
                return null;
            }
        }
        const sizeSq = size * size;
        const n = sizeSq * size;
        // Reordered into red-fastest triples (the file has blue fastest).
        const points = new Array<f64>(n * 3);
        for (let i = 0; i < n * 3; i++) points[i] = 0;
        let maxValue: f64 = 0;
        let index = 0;
        for (let li = gridLine + 1; li < lines.length; li++) {
            const tokens = splitSpaces(lines[li].trim());
            if (tokens.length != 3 || !isNumber(tokens[0]) || !isNumber(tokens[1]) || !isNumber(tokens[2])) continue;
            if (index >= n) break;
            const r = F64.parseFloat(tokens[0]);
            const g = F64.parseFloat(tokens[1]);
            const b = F64.parseFloat(tokens[2]);
            maxValue = Math.max(maxValue, Math.max(r, Math.max(g, b)));
            const bLayer = index % size;
            const gLayer = (index / size) % size;
            const rLayer = (index / sizeSq) % size;
            const d3 = (bLayer * sizeSq + gLayer * size + rLayer) * 3;
            points[d3] = r;
            points[d3 + 1] = g;
            points[d3 + 2] = b;
            index++;
        }
        // The bit depth scales the values to [0, 1].
        const bits = maxValue > 1 ? Math.ceil(Math.log2(maxValue)) : 1;
        const maxBitValue = Math.pow(2, bits) - 1;
        const result = new LUT3dlResult(makeTexture(points, size, this.type, maxBitValue));
        result.size = size;
        return result;
    }
}

async function load3dl(loader: LUT3dlLoader, url: string): Promise<LUT3dlResult?> {
    const bytes = await fetchBytes(loader, url);
    return loader.parse(String.UTF8.decode(bytes));
}
