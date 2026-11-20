// three.js's OBJLoader addon: Wavefront .obj text (from a BlobAsset, or a
// string) to a Group with one Mesh (or LineSegments / Points) per object
// and material, as three.js builds it.
//
//     const group = new OBJLoader(context).load("teapot");   // the BlobAsset's name
//
// Reads v (with optional vertex colours), vt, vn, f (any polygon, fan
// triangulated; negative indices), l, p, o, g, usemtl, s. Materials are
// MeshPhongMaterials named after usemtl (.mtl files are not read). Without
// normals, normals are computed. Geometry is non-indexed, as three.js's.

import { Context } from "rive/host";
import { Jobs } from "rive/jobs";
import { Promise } from "rive/promise";
import { Blob } from "rive/shared";
import { Loader } from "../../loaders/Loader";
import { LoadingManager } from "../../loaders/LoadingManager";
import { fetchBytes } from "../../loaders/FileLoader";
import { Group } from "../../objects/Group";
import { Mesh } from "../../objects/Mesh";
import { LineSegments } from "../../objects/Line";
import { Points } from "../../objects/Points";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute, Float32BufferAttribute } from "../../core/BufferAttribute";
import { MeshPhongMaterial } from "../../materials/MeshPhongMaterial";
import { LineBasicMaterial } from "../../materials/LineBasicMaterial";
import { PointsMaterial } from "../../materials/PointsMaterial";
import { Material } from "../../materials/Material";

class ObjPart {
    name: string;
    material: string;
    kind: i32 = 0;   // 0 faces, 1 lines, 2 points
    positions: Array<f64> = [];
    normals: Array<f64> = [];
    uvs: Array<f64> = [];
    colors: Array<f64> = [];

    constructor(name: string, material: string, kind: i32) {
        this.name = name;
        this.material = material;
        this.kind = kind;
    }
}

/// What `decodeOBJ` hands back from a Rive job: every non-empty part's float
/// attributes packed in a shared Blob, plus per-part metadata.
export class OBJDecoded {
    blob: Blob? = null;
    names: Array<string> = [];
    materials: Array<string> = [];
    kinds: Int32Array = new Int32Array(0);
    posCounts: Int32Array = new Int32Array(0);
    nrmCounts: Int32Array = new Int32Array(0);
    uvCounts: Int32Array = new Int32Array(0);
    colCounts: Int32Array = new Int32Array(0);
}

/// Decodes Wavefront .obj text off the main lane (the job behind loadAsync /
/// parseAsync).
@job export function decodeOBJ(text: string): OBJDecoded {
    const rawParts = parseOBJParts(text);
    const parts: Array<ObjPart> = [];
    for (let i = 0; i < rawParts.length; i++) {
        if (rawParts[i].positions.length > 0) parts.push(rawParts[i]);
    }
    const n = parts.length;
    const out = new OBJDecoded();
    out.kinds = new Int32Array(n);
    out.posCounts = new Int32Array(n);
    out.nrmCounts = new Int32Array(n);
    out.uvCounts = new Int32Array(n);
    out.colCounts = new Int32Array(n);
    let total = 0;
    for (let i = 0; i < n; i++) {
        const part = parts[i];
        const count = part.positions.length / 3;
        const pLen = part.positions.length;
        const nLen = part.normals.length == pLen ? pLen : 0;
        const uvLen = part.uvs.length == count * 2 ? count * 2 : 0;
        const cLen = part.colors.length == pLen ? pLen : 0;
        out.names.push(part.name);
        out.materials.push(part.material);
        out.kinds[i] = part.kind;
        out.posCounts[i] = pLen;
        out.nrmCounts[i] = nLen;
        out.uvCounts[i] = uvLen;
        out.colCounts[i] = cLen;
        total += pLen + nLen + uvLen + cLen;
    }
    if (total > 0) {
        const packed = new Float32Array(total);
        let at = 0;
        for (let i = 0; i < n; i++) {
            const part = parts[i];
            at = copyOBJFloats(packed, at, part.positions, out.posCounts[i]);
            at = copyOBJFloats(packed, at, part.normals, out.nrmCounts[i]);
            at = copyOBJFloats(packed, at, part.uvs, out.uvCounts[i]);
            at = copyOBJFloats(packed, at, part.colors, out.colCounts[i]);
        }
        out.blob = Blob.fromArray(packed);
    }
    return out;
}

