// GPU buffers of BufferGeometries (internal to GPURenderer), like three.js's
// WebGLGeometries: one vertex buffer per attribute (position, normal, uv;
// zeros stand in for a missing normal or uv) and an index buffer, uint16
// when every index fits. Re-uploaded when an attribute's version changes.
// Kept on the geometry (Disposal), freed by geometry.dispose() or with the
// geometry.

import { GPUBuffer } from "rive/gpu";
import { BufferUsage, IndexFormat } from "rive/gpu_enums";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute, Uint32BufferAttribute } from "../../core/BufferAttribute";
import { RendererData } from "../../core/RendererData";
import { DisposeQueue, DisposeListener, DISPOSED_GEOMETRY, RendererSlot, dataOf, setDataOf, detach } from "./Disposal";

export const LINE_STRIP: i32 = 0;
export const LINE_LOOP: i32 = 1;
export const LINE_SEGMENTS: i32 = 2;
export const LINE_WIREFRAME: i32 = 3;

const MUT_POS: u32 = 1 << 0;
const MUT_NRM: u32 = 1 << 1;
const MUT_UV: u32 = 1 << 2;
const MUT_UV1: u32 = 1 << 3;
const MUT_COL: u32 = 1 << 4;
const MUT_SKIN: u32 = 1 << 5;
const MUT_IDX: u32 = 1 << 6;
const MUT_LINE_SHIFT: u32 = 7;

export class GeometryGPU extends RendererData {
    /// The render (view) it was last brought up to date in.
    frame: i32 = -1;
    /// Slots whose GPUBuffer is mutable (buffers start immutable for static
    /// meshes so the host keeps no CPU copy, and become mutable on first update).
    mutableMask: u32 = 0;
    position: GPUBuffer? = null;
    normal: GPUBuffer? = null;
    uv: GPUBuffer? = null;
    /// "uv1", or the uv buffer when there is none.
    uv1: GPUBuffer? = null;
    uv1Version: i32 = -1;
    uv1Attr: BufferAttribute? = null;
    /// RGBA per vertex (white when the geometry has no "color").
    color: GPUBuffer? = null;
    /// Skinning: joint indices and weights as float4 (null without them).
    /// skinIndex and skinWeight interleaved (32 bytes a vertex: Rive allows
    /// 8 vertex buffers a pipeline).
    skin: GPUBuffer? = null;
    tangentAttr: BufferAttribute? = null;
    tangentVersion: i32 = -1;
    /// Whether slot 1 carries the geometry's "tangent" attribute.
    hasTangents: bool = false;
    skinIndexVersion: i32 = -1;
    skinWeightVersion: i32 = -1;
    private skinStaging: Float32Array = new Float32Array(0);
    index: GPUBuffer? = null;
    indexFormat: IndexFormat = IndexFormat.none;
    /// Indices when indexed, else vertices.
    count: i32 = 0;
    vertexCount: i32 = 0;
    indexed: bool = false;

    positionVersion: i32 = -1;
    normalVersion: i32 = -1;
    uvVersion: i32 = -1;
    colorVersion: i32 = -1;
    indexVersion: i32 = -1;
    positionAttr: BufferAttribute? = null;
    normalAttr: BufferAttribute? = null;
    uvAttr: BufferAttribute? = null;
    colorAttr: BufferAttribute? = null;

    // Generated line-list indices per line mode (LINE_*).
    lineBuffers: StaticArray<GPUBuffer?> = new StaticArray<GPUBuffer?>(4);
    lineFormats: StaticArray<IndexFormat> = new StaticArray<IndexFormat>(4);
    lineCounts: StaticArray<i32> = new StaticArray<i32>(4);
    lineStamps: StaticArray<i64> = [-1, -1, -1, -1];
    /// Its geometry's "dispose" (Disposal).
    listener: DisposeListener? = null;
    /// The renderer's morph texture and wide line segments of the geometry
    /// (GPURenderer's MorphTargetsGPU and WideLineGPU), released with it.
    morphTargets: RendererData? = null;
    wideLine: RendererData? = null;

