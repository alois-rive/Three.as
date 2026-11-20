// three.js's STLLoader addon: binary and ASCII STL to a BufferGeometry
// (positions and face normals, not indexed). Binary files with a
// "COLOR=" header (Materialise Magics) get per-face colours; ASCII files
// with several solids get one group each.
//
//     const geometry = new STLLoader(context).load("part");    // a BlobAsset
//     scene.add(new Mesh(geometry, new MeshStandardMaterial()));

import { Context } from "rive/host";
import { Jobs } from "rive/jobs";
import { Promise } from "rive/promise";
import { Blob } from "rive/shared";
import { BinaryReader } from "rive/binary_reader";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { fetchBytes } from "../../loaders/FileLoader";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute } from "../../core/BufferAttribute";
import { Color } from "../../math/Color";
import { SRGBColorSpace } from "../../constants";

/// What STLLoader returns: three.js sets `hasColors`, `alpha` and
/// `userData.groupNames` on the geometry.
export class STLGeometry extends BufferGeometry {
    hasColors: bool = false;
    alpha: f64 = 1;
    groupNames: Array<string> = [];
}

/// Plain parsed arrays (no BufferGeometry construction, so safe inside `@job`).
class STLParsed {
    vertices: Float32Array = new Float32Array(0);
    normals: Float32Array = new Float32Array(0);
    colors: Float32Array = new Float32Array(0);
    hasColors: bool = false;
    alpha: f64 = 1;
    groupStarts: Array<i32> = [];
    groupCounts: Array<i32> = [];
    groupNames: Array<string> = [];
}

/// What `decodeSTL` hands back from a Rive job: packed positions, normals and
/// optional colours in a shared Blob, plus any ASCII solid groups.
export class STLDecoded {
    blob: Blob? = null;
    vertexCount: i32 = 0;
    hasColors: bool = false;
    alpha: f64 = 1;
    groupStarts: Int32Array = new Int32Array(0);
    groupCounts: Int32Array = new Int32Array(0);
    groupNames: Array<string> = [];
}

/// Decodes binary or ASCII STL off the main lane (the job behind loadAsync /
/// parseAsync).
@job export function decodeSTL(data: ArrayBuffer): STLDecoded {
    const p = parseSTLData(data);
    const out = new STLDecoded();
    const floats = p.vertices.length;
    out.vertexCount = floats / 3;
    out.hasColors = p.hasColors && p.colors.length == floats;
    out.alpha = p.alpha;
    const total = out.hasColors ? floats * 3 : floats * 2;
    if (total > 0) {
        const packed = new Float32Array(total);
        packed.set(p.vertices, 0);
        packed.set(p.normals, floats);
        if (out.hasColors) packed.set(p.colors, floats * 2);
        out.blob = Blob.fromArray(packed);
    }
    const gn = p.groupStarts.length;
    out.groupStarts = new Int32Array(gn);
    out.groupCounts = new Int32Array(gn);
    for (let i = 0; i < gn; i++) {
        out.groupStarts[i] = p.groupStarts[i];
        out.groupCounts[i] = p.groupCounts[i];
    }
    out.groupNames = p.groupNames;
    return out;
}

export class STLLoader extends Loader {
    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    /// The STL BlobAsset `name`; null when missing.
    load(name: string): STLGeometry? {
        const context = this.context;
        const bytesAsset = context != null ? context.blob(this.path + name) : null;
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            if (context != null) context.log("three: STLLoader: no blob asset named '" + this.path + name + "'");
            return null;
        }
        return this.parse(bytes!);
    }

    /// An https: url or a blob asset name, decoded in a Rive job.
    loadAsync(url: string): Promise<STLGeometry> {
        return loadSTL(this, url);
    }

    /// As `parse`, decoding in a Rive job off the main lane.
    parseAsync(data: ArrayBuffer): Promise<STLGeometry> {
        return parseSTLAsync(data);
    }

    parse(data: ArrayBuffer): STLGeometry {
        const p = parseSTLData(data);
        const geometry = new STLGeometry();
        geometry.setAttribute("position", new BufferAttribute(p.vertices, 3));
        geometry.setAttribute("normal", new BufferAttribute(p.normals, 3));
        if (p.hasColors) {
            geometry.setAttribute("color", new BufferAttribute(p.colors, 3));
            geometry.hasColors = true;
            geometry.alpha = p.alpha;
        }
        for (let i = 0; i < p.groupStarts.length; i++) {
            geometry.addGroup(p.groupStarts[i], p.groupCounts[i], i);
        }
        geometry.groupNames = p.groupNames;
        return geometry;
    }
}

async function loadSTL(loader: STLLoader, url: string): Promise<STLGeometry> {
    const bytes = await fetchBytes(loader, url);
    return await parseSTLAsync(bytes);
}

async function parseSTLAsync(data: ArrayBuffer): Promise<STLGeometry> {
    const job = Jobs.run(decodeSTL, data);
    const settled = await job.promise().settled();
    job.release();
    if (!settled.ok) return await Promise.reject<STLGeometry>(settled.error);
    return buildSTLFromDecoded(settled.value);
}

