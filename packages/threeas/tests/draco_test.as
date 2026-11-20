// Draco (M15): the decoder ported to AnimaScript (three/addons/libs/draco),
// DRACOLoader, and GLTFLoader's KHR_draco_mesh_compression: rive . --test
//
// Fixtures (tests/fixtures/), all downloaded as data:
// - bunny.drc: three.js r170 examples/models/draco/bunny.drc (MIT, the
//   Stanford bunny), bitstream 1.1, Edgebreaker. Its reference numbers are
//   from bun_zipper.ply in Draco's testdata (the same bunny: 34834 used
//   vertices, 69451 faces).
// - Google Draco's testdata (Apache License 2.0, draco 1.5.7 testdata/):
//   test_nm.obj and its encodings by Draco 0.9.1 to 1.5 (bitstreams 1.1 to
//   2.2, sequential and Edgebreaker, standard and valence), cube_att.obj and
//   its encodings (cube_att_v1.1.drc is testdata's cube_att.drc, renamed
//   apart from the .obj), pc_kd_color.drc (kd-tree, 2.3), pc_color.drc,
//   point_cloud_no_qp.drc, cube_pc.drc (point clouds) and
//   octagon_preserved.drc (metadata).
// - Khronos glTF-Sample-Assets (github.com/KhronosGroup/glTF-Sample-Assets),
//   each model's glTF-Draco variant and its uncompressed glTF one: Box
//   (© 2017 Cesium, CC BY 4.0) as downloaded with the .gltf files renamed
//   (box_draco.gltf + Box.bin, box_uncompressed.gltf + Box0.bin); Avocado
//   and WaterBottle (CC0 1.0) and RiggedSimple (© 2017 Cesium, CC BY 4.0)
//   packed into <name>_draco.glb and <name>.glb by
//   tools/make_draco_samples.py (both variants name their buffer alike).
//   WaterBottle is the valence Edgebreaker case, RiggedSimple the integer
//   (JOINTS_0) attribute.

import { Tests, Expect } from "rive/test";
import * as THREE from "../three/Three";
import {
    Decoder, Mesh, PointCloud, PointAttribute, POSITION, NORMAL, TEX_COORD, COLOR, GENERIC, TRIANGULAR_MESH,
    POINT_CLOUD, INVALID_GEOMETRY_TYPE, DT_UINT8, DT_INT32,
} from "../three/addons/libs/draco/draco_decoder";
import { CornerTable, MeshAttributeIndicesEncodingData } from "../three/addons/libs/draco/corner_table";
import {
    MeshPredictionSchemeData, MeshPredictionSchemeTexCoordsPortableDecoder, PredictionSchemeWrapDecodingTransform,
} from "../three/addons/libs/draco/prediction_schemes";
import { MeshPredictionSchemeTexCoordsDecoder } from "../three/addons/libs/draco/tex_coords_deprecated";
import { DRACOLoader, decodeDraco } from "../three/addons/loaders/DRACOLoader";
import { GLTFLoader, GLTFData, decodeGLTF } from "../three/addons/loaders/GLTFLoader";

// ------------------------------------------------------------ helpers

/// A Draco file decoded with the decoder's own API.
class Decoded {
    status: string = "";
    pc: PointCloud = new PointCloud();
}

function decodeFile(bytes: Uint8Array): Decoded {
    const out = new Decoded();
    const decoder = new Decoder();
    const type = decoder.GetEncodedGeometryType(bytes);
    if (type == TRIANGULAR_MESH) {
        const mesh = new Mesh();
        out.status = decoder.DecodeArrayToMesh(bytes, bytes.length, mesh).error_msg();
        out.pc = mesh;
    } else if (type == POINT_CLOUD) {
        out.status = decoder.DecodeArrayToPointCloud(bytes, bytes.length, out.pc).error_msg();
    } else {
        out.status = "not draco";
    }
    return out;
}

function floatsOf(pc: PointCloud, type: i32): Float32Array {
    const decoder = new Decoder();
    const id = decoder.GetAttributeId(pc, type);
    if (id < 0) return new Float32Array(0);
    return decoder.GetAttributeFloatForAllPoints(pc, decoder.GetAttribute(pc, id));
}

/// An OBJ's positions, normals, uvs and triangle corners (0-based; -1 when
/// a corner has none).
class Obj {
    v: Array<f64> = [];
    vn: Array<f64> = [];
    vt: Array<f64> = [];
    fv: Array<i32> = [];
    fn: Array<i32> = [];
    ft: Array<i32> = [];
}

function parseObj(text: string): Obj {
    const obj = new Obj();
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
        const parts = lines[i].trim().split(" ").filter((s: string): bool => s.length > 0);
        if (parts.length == 0) continue;
        const kind = parts[0];
        if (kind == "v") for (let k = 1; k <= 3; k++) obj.v.push(parseFloat(parts[k]));
        else if (kind == "vn") for (let k = 1; k <= 3; k++) obj.vn.push(parseFloat(parts[k]));
        else if (kind == "vt") for (let k = 1; k <= 2; k++) obj.vt.push(parseFloat(parts[k]));
        else if (kind == "f") {
            for (let k = 1; k <= 3; k++) {
                const ids = parts[k].split("/");
                obj.fv.push(<i32>parseInt(ids[0]) - 1);
                obj.ft.push(ids.length > 1 && ids[1].length > 0 ? <i32>parseInt(ids[1]) - 1 : -1);
                obj.fn.push(ids.length > 2 && ids[2].length > 0 ? <i32>parseInt(ids[2]) - 1 : -1);
            }
        }
    }
    return obj;
}