    /// Index then weight, 8 floats a vertex.
    interleaveSkin(index: Float32Array, weight: Float32Array, count: i32): Float32Array {
        if (this.skinStaging.length != count * 8) this.skinStaging = new Float32Array(count * 8);
        const out = this.skinStaging;
        for (let v = 0; v < count; v++) {
            for (let k = 0; k < 4; k++) {
                out[v * 8 + k] = index[v * 4 + k];
                out[v * 8 + 4 + k] = weight[v * 4 + k];
            }
        }
        return out;
    }

    override release(): void {
        detach(this.listener);
        this.listener = null;
        const mt = this.morphTargets;
        if (mt != null) mt.release();
        this.morphTargets = null;
        const wl = this.wideLine;
        if (wl != null) wl.release();
        this.wideLine = null;
        for (let i = 0; i < 4; i++) {
            releaseBuffer(this.lineBuffers[i]);
            this.lineBuffers[i] = null;
            this.lineStamps[i] = -1;
        }
        releaseBuffer(this.position); this.position = null;
        releaseBuffer(this.normal); this.normal = null;
        releaseBuffer(this.uv); this.uv = null;
        if (this.uv1Attr != null) releaseBuffer(this.uv1);
        this.uv1 = null;
        releaseBuffer(this.color); this.color = null;
        releaseBuffer(this.skin); this.skin = null;
        releaseBuffer(this.index); this.index = null;
        this.mutableMask = 0;
    }
}

export class GPUGeometries {
    private queue: DisposeQueue;
    private slot: RendererSlot;
    private _count: i32 = 0;

    constructor(queue: DisposeQueue, slot: RendererSlot) {
        this.queue = queue;
        this.slot = slot;
    }

    /// The geometry's buffers as they are (null when none).
    peek(geometry: BufferGeometry): GeometryGPU? {
        const d = dataOf(geometry, this.slot);
        return d != null ? d as GeometryGPU : null;
    }

