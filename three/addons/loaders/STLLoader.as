// three.js's STLLoader addon: binary and ASCII STL to a BufferGeometry
// (positions and face normals, not indexed). Binary files with a
// "COLOR=" header (Materialise Magics) get per-face colours; ASCII files
// with several solids get one group each.
//
//     const geometry = new STLLoader(context).load("part");    // a BlobAsset
//     scene.add(new Mesh(geometry, new MeshStandardMaterial()));

import { Context } from "rive/host";
import { Promise } from "rive/promise";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { fetchBytes } from "../../loaders/FileLoader";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute, Float32BufferAttribute } from "../../core/BufferAttribute";
import { Color } from "../../math/Color";
import { SRGBColorSpace } from "../../constants";

/// What STLLoader returns: three.js sets `hasColors`, `alpha` and
/// `userData.groupNames` on the geometry.
export class STLGeometry extends BufferGeometry {
    hasColors: bool = false;
    alpha: f64 = 1;
    groupNames: Array<string> = [];
}

export class STLLoader extends Loader {
    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    /// The STL BlobAsset `name`; null when missing.
    load(name: string): STLGeometry? {
        const context = this.context;
        const bytes = context != null ? context.blob(this.path + name) : null;
        if (bytes == null) {
            if (context != null) context.log("three: STLLoader: no blob asset named '" + this.path + name + "'");
            return null;
        }
        return this.parse(bytes!);
    }

    /// An https: url or a blob asset name.
    loadAsync(url: string): Promise<STLGeometry> {
        return loadSTL(this, url);
    }

    parse(data: ArrayBuffer): STLGeometry {
        const bytes = Uint8Array.wrap(data);
        return isBinary(bytes) ? parseBinary(bytes) : parseASCII(String.UTF8.decode(data));
    }
}

async function loadSTL(loader: STLLoader, url: string): Promise<STLGeometry> {
    const bytes = await fetchBytes(loader, url);
    return loader.parse(bytes);
}

function isBinary(b: Uint8Array): bool {
    if (b.length < 84) return false;
    const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const faceSize = 32 / 8 * 3 + 32 / 8 * 3 * 3 + 16 / 8;
    const faces = <i64>view.getUint32(80, true);
    if (84 + faces * faceSize == <i64>b.length) return true;
    // ASCII starts with "solid", maybe after a byte order mark.
    for (let off = 0; off < 5; off++) {
        if (b.length >= off + 5 && b[off] == 115 && b[off + 1] == 111 && b[off + 2] == 108 && b[off + 3] == 105
            && b[off + 4] == 100) return false;
    }
    return true;
}

function parseBinary(b: Uint8Array): STLGeometry {
    const reader = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const faces = <i32>reader.getUint32(80, true);
    let r: f64 = 0, g: f64 = 0, bl: f64 = 0;
    let hasColors = false;
    let defaultR: f64 = 0, defaultG: f64 = 0, defaultB: f64 = 0, alpha: f64 = 1;
    // A default colour in the header: "COLOR=rgba".
    for (let index = 0; index < 80 - 10; index++) {
        if (reader.getUint32(index, false) == 0x434F4C4F && reader.getUint8(index + 4) == 0x52
            && reader.getUint8(index + 5) == 0x3D) {
            hasColors = true;
            defaultR = <f64>reader.getUint8(index + 6) / 255;
            defaultG = <f64>reader.getUint8(index + 7) / 255;
            defaultB = <f64>reader.getUint8(index + 8) / 255;
            alpha = <f64>reader.getUint8(index + 9) / 255;
        }
    }
    const dataOffset = 84;
    const faceLength = 12 * 4 + 2;
    const geometry = new STLGeometry();
    const vertices = new Float32Array(faces * 9);
    const normals = new Float32Array(faces * 9);
    const colors = new Float32Array(hasColors ? faces * 9 : 0);
    const color = new Color();
    for (let face = 0; face < faces; face++) {
        const start = dataOffset + face * faceLength;
        if (start + faceLength > b.length) break;
        const nx = reader.getFloat32(start, true), ny = reader.getFloat32(start + 4, true), nz = reader.getFloat32(start + 8, true);
        if (hasColors) {
            const packed = <i32>reader.getUint16(start + 48, true);
            if ((packed & 0x8000) == 0) {
                // The facet's own colour.
                r = <f64>(packed & 0x1F) / 31;
                g = <f64>((packed >> 5) & 0x1F) / 31;
                bl = <f64>((packed >> 10) & 0x1F) / 31;
            } else {
                r = defaultR; g = defaultG; bl = defaultB;
            }
        }
        for (let i = 1; i <= 3; i++) {
            const vs = start + i * 12;
            const c = face * 9 + (i - 1) * 3;
            vertices[c] = reader.getFloat32(vs, true);
            vertices[c + 1] = reader.getFloat32(vs + 4, true);
            vertices[c + 2] = reader.getFloat32(vs + 8, true);
            normals[c] = nx; normals[c + 1] = ny; normals[c + 2] = nz;
            if (hasColors) {
                color.setRGB(r, g, bl, SRGBColorSpace);
                colors[c] = <f32>color.r; colors[c + 1] = <f32>color.g; colors[c + 2] = <f32>color.b;
            }
        }
    }
    geometry.setAttribute("position", new BufferAttribute(vertices, 3));
    geometry.setAttribute("normal", new BufferAttribute(normals, 3));
    if (hasColors) {
        geometry.setAttribute("color", new BufferAttribute(colors, 3));
        geometry.hasColors = true;
        geometry.alpha = alpha;
    }
    return geometry;
}