/// Triangles as corners of attribute values: corner c of triangle t is
/// values[(t * 3 + c) * width .. + width].
class Corners {
    width: i32;
    values: Array<f64> = [];
    count: i32 = 0;

    constructor(width: i32) {
        this.width = width;
    }

    push(v: Array<f64>): void {
        for (let i = 0; i < v.length; i++) this.values.push(v[i]);
    }
}

/// The corners of an indexed mesh, from per-point attributes (each
/// `itemSizes[k]` floats, all concatenated per corner).
function meshCorners(index: Uint32Array, attributes: Array<Float32Array>, itemSizes: Array<i32>): Corners {
    let width = 0;
    for (let k = 0; k < itemSizes.length; k++) width += itemSizes[k];
    const out = new Corners(width);
    const v: Array<f64> = [];
    for (let i = 0; i < index.length; i++) {
        v.length = 0;
        const p = <i32>index[i];
        for (let k = 0; k < attributes.length; k++) {
            for (let c = 0; c < itemSizes[k]; c++) v.push(attributes[k][p * itemSizes[k] + c]);
        }
        out.push(v);
    }
    out.count = index.length / 3;
    return out;
}

/// Whether every triangle of `a` matches one of `b` (one to one, any order,
/// corners rotated but not flipped), each value within tolerances[k] for
/// its column. The number of unmatched triangles.
function unmatchedTriangles(a: Corners, b: Corners, tolerances: Array<f64>): i32 {
    if (a.width != b.width || a.count != b.count) return max<i32>(a.count, b.count);
    const w = a.width;
    const used = new Uint8Array(b.count);
    // b's triangles by the x of their centroid: a match's centroid is within
    // the x tolerance.
    const order: Array<i32> = [];
    const cx = new Float64Array(b.count);
    for (let u = 0; u < b.count; u++) {
        order.push(u);
        cx[u] = (b.values[u * 3 * w] + b.values[(u * 3 + 1) * w] + b.values[(u * 3 + 2) * w]) / 3;
    }
    order.sort((x: i32, y: i32): i32 => cx[x] < cx[y] ? -1 : cx[x] > cx[y] ? 1 : 0);
    const sorted = new Float64Array(b.count);
    for (let i = 0; i < b.count; i++) sorted[i] = cx[order[i]];
    let unmatched = 0;
    for (let t = 0; t < a.count; t++) {
        let found = false;
        const x = (a.values[t * 3 * w] + a.values[(t * 3 + 1) * w] + a.values[(t * 3 + 2) * w]) / 3;
        let lo = 0, hi = b.count;
        while (lo < hi) {
            const mid = (lo + hi) >> 1;
            if (sorted[mid] < x - tolerances[0]) lo = mid + 1;
            else hi = mid;
        }
        for (let s = lo; s < b.count && sorted[s] <= x + tolerances[0] && !found; s++) {
            const u = order[s];
            if (used[u] != 0) continue;
            for (let rot = 0; rot < 3 && !found; rot++) {
                let ok = true;
                for (let c = 0; c < 3 && ok; c++) {
                    const ao = (t * 3 + c) * w;
                    const bo = (u * 3 + (c + rot) % 3) * w;
                    for (let k = 0; k < w && ok; k++) {
                        if (Math.abs(a.values[ao + k] - b.values[bo + k]) > tolerances[k]) ok = false;
                    }
                }
                if (ok) {
                    found = true;
                    used[u] = 1;
                }
            }
        }
        if (!found) unmatched++;
    }
    return unmatched;
}

function tolerances(spec: Array<f64>, sizes: Array<i32>): Array<f64> {
    const out: Array<f64> = [];
    for (let k = 0; k < sizes.length; k++) for (let c = 0; c < sizes[k]; c++) out.push(spec[k]);
    return out;
}

/// The OBJ's corners: position, then (unit) normal and uv when asked.
function objCorners(obj: Obj, normals: bool, uvs: bool, unitNormals: bool): Corners {
    const out = new Corners(3 + (normals ? 3 : 0) + (uvs ? 2 : 0));
    const v: Array<f64> = [];
    for (let i = 0; i < obj.fv.length; i++) {
        v.length = 0;
        const p = obj.fv[i];
        v.push(obj.v[p * 3]); v.push(obj.v[p * 3 + 1]); v.push(obj.v[p * 3 + 2]);
        if (normals) {
            const n = obj.fn[i];
            let x = obj.vn[n * 3], y = obj.vn[n * 3 + 1], z = obj.vn[n * 3 + 2];
            if (unitNormals) {
                const l = Math.sqrt(x * x + y * y + z * z);
                if (l > 0) { x /= l; y /= l; z /= l; } else { x = 1; y = 0; z = 0; }
            }
            v.push(x); v.push(y); v.push(z);
        }
        if (uvs) {
            const t = obj.ft[i];
            v.push(obj.vt[t * 2]); v.push(obj.vt[t * 2 + 1]);
        }
        out.push(v);
    }
    out.count = obj.fv.length / 3;
    return out;
}

/// The OBJ's triangles with zero-length normals dropped (Draco's octahedral
/// coding gives them a direction), as a mask over its faces.
function objZeroNormalFaces(obj: Obj): Uint8Array {
    const out = new Uint8Array(obj.fv.length / 3);
    for (let i = 0; i < obj.fv.length; i++) {
        const n = obj.fn[i];
        if (n < 0) continue;
        if (obj.vn[n * 3] == 0 && obj.vn[n * 3 + 1] == 0 && obj.vn[n * 3 + 2] == 0) out[i / 3] = 1;
    }
    return out;
}