    /// The geometry's buffers, uploading what changed. Null when it has no
    /// position attribute. With a `frame` (the renderer's view counter), a
    /// geometry already checked in that view is returned as it is.
    get(geometry: BufferGeometry, frame: i32 = -1): GeometryGPU? {
        const kept = dataOf(geometry, this.slot);
        if (kept != null && frame >= 0 && (kept as GeometryGPU).frame == frame) return kept as GeometryGPU;
        const position = geometry.getAttribute("position");
        if (position == null || position.count == 0) return null;
        let g: GeometryGPU;
        if (kept != null) g = kept as GeometryGPU;
        else {
            g = new GeometryGPU();
            setDataOf(geometry, this.slot, g);
            g.listener = new DisposeListener(this.queue, DISPOSED_GEOMETRY, g).attach(geometry);
            this._count++;
        }
        const vertexCount = position.count;
        const resized = vertexCount != g.vertexCount;
        g.vertexCount = vertexCount;

        if (resized || g.positionAttr !== position || g.positionVersion != position.version) {
            g.position = uploadAttr(g, MUT_POS, g.position, position);
            g.positionAttr = position;
            g.positionVersion = position.version;
        }

        // Normals and tangents share slot 1 (7 floats a vertex; zero
        // tangents when there are none).
        const normal = geometry.getAttribute("normal");
        const tangent = geometry.getAttribute("tangent");
        const hasNormal = normal != null && normal.count == vertexCount;
        const hasTangent = tangent != null && tangent.count == vertexCount && tangent.itemSize == 4;
        const nv = hasNormal ? normal!.version : -1;
        const tv = hasTangent ? tangent!.version : -1;
        if (resized || g.normal == null || g.normalAttr !== (hasNormal ? normal : null) || g.normalVersion != nv
                || g.tangentAttr !== (hasTangent ? tangent : null) || g.tangentVersion != tv) {
            g.normal = upload(g, MUT_NRM, g.normal, interleaveNormalTangent(hasNormal ? normal!.array : null,
                hasTangent ? tangent!.array : null, vertexCount));
            g.normalAttr = hasNormal ? normal : null;
            g.normalVersion = nv;
            g.tangentAttr = hasTangent ? tangent : null;
            g.tangentVersion = tv;
            g.hasTangents = hasTangent;
        }

        // Dashed lines read "lineDistance" through the uv slot.
        let uv = geometry.getAttribute("uv");
        if (uv == null) {
            const d = geometry.getAttribute("lineDistance");
            if (d != null && d.count == vertexCount) {
                if (resized || g.uvAttr !== d || g.uvVersion != d.version) {
                    const a = new Float32Array(vertexCount * 2);
                    for (let i = 0; i < vertexCount; i++) a[i * 2] = d.array[i];
                    g.uv = upload(g, MUT_UV, g.uv, a);
                    g.uvAttr = d;
                    g.uvVersion = d.version;
                }
                uv = d;
            }
        }
        if (uv != null && uv.itemSize == 1) {
            // lineDistance, uploaded above.
        } else
        if (uv != null && uv.count == vertexCount) {
            if (resized || g.uvAttr !== uv || g.uvVersion != uv.version) {
                g.uv = uploadAttr(g, MUT_UV, g.uv, uv);
                g.uvAttr = uv;
                g.uvVersion = uv.version;
            }
        } else if (resized || g.uv == null || g.uvAttr != null) {
            g.uv = upload(g, MUT_UV, g.uv, new Float32Array(vertexCount * 2));
            g.uvAttr = null;
        }

        // The second UV set (texture.channel 1), or the first again.
        const uv1 = geometry.getAttribute("uv1");
        if (uv1 != null && uv1.itemSize == 2 && uv1.count == vertexCount) {
            if (resized || g.uv1Attr !== uv1 || g.uv1Version != uv1.version) {
                g.uv1 = uploadAttr(g, MUT_UV1, g.uv1Attr != null ? g.uv1 : null, uv1);
                g.uv1Attr = uv1;
                g.uv1Version = uv1.version;
            }
        } else {
            if (g.uv1Attr != null) {
                releaseBuffer(g.uv1);
                g.mutableMask &= ~MUT_UV1;
            }
            g.uv1 = g.uv;
            g.uv1Attr = null;
        }

        const color = geometry.getAttribute("color");
        if (color != null && color.count == vertexCount && (color.itemSize == 3 || color.itemSize == 4)) {
            if (resized || g.colorAttr !== color || g.colorVersion != color.version) {
                g.color = color.itemSize == 4
                    ? uploadAttr(g, MUT_COL, g.color, color)
                    : upload(g, MUT_COL, g.color, toRGBA(color, vertexCount));
                g.colorAttr = color;
                g.colorVersion = color.version;
            }
        } else if (resized || g.color == null || g.colorAttr != null) {
            const white = new Float32Array(vertexCount * 4);
            white.fill(1);
            g.color = upload(g, MUT_COL, g.color, white);
            g.colorAttr = null;
        }

        const si = geometry.getAttribute("skinIndex");
        const sw = geometry.getAttribute("skinWeight");
        if (si != null && sw != null && si.itemSize == 4 && sw.itemSize == 4 && si.count == vertexCount
                && sw.count == vertexCount) {
            if (resized || g.skin == null || g.skinIndexVersion != si.version || g.skinWeightVersion != sw.version) {
                g.skin = upload(g, MUT_SKIN, g.skin, g.interleaveSkin(si.array, sw.array, vertexCount));
                g.skinIndexVersion = si.version;
                g.skinWeightVersion = sw.version;
            }
        }

        const index = geometry.index;
        if (index != null && index.count > 0) {
            if (!g.indexed || g.indexVersion != index.version || g.count != index.count) {
                const src = index.array;
                let maxIndex: u32 = 0;
                for (let i = 0; i < src.length; i++) if (src[i] > maxIndex) maxIndex = src[i];
                let bytes: ArrayBuffer;
                if (maxIndex < 65535) {
                    // uint16, padded to a multiple of 4 bytes
                    const n = (src.length + 1) & ~1;
                    const a = new Uint16Array(n);
                    for (let i = 0; i < src.length; i++) a[i] = <u16>src[i];
                    bytes = a.buffer;
                    g.indexFormat = IndexFormat.uint16;
                } else {
                    bytes = wholeBuffer(src.buffer, src.byteOffset, src.byteLength);
                    g.indexFormat = IndexFormat.uint32;
                }
                g.index = uploadBytes(g, MUT_IDX, g.index, BufferUsage.index, bytes);
                g.indexVersion = index.version;
            }
            g.indexed = true;
            g.count = index.count;
        } else {
            if (g.index != null) {
                releaseBuffer(g.index);
                g.index = null;
                g.mutableMask &= ~MUT_IDX;
            }
            g.indexed = false;
            g.indexFormat = IndexFormat.none;
            g.count = vertexCount;
        }
        g.frame = frame;
        return g;
    }