export function buildOBJFromDecoded(decoded: OBJDecoded): Group {
    const group = new Group();
    const materials = new Map<string, Material>();
    const blob = decoded.blob;
    const hasBlob = blob != null && blob.id != 0;
    let byteOff: u32 = 0;
    for (let i = 0; i < decoded.names.length; i++) {
        const pLen = decoded.posCounts[i];
        const nLen = decoded.nrmCounts[i];
        const uvLen = decoded.uvCounts[i];
        const cLen = decoded.colCounts[i];
        const kind = decoded.kinds[i];
        const g = new BufferGeometry();
        const pos = new Float32Array(pLen);
        if (hasBlob && pLen > 0) blob!.readInto(byteOff, pos);
        const posAttr = new BufferAttribute(pos, 3);
        if (hasBlob && pLen > 0) posAttr.setBlob(blob!, byteOff, <u32>(pLen * 4));
        g.setAttribute("position", posAttr);
        byteOff += <u32>(pLen * 4);
        if (nLen > 0) {
            const nrm = new Float32Array(nLen);
            if (hasBlob) blob!.readInto(byteOff, nrm);
            g.setAttribute("normal", new BufferAttribute(nrm, 3));
            byteOff += <u32>(nLen * 4);
        }
        if (uvLen > 0) {
            const uv = new Float32Array(uvLen);
            if (hasBlob) blob!.readInto(byteOff, uv);
            const uvAttr = new BufferAttribute(uv, 2);
            if (hasBlob) uvAttr.setBlob(blob!, byteOff, <u32>(uvLen * 4));
            g.setAttribute("uv", uvAttr);
            byteOff += <u32>(uvLen * 4);
        }
        const hasColors = cLen > 0;
        if (hasColors) {
            const col = new Float32Array(cLen);
            if (hasBlob) blob!.readInto(byteOff, col);
            g.setAttribute("color", new BufferAttribute(col, 3));
            byteOff += <u32>(cLen * 4);
        }
        addOBJPart(group, materials, g, decoded.names[i], decoded.materials[i], kind, hasColors);
    }
    return group;
}

export class OBJLoader extends Loader {
    constructor(context: Context? = null, manager: LoadingManager? = null) {
        super(context, manager);
    }

    /// Loads the BlobAsset called `name`; null when missing.
    load(name: string): Group? {
        const c = this.context;
        if (c == null) return null;
        const bytesAsset = c.blob(this.path + name);
        const bytes = bytesAsset != null ? bytesAsset!.toArrayBuffer() : null;
        if (bytes == null) {
            c.log("three: OBJLoader: no blob asset named '" + this.path + name + "'");
            return null;
        }
        return this.parse(String.UTF8.decode(bytes));
    }

    /// An https: url or a blob asset name, decoded in a Rive job.
    loadAsync(url: string): Promise<Group> {
        return loadOBJAsync(this, url);
    }

    /// As `parse`, decoding in a Rive job off the main lane.
    parseAsync(text: string): Promise<Group> {
        return parseOBJAsync(text);
    }

    parse(text: string): Group {
        const parts = parseOBJParts(text);
        const group = new Group();
        const materials = new Map<string, Material>();
        for (let i = 0; i < parts.length; i++) {
            const part = parts[i];
            if (part.positions.length == 0) continue;
            const g = new BufferGeometry();
            g.setAttribute("position", new Float32BufferAttribute(part.positions, 3));
            const count = part.positions.length / 3;
            if (part.normals.length == part.positions.length) g.setAttribute("normal", new Float32BufferAttribute(part.normals, 3));
            if (part.uvs.length == count * 2) g.setAttribute("uv", new Float32BufferAttribute(part.uvs, 2));
            const hasColors = part.colors.length == part.positions.length;
            if (hasColors) g.setAttribute("color", new Float32BufferAttribute(part.colors, 3));
            addOBJPart(group, materials, g, part.name, part.material, part.kind, hasColors);
        }
        return group;
    }
}

async function loadOBJAsync(loader: OBJLoader, url: string): Promise<Group> {
    const bytes = await fetchBytes(loader, url);
    return await parseOBJAsync(String.UTF8.decode(bytes));
}

async function parseOBJAsync(text: string): Promise<Group> {
    const job = Jobs.run(decodeOBJ, text);
    const settled = await job.promise().settled();
    job.release();
    if (!settled.ok) return await Promise.reject<Group>(settled.error);
    return buildOBJFromDecoded(settled.value);
}

function copyOBJFloats(dst: Float32Array, at: i32, src: Array<f64>, count: i32): i32 {
    for (let i = 0; i < count; i++) dst[at + i] = <f32>src[i];
    return at + count;
}

function addOBJPart(
    group: Group,
    materials: Map<string, Material>,
    g: BufferGeometry,
    name: string,
    materialName: string,
    kind: i32,
    hasColors: bool,
): void {
    const key = materialName + "#" + kind.toString() + (hasColors ? "c" : "");
    let material: Material;
    if (materials.has(key)) material = materials.get(key);
    else {
        if (kind == 1) material = new LineBasicMaterial();
        else if (kind == 2) material = new PointsMaterial({ size: 1, sizeAttenuation: false });
        else material = new MeshPhongMaterial();
        material.name = materialName;
        material.vertexColors = hasColors;
        materials.set(key, material);
    }
    if (kind == 0) {
        if (!g.hasAttribute("normal")) g.computeVertexNormals();
        const mesh = new Mesh(g, material);
        mesh.name = name;
        group.add(mesh);
    } else if (kind == 1) {
        const segments = new LineSegments(g, material);
        segments.name = name;
        group.add(segments);
    } else {
        const points = new Points(g, material);
        points.name = name;
        group.add(points);
    }
}