/// Whitespace-separated tokens of `text`.
function tokens(text: string): Array<string> {
    const out: Array<string> = [];
    let start = -1;
    for (let i = 0; i <= text.length; i++) {
        const c = i < text.length ? text.charCodeAt(i) : 32;
        const space = c == 32 || c == 9 || c == 10 || c == 13 || c == 12 || c == 11;
        if (space) {
            if (start >= 0) {
                out.push(text.substring(start, i));
                start = -1;
            }
        } else if (start < 0) {
            start = i;
        }
    }
    return out;
}

/// The rest of the line after `at` (the solid's name).
function restOfLine(text: string, at: i32): string {
    let end = at;
    while (end < text.length && text.charCodeAt(end) != 10 && text.charCodeAt(end) != 13) end++;
    return text.substring(at, end).trim();
}

function parseASCII(text: string): STLGeometry {
    const geometry = new STLGeometry();
    const vertices: Array<f64> = [];
    const normals: Array<f64> = [];
    let nx: f64 = 0, ny: f64 = 0, nz: f64 = 0;
    let groupCount = 0;
    let startVertex = 0;
    let endVertex = 0;
    let inSolid = false;
    // Solid names: from the text, since tokens lose line structure.
    let search = 0;
    const t = tokens(text);
    for (let i = 0; i < t.length; i++) {
        const w = t[i];
        if (w == "solid") {
            inSolid = true;
            startVertex = endVertex;
            const at = text.indexOf("solid", search);
            geometry.groupNames.push(at >= 0 ? restOfLine(text, at + 5) : "");
            if (at >= 0) search = at + 5;
            // Skip the name's tokens up to the first facet.
            while (i + 1 < t.length && t[i + 1] != "facet" && t[i + 1] != "endsolid") i++;
        } else if (w == "endsolid") {
            if (inSolid) {
                geometry.addGroup(startVertex, endVertex - startVertex, groupCount);
                groupCount++;
            }
            inSolid = false;
            const at = text.indexOf("endsolid", search);
            if (at >= 0) search = at + 8;
            while (i + 1 < t.length && t[i + 1] != "solid") i++;
        } else if (w == "normal" && i + 3 < t.length) {
            nx = parseFloat(t[i + 1]); ny = parseFloat(t[i + 2]); nz = parseFloat(t[i + 3]);
            i += 3;
        } else if (w == "vertex" && i + 3 < t.length) {
            vertices.push(parseFloat(t[i + 1])); vertices.push(parseFloat(t[i + 2])); vertices.push(parseFloat(t[i + 3]));
            normals.push(nx); normals.push(ny); normals.push(nz);
            endVertex++;
            i += 3;
        }
    }
    geometry.setAttribute("position", new Float32BufferAttribute(vertices, 3));
    geometry.setAttribute("normal", new Float32BufferAttribute(normals, 3));
    return geometry;
}