    /// Line-list indices drawing `geometry` as `mode` (LINE_STRIP for Line,
    /// LINE_LOOP, LINE_SEGMENTS, LINE_WIREFRAME for triangle edges). Fills
    /// g.lineBuffers/lineFormats/lineCounts[mode]; false when empty.
    lines(geometry: BufferGeometry, g: GeometryGPU, mode: i32): bool {
        const index = geometry.index;
        const stamp: i64 = (index != null ? (<i64>index.version + 1) << 33 | (<i64>index.count << 1) | 1 : 0)
            ^ (<i64>g.vertexCount << 40);
        if (g.lineStamps[mode] == stamp) return g.lineCounts[mode] > 0;
        g.lineStamps[mode] = stamp;
        const n = index != null ? index.count : g.vertexCount;
        const out: Array<u32> = [];
        if (mode == LINE_WIREFRAME) {
            for (let t = 0; t + 2 < n; t += 3) {
                const a = seq(index, t), b = seq(index, t + 1), c = seq(index, t + 2);
                out.push(a); out.push(b); out.push(b); out.push(c); out.push(c); out.push(a);
            }
        } else if (mode == LINE_SEGMENTS) {
            for (let i = 0; i + 1 < n; i += 2) { out.push(seq(index, i)); out.push(seq(index, i + 1)); }
        } else {
            for (let i = 0; i + 1 < n; i++) { out.push(seq(index, i)); out.push(seq(index, i + 1)); }
            if (mode == LINE_LOOP && n > 2) { out.push(seq(index, n - 1)); out.push(seq(index, 0)); }
        }
        g.lineCounts[mode] = out.length;
        if (out.length == 0) return false;
        let maxIndex: u32 = 0;
        for (let i = 0; i < out.length; i++) if (out[i] > maxIndex) maxIndex = out[i];
        let bytes: ArrayBuffer;
        if (maxIndex < 65535) {
            const a = new Uint16Array((out.length + 1) & ~1);
            for (let i = 0; i < out.length; i++) a[i] = <u16>out[i];
            bytes = a.buffer;
            g.lineFormats[mode] = IndexFormat.uint16;
        } else {
            const a = new Uint32Array(out.length);
            for (let i = 0; i < out.length; i++) a[i] = out[i];
            bytes = a.buffer;
            g.lineFormats[mode] = IndexFormat.uint32;
        }
        g.lineBuffers[mode] = uploadBytes(g, <u32>1 << (MUT_LINE_SHIFT + <u32>mode), g.lineBuffers[mode], BufferUsage.index, bytes);
        return true;
    }