function withoutFaces(c: Corners, mask: Uint8Array): Corners {
    const out = new Corners(c.width);
    for (let t = 0; t < c.count; t++) {
        if (mask[t] != 0) continue;
        for (let k = 0; k < c.width * 3; k++) out.values.push(c.values[t * 3 * c.width + k]);
        out.count++;
    }
    return out;
}

/// Drops decoded triangles whose OBJ counterpart has zero normals: those
/// whose positions match a masked OBJ triangle.
function withoutMatching(c: Corners, obj: Obj, mask: Uint8Array, tol: f64): Corners {
    const out = new Corners(c.width);
    for (let t = 0; t < c.count; t++) {
        let drop = false;
        for (let f = 0; f < mask.length && !drop; f++) {
            if (mask[f] == 0) continue;
            for (let rot = 0; rot < 3 && !drop; rot++) {
                let ok = true;
                for (let k = 0; k < 3 && ok; k++) {
                    const p = obj.fv[f * 3 + (k + rot) % 3];
                    for (let a = 0; a < 3 && ok; a++) {
                        if (Math.abs(c.values[(t * 3 + k) * c.width + a] - obj.v[p * 3 + a]) > tol) ok = false;
                    }
                }
                if (ok) drop = true;
            }
        }
        if (drop) continue;
        for (let k = 0; k < c.width * 3; k++) out.values.push(c.values[t * 3 * c.width + k]);
        out.count++;
    }
    return out;
}

function indexOf(pc: PointCloud): Uint32Array {
    return new Decoder().GetTrianglesUInt32Array(pc as Mesh);
}

@editTime
function expectNear(expect: Expect, actual: f64, expected: f64, tolerance: f64): void {
    if (Math.abs(actual - expected) <= tolerance) expect.that(true).is(true);
    else expect.that(actual).is(expected);
}

/// A glTF geometry's corners (position [, normal] [, uv]).
function geometryCorners(g: THREE.BufferGeometry, normals: bool, uvs: bool): Corners {
    const attributes: Array<Float32Array> = [g.getAttribute("position")!.array];
    const sizes: Array<i32> = [3];
    if (normals) { attributes.push(g.getAttribute("normal")!.array); sizes.push(3); }
    if (uvs) { attributes.push(g.getAttribute("uv")!.array); sizes.push(2); }
    return meshCorners(g.index!.array, attributes, sizes);
}

function firstMesh(root: THREE.Object3D): THREE.Mesh? {
    if (root instanceof THREE.Mesh) return root as THREE.Mesh;
    for (let i = 0; i < root.children.length; i++) {
        const m = firstMesh(root.children[i]);
        if (m != null) return m;
    }
    return null;
}

function pushVarint(out: Array<u8>, value: u32): void {
    while (value >= 0x80) {
        out.push(<u8>((value & 0x7F) | 0x80));
        value >>= 7;
    }
    out.push(<u8>value);
}

/// Draco's raw-scheme symbol encoding (RAnsSymbolEncoder and the rANS
/// coder of compression/entropy/ans.h, encoding side), for streams no
/// fixture has: SYMBOL_CODING_RAW, the bit length, the probability table,
/// then the rANS bytes.
function encodeRawSymbols(symbols: Array<u32>, out: Array<u8>): void {
    let maxSymbol: u32 = 0;
    for (let i = 0; i < symbols.length; i++) maxSymbol = max<u32>(maxSymbol, symbols[i]);
    const bitLength = max<i32>(1, 32 - <i32>clz<u32>(maxSymbol));
    const p = (3 * bitLength) / 2;
    const precisionBits = p < 12 ? 12 : p > 20 ? 20 : p;
    const precision: u32 = <u32>1 << <u32>precisionBits;
    const numSymbols = <i32>maxSymbol + 1;
    const counts = new Float64Array(numSymbols);
    for (let i = 0; i < symbols.length; i++) counts[symbols[i]] += 1;
    const probs = new Uint32Array(numSymbols);
    let sum: u32 = 0, largest = 0;
    for (let s = 0; s < numSymbols; s++) {
        if (counts[s] == 0) continue;
        probs[s] = max<u32>(1, <u32>Math.floor(counts[s] * <f64>precision / <f64>symbols.length));
        sum += probs[s];
        if (probs[s] > probs[largest]) largest = s;
    }
    probs[largest] += precision - sum;
    const cum = new Uint32Array(numSymbols);
    let c: u32 = 0;
    for (let s = 0; s < numSymbols; s++) {
        cum[s] = c;
        c += probs[s];
    }
    out.push(1);   // SYMBOL_CODING_RAW
    out.push(<u8>bitLength);
    pushVarint(out, <u32>numSymbols);
    for (let s = 0; s < numSymbols; s++) {
        const prob = probs[s];
        if (prob < 64) {
            out.push(<u8>(prob << 2));
        } else if (prob < (1 << 14)) {
            out.push(<u8>(((prob & 0x3F) << 2) | 1));
            out.push(<u8>(prob >> 6));
        } else {
            out.push(<u8>(((prob & 0x3F) << 2) | 2));
            out.push(<u8>(prob >> 6));
            out.push(<u8>(prob >> 14));
        }
    }
    const base: u32 = precision * 4;
    let state: u32 = base;
    const data: Array<u8> = [];
    for (let i = symbols.length - 1; i >= 0; i--) {
        const s = symbols[i];
        const ps = probs[s];
        while (state >= base / precision * 256 * ps) {
            data.push(<u8>(state % 256));
            state /= 256;
        }
        state = (state / ps) * precision + state % ps + cum[s];
    }
    state -= base;
    if (state < (1 << 6)) {
        data.push(<u8>state);
    } else if (state < (1 << 14)) {
        const v = (<u32>0x01 << 14) + state;
        data.push(<u8>v); data.push(<u8>(v >> 8));
    } else if (state < (1 << 22)) {
        const v = (<u32>0x02 << 22) + state;
        data.push(<u8>v); data.push(<u8>(v >> 8)); data.push(<u8>(v >> 16));
    } else {
        const v = (<u32>0x03 << 30) + state;
        data.push(<u8>v); data.push(<u8>(v >> 8)); data.push(<u8>(v >> 16)); data.push(<u8>(v >> 24));
    }
    pushVarint(out, <u32>data.length);
    for (let i = 0; i < data.length; i++) out.push(data[i]);
}