export function buildSTLFromDecoded(decoded: STLDecoded): STLGeometry {
    const g = new STLGeometry();
    const floats = decoded.vertexCount * 3;
    const blob = decoded.blob;
    const pos = new Float32Array(floats);
    const nrm = new Float32Array(floats);
    if (blob != null && blob.id != 0 && floats > 0) {
        blob.readInto(0, pos);
        blob.readInto(<u32>(floats * 4), nrm);
    }
    const posAttr = new BufferAttribute(pos, 3);
    if (blob != null && blob.id != 0 && floats > 0) posAttr.setBlob(blob, 0, <u32>(floats * 4));
    g.setAttribute("position", posAttr);
    g.setAttribute("normal", new BufferAttribute(nrm, 3));
    if (decoded.hasColors) {
        const col = new Float32Array(floats);
        if (blob != null && blob.id != 0 && floats > 0) blob.readInto(<u32>(floats * 8), col);
        g.setAttribute("color", new BufferAttribute(col, 3));
        g.hasColors = true;
        g.alpha = decoded.alpha;
    }
    for (let i = 0; i < decoded.groupStarts.length; i++) {
        g.addGroup(decoded.groupStarts[i], decoded.groupCounts[i], i);
    }
    g.groupNames = decoded.groupNames;
    return g;
}

function parseSTLData(data: ArrayBuffer): STLParsed {
    const bytes = Uint8Array.wrap(data);
    return isBinary(bytes) ? parseBinary(bytes) : parseASCII(String.UTF8.decode(data));
}

function isBinary(b: Uint8Array): bool {
    if (b.length < 84) return false;
    const reader = new BinaryReader(b.buffer, b.byteOffset, b.byteLength);
    reader.position = 80;
    const faceSize: i64 = 50;
    const faces = <i64>reader.readUint32();
    if (84 + faces * faceSize == <i64>b.length) return true;
    // ASCII starts with "solid", maybe after a byte order mark.
    for (let off = 0; off < 5; off++) {
        if (b.length >= off + 5 && b[off] == 115 && b[off + 1] == 111 && b[off + 2] == 108 && b[off + 3] == 105
            && b[off + 4] == 100) return false;
    }
    return true;
}

function parseBinary(b: Uint8Array): STLParsed {
    const reader = new BinaryReader(b.buffer, b.byteOffset, b.byteLength);
    let r: f64 = 0, g: f64 = 0, bl: f64 = 0;
    let hasColors = false;
    let defaultR: f64 = 0, defaultG: f64 = 0, defaultB: f64 = 0, alpha: f64 = 1;
    // A default colour in the header: "COLOR=rgba".
    for (let index = 0; index <= 80 - 10; index++) {
        if (b[index] == 0x43 && b[index + 1] == 0x4F && b[index + 2] == 0x4C && b[index + 3] == 0x4F
            && b[index + 4] == 0x52 && b[index + 5] == 0x3D) {
            hasColors = true;
            defaultR = <f64>b[index + 6] / 255;
            defaultG = <f64>b[index + 7] / 255;
            defaultB = <f64>b[index + 8] / 255;
            alpha = <f64>b[index + 9] / 255;
        }
    }
    reader.position = 80;
    const rawFaces = reader.readUint32();
    const maxFaces: u32 = b.length >= 84 ? <u32>((b.length - 84) / 50) : 0;
    const faces = <i32>min<u32>(rawFaces, maxFaces);
    const out = new STLParsed();
    const vertices = new Float32Array(faces * 9);
    const normals = new Float32Array(faces * 9);
    const colors = new Float32Array(hasColors ? faces * 9 : 0);
    const color = new Color();
    for (let face = 0; face < faces; face++) {
        const nx = reader.readFloat32(), ny = reader.readFloat32(), nz = reader.readFloat32();
        const base = face * 9;
        for (let i = 0; i < 3; i++) {
            const c = base + i * 3;
            vertices[c] = reader.readFloat32();
            vertices[c + 1] = reader.readFloat32();
            vertices[c + 2] = reader.readFloat32();
            normals[c] = nx; normals[c + 1] = ny; normals[c + 2] = nz;
        }
        const packed = <i32>reader.readUint16();
        if (reader.didOverflow) break;
        if (hasColors) {
            if ((packed & 0x8000) == 0) {
                // The facet's own colour.
                r = <f64>(packed & 0x1F) / 31;
                g = <f64>((packed >> 5) & 0x1F) / 31;
                bl = <f64>((packed >> 10) & 0x1F) / 31;
            } else {
                r = defaultR; g = defaultG; bl = defaultB;
            }
            color.setRGB(r, g, bl, SRGBColorSpace);
            const cr = <f32>color.r, cg = <f32>color.g, cb = <f32>color.b;
            for (let i = 0; i < 3; i++) {
                const c = base + i * 3;
                colors[c] = cr; colors[c + 1] = cg; colors[c + 2] = cb;
            }
        }
    }
    out.vertices = vertices;
    out.normals = normals;
    if (hasColors) {
        out.colors = colors;
        out.hasColors = true;
        out.alpha = alpha;
    }
    return out;
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

function parseASCII(text: string): STLParsed {
    const out = new STLParsed();
    const vertices: Array<f64> = [];
    const normals: Array<f64> = [];
    let nx: f64 = 0, ny: f64 = 0, nz: f64 = 0;
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
            out.groupNames.push(at >= 0 ? restOfLine(text, at + 5) : "");
            if (at >= 0) search = at + 5;
            // Skip the name's tokens up to the first facet.
            while (i + 1 < t.length && t[i + 1] != "facet" && t[i + 1] != "endsolid") i++;
        } else if (w == "endsolid") {
            if (inSolid) {
                out.groupStarts.push(startVertex);
                out.groupCounts.push(endVertex - startVertex);
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
    const vArr = new Float32Array(vertices.length);
    for (let i = 0; i < vertices.length; i++) vArr[i] = <f32>vertices[i];
    const nArr = new Float32Array(normals.length);
    for (let i = 0; i < normals.length; i++) nArr[i] = <f32>normals[i];
    out.vertices = vArr;
    out.normals = nArr;
    return out;
}
