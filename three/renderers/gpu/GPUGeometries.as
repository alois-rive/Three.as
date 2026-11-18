// GPU buffers of BufferGeometries (internal to GPURenderer), like three.js's
// WebGLGeometries: one vertex buffer per attribute (position, normal, uv;
// zeros stand in for a missing normal or uv) and an index buffer, uint16
// when every index fits. Re-uploaded when an attribute's version changes.

import { GPUBuffer } from "rive/gpu";
import { BufferUsage, IndexFormat } from "rive/gpu_enums";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute, Uint32BufferAttribute } from "../../core/BufferAttribute";

export const LINE_STRIP: i32 = 0;
export const LINE_LOOP: i32 = 1;
export const LINE_SEGMENTS: i32 = 2;
export const LINE_WIREFRAME: i32 = 3;

export class GeometryGPU {
    position: GPUBuffer? = null;
    normal: GPUBuffer? = null;
    uv: GPUBuffer? = null;
    /// RGBA per vertex (white when the geometry has no "color").
    color: GPUBuffer? = null;
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

    release(): void {
        for (let i = 0; i < 4; i++) {
            releaseBuffer(this.lineBuffers[i]);
            this.lineBuffers[i] = null;
            this.lineStamps[i] = -1;
        }
        releaseBuffer(this.position); this.position = null;
        releaseBuffer(this.normal); this.normal = null;
        releaseBuffer(this.uv); this.uv = null;
        releaseBuffer(this.color); this.color = null;
        releaseBuffer(this.index); this.index = null;
    }
}

export class GPUGeometries {
    private map: Map<i32, GeometryGPU> = new Map<i32, GeometryGPU>();

    /// The geometry's buffers, uploading what changed. Null when it has no
    /// position attribute.
    get(geometry: BufferGeometry): GeometryGPU? {
        const position = geometry.getAttribute("position");
        if (position == null || position.count == 0) return null;
        let g: GeometryGPU;
        if (this.map.has(geometry.id)) g = this.map.get(geometry.id);
        else {
            g = new GeometryGPU();
            this.map.set(geometry.id, g);
        }
        const vertexCount = position.count;
        const resized = vertexCount != g.vertexCount;
        g.vertexCount = vertexCount;

        if (resized || g.positionAttr !== position || g.positionVersion != position.version) {
            g.position = upload(g.position, position.array);
            g.positionAttr = position;
            g.positionVersion = position.version;
        }

        const normal = geometry.getAttribute("normal");
        if (normal != null && normal.count == vertexCount) {
            if (resized || g.normalAttr !== normal || g.normalVersion != normal.version) {
                g.normal = upload(g.normal, normal.array);
                g.normalAttr = normal;
                g.normalVersion = normal.version;
            }
        } else if (resized || g.normal == null || g.normalAttr != null) {
            g.normal = upload(g.normal, new Float32Array(vertexCount * 3));
            g.normalAttr = null;
        }

        // Dashed lines read "lineDistance" through the uv slot.
        let uv = geometry.getAttribute("uv");
        if (uv == null) {
            const d = geometry.getAttribute("lineDistance");
            if (d != null && d.count == vertexCount) {
                if (resized || g.uvAttr !== d || g.uvVersion != d.version) {
                    const a = new Float32Array(vertexCount * 2);
                    for (let i = 0; i < vertexCount; i++) a[i * 2] = d.array[i];
                    g.uv = upload(g.uv, a);
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
                g.uv = upload(g.uv, uv.array);
                g.uvAttr = uv;
                g.uvVersion = uv.version;
            }
        } else if (resized || g.uv == null || g.uvAttr != null) {
            g.uv = upload(g.uv, new Float32Array(vertexCount * 2));
            g.uvAttr = null;
        }

        const color = geometry.getAttribute("color");
        if (color != null && color.count == vertexCount && (color.itemSize == 3 || color.itemSize == 4)) {
            if (resized || g.colorAttr !== color || g.colorVersion != color.version) {
                g.color = upload(g.color, toRGBA(color, vertexCount));
                g.colorAttr = color;
                g.colorVersion = color.version;
            }
        } else if (resized || g.color == null || g.colorAttr != null) {
            const white = new Float32Array(vertexCount * 4);
            white.fill(1);
            g.color = upload(g.color, white);
            g.colorAttr = null;
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
                g.index = uploadBytes(g.index, BufferUsage.index, bytes);
                g.indexVersion = index.version;
            }
            g.indexed = true;
            g.count = index.count;
        } else {
            if (g.index != null) { releaseBuffer(g.index); g.index = null; }
            g.indexed = false;
            g.indexFormat = IndexFormat.none;
            g.count = vertexCount;
        }
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
        g.lineBuffers[mode] = uploadBytes(g.lineBuffers[mode], BufferUsage.index, bytes);
        return true;
    }

    dispose(id: i32): void {
        if (this.map.has(id)) {
            this.map.get(id).release();
            this.map.delete(id);
        }
    }

    disposeAll(): void {
        const values = this.map.values();
        for (let i = 0; i < values.length; i++) values[i].release();
        this.map.clear();
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

function upload(existing: GPUBuffer?, data: Float32Array): GPUBuffer {
    return uploadBytes(existing, BufferUsage.vertex, wholeBuffer(data.buffer, data.byteOffset, data.byteLength));
}

function uploadBytes(existing: GPUBuffer?, usage: BufferUsage, bytes: ArrayBuffer): GPUBuffer {
    const size = <u32>bytes.byteLength;
    if (existing != null && existing.size == size) {
        existing.update(0, bytes);
        return existing;
    }
    releaseBuffer(existing);
    return new GPUBuffer(usage, size, bytes);
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