/// A sequential mesh (bitstream 2.2, raw indices of one byte, no metadata)
/// rewritten with compressed indices (connectivity method 0, which Draco's
/// encoder writes only with its compress_connectivity option).
function compressSequentialIndices(bytes: Uint8Array): Uint8Array {
    let at = 11;
    let numFaces: u32 = 0, shift: u32 = 0;
    while (true) {
        const b = <u32>bytes[at++];
        numFaces |= (b & 0x7F) << shift;
        shift += 7;
        if ((b & 0x80) == 0) break;
    }
    const pointsAt = at;
    while ((bytes[at] & 0x80) != 0) at++;
    at++;
    const out: Array<u8> = [];
    for (let i = 0; i < pointsAt; i++) out.push(bytes[i]);
    for (let i = pointsAt; i < at; i++) out.push(bytes[i]);
    if (bytes[at] != 1) return new Uint8Array(0);   // not raw indices
    at++;
    out.push(0);
    const symbols: Array<u32> = [];
    let last: i32 = 0;
    for (let i = 0; i < <i32>numFaces * 3; i++) {
        const index = <i32>bytes[at++];
        const diff = index - last;
        symbols.push(diff < 0 ? (<u32>(-diff) << 1) | 1 : <u32>diff << 1);
        last = index;
    }
    encodeRawSymbols(symbols, out);
    for (let i = at; i < bytes.length; i++) out.push(bytes[i]);
    const result = new Uint8Array(out.length);
    for (let i = 0; i < out.length; i++) result[i] = out[i];
    return result;
}

const TEST_NM: StaticArray<string> = [
    "test_nm.obj.edgebreaker.cl4.2.2", "test_nm.obj.edgebreaker.cl10.2.2", "test_nm.obj.sequential.cl3.2.2",
    "test_nm.obj.edgebreaker.1.1.0", "test_nm.obj.edgebreaker.1.0.0", "test_nm.obj.edgebreaker.0.10.0",
    "test_nm.obj.edgebreaker.0.9.1", "test_nm.obj.sequential.1.1.0", "test_nm.obj.sequential.1.0.0",
    "test_nm.obj.sequential.0.10.0", "test_nm.obj.sequential.0.9.1", "test_nm_quant.0.9.0",
];

const CUBE_ATT: StaticArray<string> = [
    "cube_att.obj.edgebreaker.cl10.2.2", "cube_att.obj.edgebreaker.cl4.2.2", "cube_att.obj.sequential.cl3.2.2",
    "cube_att_v1.1",
];