function parseOBJParts(text: string): Array<ObjPart> {
    const vertices: Array<f64> = [];
    const normals: Array<f64> = [];
    const uvs: Array<f64> = [];
    const colors: Array<f64> = [];
    const parts: Array<ObjPart> = [];
    let objectName = "";
    let materialName = "";
    let current: ObjPart? = null;

    const lines = text.split("\n");
    for (let li = 0; li < lines.length; li++) {
        let line = lines[li].trim();
        if (line.length == 0 || line.charAt(0) == "#") continue;
        const tokens = splitSpaces(line);
        const keyword = tokens[0];
        if (keyword == "v") {
            vertices.push(F64.parseFloat(tokens[1]));
            vertices.push(F64.parseFloat(tokens[2]));
            vertices.push(F64.parseFloat(tokens[3]));
            if (tokens.length >= 7) {
                colors.push(F64.parseFloat(tokens[4]));
                colors.push(F64.parseFloat(tokens[5]));
                colors.push(F64.parseFloat(tokens[6]));
            } else {
                colors.push(-1); colors.push(-1); colors.push(-1);
            }
        } else if (keyword == "vn") {
            normals.push(F64.parseFloat(tokens[1]));
            normals.push(F64.parseFloat(tokens[2]));
            normals.push(F64.parseFloat(tokens[3]));
        } else if (keyword == "vt") {
            uvs.push(F64.parseFloat(tokens[1]));
            uvs.push(tokens.length > 2 ? F64.parseFloat(tokens[2]) : 0);
        } else if (keyword == "o" || keyword == "g") {
            objectName = tokens.length > 1 ? line.substring(2).trim() : "";
            current = null;
        } else if (keyword == "usemtl") {
            materialName = tokens.length > 1 ? line.substring(7).trim() : "";
            current = null;
        } else if (keyword == "f" || keyword == "l" || keyword == "p") {
            const kind = keyword == "f" ? 0 : keyword == "l" ? 1 : 2;
            let part = current;
            if (part == null || part.kind != kind) {
                part = new ObjPart(objectName, materialName, kind);
                parts.push(part);
                current = part;
            }
            const refs: Array<StaticArray<i32>> = [];
            for (let t = 1; t < tokens.length; t++) {
                refs.push(parseRef(tokens[t], vertices.length / 3, uvs.length / 2, normals.length / 3));
            }
            if (kind == 0) {
                for (let k = 1; k + 1 < refs.length; k++) {
                    addVertex(part, refs[0], vertices, uvs, normals, colors);
                    addVertex(part, refs[k], vertices, uvs, normals, colors);
                    addVertex(part, refs[k + 1], vertices, uvs, normals, colors);
                }
            } else if (kind == 1) {
                for (let k = 0; k + 1 < refs.length; k++) {
                    addVertex(part, refs[k], vertices, uvs, normals, colors);
                    addVertex(part, refs[k + 1], vertices, uvs, normals, colors);
                }
            } else {
                for (let k = 0; k < refs.length; k++) addVertex(part, refs[k], vertices, uvs, normals, colors);
            }
        }
    }
    return parts;
}

function splitSpaces(line: string): Array<string> {
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

/// "v", "v/vt", "v//vn", "v/vt/vn" to zero-based [v, vt, vn] (-1: none);
/// negative indices count back from the end.
function parseRef(token: string, nv: i32, nt: i32, nn: i32): StaticArray<i32> {
    const out: StaticArray<i32> = [-1, -1, -1];
    const fields = token.split("/");
    const counts: StaticArray<i32> = [nv, nt, nn];
    for (let k = 0; k < 3 && k < fields.length; k++) {
        if (fields[k].length == 0) continue;
        const i = I32.parseInt(fields[k]);
        out[k] = i > 0 ? i - 1 : counts[k] + i;
    }
    return out;
}

function addVertex(part: ObjPart, ref: StaticArray<i32>, vertices: Array<f64>, uvs: Array<f64>, normals: Array<f64>,
                   colors: Array<f64>): void {
    const v = ref[0];
    if (v < 0 || v * 3 + 2 >= vertices.length) return;
    part.positions.push(vertices[v * 3]);
    part.positions.push(vertices[v * 3 + 1]);
    part.positions.push(vertices[v * 3 + 2]);
    if (colors[v * 3] >= 0) {
        part.colors.push(colors[v * 3]);
        part.colors.push(colors[v * 3 + 1]);
        part.colors.push(colors[v * 3 + 2]);
    }
    const t = ref[1];
    if (t >= 0 && t * 2 + 1 < uvs.length) {
        part.uvs.push(uvs[t * 2]);
        part.uvs.push(uvs[t * 2 + 1]);
    }
    const n = ref[2];
    if (n >= 0 && n * 3 + 2 < normals.length) {
        part.normals.push(normals[n * 3]);
        part.normals.push(normals[n * 3 + 1]);
        part.normals.push(normals[n * 3 + 2]);
    }
}