    /// Frees a disposed geometry's buffers.
    free(g: GeometryGPU): void {
        if (g.serial != this.slot.serial) return;
        g.release();
        g.serial = -1;
        this._count--;
    }

    /// Geometries with GPU buffers, not disposed
    /// (renderer.info.memory.geometries).
    get count(): i32 { return this._count; }

    /// renderer.dispose(): what is on geometries is left to be collected
    /// (or released when replaced).
    reset(): void {
        this._count = 0;
    }
}

/// A colour attribute as RGBA floats (alpha 1 for RGB).
function toRGBA(color: BufferAttribute, count: i32): Float32Array {
    if (color.itemSize == 4) return color.array;
    const out = new Float32Array(count * 4);
    const src = color.array;
    for (let i = 0; i < count; i++) {
        out[i * 4] = src[i * 3];
        out[i * 4 + 1] = src[i * 3 + 1];
        out[i * 4 + 2] = src[i * 3 + 2];
        out[i * 4 + 3] = 1;
    }
    return out;
}

function seq(index: Uint32BufferAttribute?, i: i32): u32 {
    return index != null ? index.array[i] : <u32>i;
}

function uploadAttr(g: GeometryGPU, bit: u32, existing: GPUBuffer?, attr: BufferAttribute): GPUBuffer {
    const blob = attr._blob;
    if (existing == null && blob != null && blob.id != 0 && attr.version == 0
            && attr._blobBytes > 0 && attr._blobBytes == <u32>attr.array.byteLength) {
        g.mutableMask &= ~bit;
        const buf = GPUBuffer.fromBlob(BufferUsage.vertex, blob, true, attr._blobBytes, attr._blobOffset);
        attr._blob = null;
        return buf;
    }
    return upload(g, bit, existing, attr.array);
}

function upload(g: GeometryGPU, bit: u32, existing: GPUBuffer?, data: Float32Array): GPUBuffer {
    return uploadBytes(g, bit, existing, BufferUsage.vertex, wholeBuffer(data.buffer, data.byteOffset, data.byteLength));
}

function uploadBytes(g: GeometryGPU, bit: u32, existing: GPUBuffer?, usage: BufferUsage, bytes: ArrayBuffer): GPUBuffer {
    const size = <u32>bytes.byteLength;
    if (existing == null) {
        // First upload: immutable so the host keeps no CPU shadow copy of
        // static meshes.
        g.mutableMask &= ~bit;
        return new GPUBuffer(usage, size, bytes, true);
    }
    if ((g.mutableMask & bit) != 0 && existing.size == size) {
        existing.update(0, bytes);
        return existing;
    }
    releaseBuffer(existing);
    g.mutableMask |= bit;
    return new GPUBuffer(usage, size, bytes, false);
}

/// `buffer`'s bytes [offset, offset + length), without copying when that is
/// all of it.
function wholeBuffer(buffer: ArrayBuffer, offset: i32, length: i32): ArrayBuffer {
    if (offset == 0 && length == buffer.byteLength) return buffer;
    return buffer.slice(offset, offset + length);
}

function releaseBuffer(b: GPUBuffer?): void {
    if (b != null) b.release();
}

/// Normals (3 floats) and tangents (4) interleaved, 28 bytes a vertex, as
/// vertex slot 1 holds them; missing ones are zero.
export function interleaveNormalTangent(normals: Float32Array?, tangents: Float32Array?,
                                        count: i32): Float32Array {
    const out = new Float32Array(count * 7);
    for (let v = 0; v < count; v++) {
        const o = v * 7;
        if (normals != null) {
            out[o] = normals[v * 3]; out[o + 1] = normals[v * 3 + 1]; out[o + 2] = normals[v * 3 + 2];
        }
        if (tangents != null) {
            out[o + 3] = tangents[v * 4]; out[o + 4] = tangents[v * 4 + 1];
            out[o + 5] = tangents[v * 4 + 2]; out[o + 6] = tangents[v * 4 + 3];
        }
    }
    return out;
}