export class DracoTests extends Tests {
    override run(): void {
        group("Draco decoder", () => {
            test("header and errors", (expect) => {
                const decoder = new Decoder();
                const junk = new Uint8Array(16);
                expect.that(decoder.GetEncodedGeometryType(junk)).is(INVALID_GEOMETRY_TYPE);
                const blob = this.blob("bunny");
                if (blob == null) return;
                const bytes = Uint8Array.wrap(blob!);
                expect.that(decoder.GetEncodedGeometryType(bytes)).is(TRIANGULAR_MESH);
                // Truncated: an error, not a trap.
                const cut = bytes.slice(0, 2000);
                const mesh = new Mesh();
                const status = decoder.DecodeArrayToMesh(cut, cut.length, mesh);
                expect.that(status.ok()).is(false);
                expect.that(status.error_msg().length > 0).is(true);
                // A mesh decoded as a point cloud.
                expect.that(decoder.DecodeArrayToPointCloud(bytes, bytes.length, new PointCloud()).ok()).is(false);
            });

            test("bunny.drc: three.js's bunny (bitstream 1.1, Edgebreaker)", (expect) => {
                const blob = this.blob("bunny");
                if (blob == null) return;
                const d = decodeFile(Uint8Array.wrap(blob!));
                expect.that(d.status).is("");
                const mesh = d.pc as Mesh;
                expect.that(mesh.numPoints).is(34834);
                expect.that(mesh.numFaces).is(69451);
                const p = floatsOf(mesh, POSITION);
                const index = indexOf(mesh);
                let inRange = true;
                for (let i = 0; i < index.length; i++) if (index[i] >= <u32>mesh.numPoints) inRange = false;
                expect.that(inRange).is(true);
                // bun_zipper.ply's used vertices: their sum, the surface area
                // and the signed volume (connectivity and orientation).
                let sx: f64 = 0, sy: f64 = 0, sz: f64 = 0;
                for (let i = 0; i < mesh.numPoints; i++) {
                    sx += p[i * 3];
                    sy += p[i * 3 + 1];
                    sz += p[i * 3 + 2];
                }
                // Quantization: 0.16 m over (likely) 11+ bits, a few 1e-5 a point.
                expectNear(expect, sx, -928.76631185173, 1.0);
                expectNear(expect, sy, 3305.819644, 1.0);
                expectNear(expect, sz, 313.193918045529, 1.0);
                let area: f64 = 0, volume: f64 = 0;
                for (let f = 0; f < mesh.numFaces; f++) {
                    const a = <i32>index[f * 3] * 3, b = <i32>index[f * 3 + 1] * 3, c = <i32>index[f * 3 + 2] * 3;
                    const ux = p[b] - p[a], uy = p[b + 1] - p[a + 1], uz = p[b + 2] - p[a + 2];
                    const vx = p[c] - p[a], vy = p[c + 1] - p[a + 1], vz = p[c + 2] - p[a + 2];
                    const cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx;
                    area += Math.sqrt(cx * cx + cy * cy + cz * cz) / 2;
                    volume += (<f64>p[a] * (<f64>p[b + 1] * p[c + 2] - <f64>p[b + 2] * p[c + 1])
                        - <f64>p[a + 1] * (<f64>p[b] * p[c + 2] - <f64>p[b + 2] * p[c])
                        + <f64>p[a + 2] * (<f64>p[b] * p[c + 1] - <f64>p[b + 1] * p[c])) / 6;
                }
                expectNear(expect, area, 0.057128783477919554, 0.0005);
                expectNear(expect, volume, 0.0007700565241248492, 0.00001);
            });

            test("test_nm.obj, bitstreams 1.1 to 2.2: positions, normals, triangles", (expect) => {
                const text = this.blob("test_nm");
                if (text == null) return;
                const obj = parseObj(String.UTF8.decode(text!));
                const zero = objZeroNormalFaces(obj);
                for (let f = 0; f < TEST_NM.length; f++) {
                    const blob = this.blob(TEST_NM[f]);
                    if (blob == null) continue;
                    const d = decodeFile(Uint8Array.wrap(blob!));
                    expect.that(d.status == "" ? TEST_NM[f] : TEST_NM[f] + ": " + d.status).is(TEST_NM[f]);
                    if (d.status != "") continue;
                    const mesh = d.pc as Mesh;
                    expect.that(mesh.numFaces).is(170);
                    const p = floatsOf(mesh, POSITION);
                    const n = floatsOf(mesh, NORMAL);
                    // Normals: older encoders kept the OBJ's (unnormalized)
                    // vectors, octahedral ones are unit length.
                    let raw = false;
                    for (let i = 0; i < n.length; i += 3) {
                        if (Math.sqrt(n[i] * n[i] + n[i + 1] * n[i + 1] + n[i + 2] * n[i + 2]) > 1.5) raw = true;
                    }
                    const decoded = meshCorners(indexOf(mesh), [p, n], [3, 3]);
                    const reference = objCorners(obj, true, false, !raw);
                    const tol = tolerances([0.002, raw ? 0.01 : 0.03], [3, 3]);
                    let unmatched: i32;
                    if (raw) {
                        unmatched = unmatchedTriangles(decoded, reference, tol);
                    } else {
                        unmatched = unmatchedTriangles(withoutMatching(decoded, obj, zero, 0.002), withoutFaces(reference, zero), tol);
                    }
                    expect.that(TEST_NM[f] + " unmatched " + unmatched.toString()).is(TEST_NM[f] + " unmatched 0");
                }
            });

            test("cube_att.obj: seams, corner attributes, tex coords and normals", (expect) => {
                const text = this.blob("cube_att");
                if (text == null) return;
                const obj = parseObj(String.UTF8.decode(text!));
                const reference = objCorners(obj, true, true, true);
                for (let f = 0; f < CUBE_ATT.length; f++) {
                    const blob = this.blob(CUBE_ATT[f]);
                    if (blob == null) continue;
                    const d = decodeFile(Uint8Array.wrap(blob!));
                    expect.that(d.status == "" ? CUBE_ATT[f] : CUBE_ATT[f] + ": " + d.status).is(CUBE_ATT[f]);
                    if (d.status != "") continue;
                    const mesh = d.pc as Mesh;
                    expect.that(mesh.numFaces).is(12);
                    expect.that(mesh.numPoints).is(24);
                    const decoded = meshCorners(indexOf(mesh),
                        [floatsOf(mesh, POSITION), floatsOf(mesh, NORMAL), floatsOf(mesh, TEX_COORD)], [3, 3, 2]);
                    const unmatched = unmatchedTriangles(decoded, reference, tolerances([0.001, 0.01, 0.001], [3, 3, 2]));
                    expect.that(CUBE_ATT[f] + " unmatched " + unmatched.toString()).is(CUBE_ATT[f] + " unmatched 0");
                }
            });

            test("point clouds: sequential and kd-tree (2.3), raw and quantized", (expect) => {
                const kd = this.blob("pc_kd_color");
                const seq = this.blob("pc_color");
                if (kd == null || seq == null) return;
                const a = decodeFile(Uint8Array.wrap(kd!));
                const b = decodeFile(Uint8Array.wrap(seq!));
                expect.that(a.status).is("");
                expect.that(b.status).is("");
                expect.that(a.pc.numPoints).is(7733);
                expect.that(b.pc.numPoints).is(7733);
                // The same cloud, in another order: equal colour sums, near
                // position sums.
                const ca = floatsOf(a.pc, COLOR), cb = floatsOf(b.pc, COLOR);
                const pa = floatsOf(a.pc, POSITION), pb = floatsOf(b.pc, POSITION);
                expect.that(a.pc.attribute(a.pc.getNamedAttributeId(COLOR)).dataType).is(DT_UINT8);
                for (let c = 0; c < 3; c++) {
                    let sa: f64 = 0, sb: f64 = 0, qa: f64 = 0, qb: f64 = 0;
                    for (let i = 0; i < 7733; i++) {
                        sa += ca[i * 3 + c];
                        sb += cb[i * 3 + c];
                        qa += pa[i * 3 + c];
                        qb += pb[i * 3 + c];
                    }
                    expect.that(sa).is(sb);
                    expectNear(expect, qa / 7733, qb / 7733, 0.05);
                }
                const noQp = this.blob("point_cloud_no_qp");
                if (noQp != null) {
                    const d = decodeFile(Uint8Array.wrap(noQp!));
                    expect.that(d.status).is("");
                    expect.that(d.pc.numPoints).is(21);
                }
                // cube_pc.drc (bitstream 1.1): the cube's 24 corners.
                const cube = this.blob("cube_pc");
                if (cube != null) {
                    const d = decodeFile(Uint8Array.wrap(cube!));
                    expect.that(d.status).is("");
                    expect.that(d.pc.numPoints).is(24);
                    const p = floatsOf(d.pc, POSITION);
                    let onCorners = true;
                    for (let i = 0; i < p.length; i++) if (Math.abs(p[i]) > 0.001 && Math.abs(p[i] - 1) > 0.001) onCorners = false;
                    expect.that(onCorners).is(true);
                }
            });

            test("sequential connectivity with compressed indices", (expect) => {
                const blob = this.blob("test_nm.obj.sequential.cl3.2.2");
                if (blob == null) return;
                const raw = Uint8Array.wrap(blob!);
                const compressed = compressSequentialIndices(raw);
                expect.that(compressed.length > 0).is(true);
                const a = decodeFile(raw);
                const b = decodeFile(compressed);
                expect.that(b.status).is("");
                if (b.status != "") return;
                const ia = indexOf(a.pc), ib = indexOf(b.pc);
                let same = ia.length == ib.length && ia.length == 510;
                for (let i = 0; i < ia.length && same; i++) if (ia[i] != ib[i]) same = false;
                expect.that(same).is(true);
                const pa = floatsOf(a.pc, POSITION), pb = floatsOf(b.pc, POSITION);
                let samePositions = pa.length == pb.length;
                for (let i = 0; i < pa.length && samePositions; i++) if (pa[i] != pb[i]) samePositions = false;
                expect.that(samePositions).is(true);
            });

            test("metadata", (expect) => {
                const blob = this.blob("octagon_preserved");
                if (blob == null) return;
                const d = decodeFile(Uint8Array.wrap(blob!));
                expect.that(d.status).is("");
                const metadata = d.pc.metadata;
                expect.that(metadata != null).is(true);
                if (metadata == null) return;
                expect.that(metadata.attributeMetadatas.length).is(1);
                const generic = d.pc.attribute(d.pc.getNamedAttributeId(GENERIC));
                const att = metadata.getAttributeMetadataByUniqueId(generic.uniqueId);
                expect.that(att != null).is(true);
                if (att != null) expect.that(att.getEntryString("name")).is("added_edges");
            });

            test("tex-coord predictors prefer prevDataId when prevDataId < dataId <= nextDataId", (expect) => {
                // Single triangle: corners 0->v0, 1->v1, 2->v2.
                // Data IDs: v0 -> 0, v1 -> 2, v2 -> 3, plus an unrelated dataId 1 on v3.
                // For dataId = 2 (corner 1): previous corner is 0 (prevDataId = 0 < 2),
                // next corner is 2 (nextDataId = 3 >= 2). Prediction must copy data[0]
                // (prevDataId * 2), NOT data[2] ((dataId - 1) * 2).
                const ct = new CornerTable();
                ct.reset(2, 4);
                ct.mapCornerToVertex(0, 0);
                ct.mapCornerToVertex(1, 1);
                ct.mapCornerToVertex(2, 2);
                ct.mapCornerToVertex(3, 3);
                ct.mapCornerToVertex(4, 2);
                ct.mapCornerToVertex(5, 0);
                ct.vertexCount = 4;
                const enc = new MeshAttributeIndicesEncodingData();
                enc.encodedAttributeValueIndexToCornerMap = [0, 3, 1, 2]; // v0, v3, v1 (prev=v0->0, next=v2->3), v2
                enc.vertexToEncodedAttributeValueIndexMap = new Int32Array(4);
                enc.vertexToEncodedAttributeValueIndexMap[0] = 0;
                enc.vertexToEncodedAttributeValueIndexMap[1] = 2;
                enc.vertexToEncodedAttributeValueIndexMap[2] = 3;
                enc.vertexToEncodedAttributeValueIndexMap[3] = 1;
                const meshData = new MeshPredictionSchemeData(ct, enc);
                const posAttr = new PointAttribute();
                posAttr.attributeType = POSITION;
                posAttr.numComponents = 3;
                posAttr.dataType = DT_INT32;
                posAttr.byteStride = 12;
                posAttr.buffer = new ArrayBuffer(4 * 12);
                const uvAttr = new PointAttribute();
                uvAttr.attributeType = TEX_COORD;
                uvAttr.numComponents = 2;
                const entryToPoint = new Int32Array(4);
                for (let i = 0; i < 4; i++) entryToPoint[i] = i;

                // Portable tex-coord predictor
                const t1 = new PredictionSchemeWrapDecodingTransform();
                t1.minValue = -1000; t1.maxValue = 1000; t1.maxDif = 2001;
                const portable = new MeshPredictionSchemeTexCoordsPortableDecoder(uvAttr, t1, meshData);
                expect.that(portable.setParentAttribute(posAttr)).is(true);
                const data1 = new Int32Array(8);
                // Corrections: dataId 0 -> (10, 20), dataId 1 -> (+90, +80) => (100, 100),
                // dataId 2 -> (0, 0) => should predict from prevDataId=0 => (10, 20), NOT (100, 100)!
                data1[0] = 10; data1[1] = 20;
                data1[2] = 90; data1[3] = 80;
                data1[4] = 0; data1[5] = 0;
                data1[6] = 0; data1[7] = 0;
                expect.that(portable.computeOriginalValues(data1, 8, 2, entryToPoint)).is(true);
                expect.that(data1[4]).is(10);
                expect.that(data1[5]).is(20);

                // Deprecated tex-coord predictor
                const t2 = new PredictionSchemeWrapDecodingTransform();
                t2.minValue = -1000; t2.maxValue = 1000; t2.maxDif = 2001;
                const deprecated = new MeshPredictionSchemeTexCoordsDecoder(uvAttr, t2, meshData, 0);
                expect.that(deprecated.setParentAttribute(posAttr)).is(true);
                const data2 = new Int32Array(8);
                data2[0] = 10; data2[1] = 20;
                data2[2] = 90; data2[3] = 80;
                data2[4] = 0; data2[5] = 0;
                data2[6] = 0; data2[7] = 0;
                expect.that(deprecated.computeOriginalValues(data2, 8, 2, entryToPoint)).is(true);
                expect.that(data2[4]).is(10);
                expect.that(data2[5]).is(20);
            });
        });

        group("DRACOLoader", () => {
            test("parse: a .drc to a BufferGeometry", (expect) => {
                const blob = this.blob("bunny");
                if (blob == null) return;
                const loader = new DRACOLoader();
                const geometry = loader.parse(blob!);
                expect.that(loader.error).is("");
                if (geometry == null) return;
                expect.that(geometry.getAttribute("position")!.count).is(34834);
                expect.that(geometry.index!.count).is(69451 * 3);
                expect.that(geometry.getAttribute("normal") == null).is(true);
                expect.that(loader.parse(new ArrayBuffer(8)) == null).is(true);
                expect.that(loader.error.length > 0).is(true);
            });

            test("decodeDraco (the async job) matches parse", (expect) => {
                const blob = this.blob("cube_att.obj.edgebreaker.cl10.2.2");
                if (blob == null) return;
                const loader = new DRACOLoader();
                const data = decodeDraco(blob!, loader.taskConfig(null, null, THREE.SRGBColorSpace));
                expect.that(data.error).is("");
                const a = loader.createGeometry(data);
                const b = loader.parse(blob!)!;
                for (let k = 0; k < 3; k++) {
                    const name = k == 0 ? "position" : k == 1 ? "normal" : "uv";
                    const x = a.getAttribute(name)!.array, y = b.getAttribute(name)!.array;
                    let same = x.length == y.length && x.length > 0;
                    for (let i = 0; i < x.length && same; i++) if (x[i] != y[i]) same = false;
                    expect.that(name + (same ? " same" : " differs")).is(name + " same");
                }
                expect.that(a.index!.count).is(36);
            });

            test("colours: normalized as asked, sRGB to linear for .drc", (expect) => {
                const blob = this.blob("pc_color");
                if (blob == null) return;
                const loader = new DRACOLoader();
                // Float32Array (the default): Draco's values, not normalized
                // (this file's colours are not flagged normalized).
                const raw = loader.decodeDracoFile(blob!, null, null, THREE.LinearSRGBColorSpace)!;
                expect.that(raw.getAttribute("color")!.array[0] > 1).is(true);
                const types = new Map<string, string>();
                types.set("color", "Uint8Array");
                const normalized = loader.decodeDracoFile(blob!, null, types, THREE.LinearSRGBColorSpace)!;
                const c = normalized.getAttribute("color")!;
                let inRange = true;
                for (let i = 0; i < c.array.length; i++) if (c.array[i] < 0 || c.array[i] > 1) inRange = false;
                expect.that(inRange).is(true);
                const r = raw.getAttribute("color")!;
                expectNear(expect, c.array[0], r.array[0] / 255, 1e-6);
                const srgb = loader.decodeDracoFile(blob!, null, types, THREE.SRGBColorSpace)!.getAttribute("color")!;
                expectNear(expect, srgb.array[0], THREE.SRGBToLinear(c.array[0]), 1e-6);
                expect.that(raw.index == null).is(true);
                expect.that(raw.getAttribute("position")!.count).is(7733);
            });
        });

        group("GLTFLoader KHR_draco_mesh_compression", () => {
            test("without setDRACOLoader a file requiring it fails", (expect) => {
                const bytes = this.blob("avocado_draco");
                if (bytes == null) return;
                const loader = new GLTFLoader();
                expect.that(loader.parse(bytes!) == null).is(true);
                expect.that(loader.error).is("No DRACOLoader instance provided.");
            });

            test("Avocado: positions, normals and uvs match the uncompressed glTF", (expect) => {
                const compressed = this.blob("avocado_draco");
                const plain = this.blob("avocado");
                if (compressed == null || plain == null) return;
                const loader = new GLTFLoader().setDRACOLoader(new DRACOLoader());
                const a = loader.parse(compressed!);
                expect.that(loader.error).is("");
                const b = new GLTFLoader().parse(plain!);
                if (a == null || b == null) return;
                const ma = firstMesh(a.scene)!, mb = firstMesh(b.scene)!;
                const ga = ma.geometry, gb = mb.geometry;
                expect.that(ga.index!.count).is(2046);
                expect.that(gb.index!.count).is(2046);
                // Positions span ~0.06; Draco's default quantization steps
                // are well under these.
                const unmatched = unmatchedTriangles(geometryCorners(ga, true, true), geometryCorners(gb, true, true),
                    tolerances([0.0002, 0.02, 0.002], [3, 3, 2]));
                expect.that(unmatched).is(0);
                expect.that(ma.name).is(mb.name);
            });

            test("WaterBottle: valence Edgebreaker matches the uncompressed glTF", (expect) => {
                const compressed = this.blob("water_bottle_draco");
                const plain = this.blob("water_bottle");
                if (compressed == null || plain == null) return;
                const loader = new GLTFLoader().setDRACOLoader(new DRACOLoader());
                const a = loader.parse(compressed!);
                expect.that(loader.error).is("");
                const b = new GLTFLoader().parse(plain!);
                if (a == null || b == null) return;
                const ga = firstMesh(a.scene)!.geometry, gb = firstMesh(b.scene)!.geometry;
                expect.that(ga.index!.count).is(13530);
                const unmatched = unmatchedTriangles(geometryCorners(ga, true, true), geometryCorners(gb, true, true),
                    tolerances([0.0005, 0.02, 0.002], [3, 3, 2]));
                expect.that(unmatched).is(0);
            });

            test("RiggedSimple: joints (uint16) and weights", (expect) => {
                const compressed = this.blob("rigged_simple_draco");
                const plain = this.blob("rigged_simple");
                if (compressed == null || plain == null) return;
                const loader = new GLTFLoader().setDRACOLoader(new DRACOLoader());
                const a = loader.parse(compressed!);
                expect.that(loader.error).is("");
                const b = new GLTFLoader().parse(plain!);
                if (a == null || b == null) return;
                const ma = firstMesh(a.scene)!, mb = firstMesh(b.scene)!;
                expect.that(ma instanceof THREE.SkinnedMesh).is(true);
                const ga = ma.geometry, gb = mb.geometry;
                const corners = (g: THREE.BufferGeometry): Corners => meshCorners(g.index!.array,
                    [g.getAttribute("position")!.array, g.getAttribute("skinIndex")!.array, g.getAttribute("skinWeight")!.array],
                    [3, 4, 4]);
                // Positions: 11 bits over the 9.15 m length, steps of 0.0045.
                const unmatched = unmatchedTriangles(corners(ga), corners(gb), tolerances([0.0023, 0, 0.002], [3, 4, 4]));
                expect.that(unmatched).is(0);
            });

            test("Box (.gltf + .bin): positions and normals, the async job", (expect) => {
                const gltf = this.blob("box_draco");
                const bin = this.blob("Box");
                const plainGltf = this.blob("box_uncompressed");
                const plainBin = this.blob("Box0");
                if (gltf == null || bin == null || plainGltf == null || plainBin == null) return;
                // The external buffer as load() resolves it ("Box.bin" -> "Box").
                const loader = new GLTFLoader().setDRACOLoader(new DRACOLoader());
                const gd = new GLTFData(gltf!, null);
                gd.draco = true;
                gd.external.set(0, Uint8Array.wrap(bin!));
                const a = loader.parseData(gd);
                expect.that(loader.error).is("");
                const pd = new GLTFData(plainGltf!, null);
                pd.external.set(0, Uint8Array.wrap(plainBin!));
                const b = new GLTFLoader().parseData(pd);
                if (a == null || b == null) return;
                const ga = firstMesh(a.scene)!.geometry, gb = firstMesh(b.scene)!.geometry;
                expect.that(ga.getAttribute("position")!.count).is(24);
                const tol = tolerances([0.001, 0.01], [3, 3]);
                expect.that(unmatchedTriangles(geometryCorners(ga, true, false), geometryCorners(gb, true, false), tol)).is(0);

                // loadAsync / parseAsync: the job decodes the Draco primitive.
                const decoded = decodeGLTF(gltf!, false, [bin!], [0], true);
                expect.that(decoded.error).is("");
                expect.that(decoded.dracoViews.length).is(1);
                const jd = new GLTFData(gltf!, null);
                jd.external.set(0, Uint8Array.wrap(bin!));
                jd.setDecoded(decoded);
                const c = new GLTFLoader().setDRACOLoader(new DRACOLoader()).parseData(jd);
                if (c == null) return;
                const gc = firstMesh(c.scene)!.geometry;
                const x = gc.getAttribute("position")!.array, y = ga.getAttribute("position")!.array;
                let same = x.length == y.length;
                for (let i = 0; i < x.length && same; i++) if (x[i] != y[i]) same = false;
                expect.that(same).is(true);
                expect.that(gc.index!.count).is(36);
            });

            test("the job's Draco data serves a loader without the decoder", (expect) => {
                const compressed = this.blob("avocado_draco");
                if (compressed == null) return;
                const decoded = decodeGLTF(compressed!, false, [], [], true);
                expect.that(decoded.error).is("");
                expect.that(decoded.dracoData.length).is(1);
                expect.that(decoded.dracoData[0].error).is("");
                const gd = new GLTFData(compressed!, null);
                gd.setDecoded(decoded);
                const loader = new GLTFLoader();
                const gltf = loader.parseData(gd);
                expect.that(loader.error).is("");
                if (gltf == null) return;
                expect.that(firstMesh(gltf.scene)!.geometry.getAttribute("uv")!.count).is(406);
            });
        });
    }
}
