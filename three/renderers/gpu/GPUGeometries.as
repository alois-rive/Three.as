// GPU buffers of BufferGeometries (internal to GPURenderer), like three.js's
// WebGLGeometries: one vertex buffer per attribute (position, normal, uv;
// zeros stand in for a missing normal or uv) and an index buffer, uint16
// when every index fits. Re-uploaded when an attribute's version changes.

import { GPUBuffer } from "rive/gpu";
import { BufferUsage, IndexFormat } from "rive/gpu_enums";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute } from "../../core/BufferAttribute";

export class GeometryGPU {
    position: GPUBuffer? = null;
    normal: GPUBuffer? = null;
    uv: GPUBuffer? = null;
    index: GPUBuffer? = null;
    indexFormat: IndexFormat = IndexFormat.none;
    /// Indices when indexed, else vertices.
    count: i32 = 0;
    vertexCount: i32 = 0;
    indexed: bool = false;

    positionVersion: i32 = -1;
    normalVersion: i32 = -1;
    uvVersion: i32 = -1;
    indexVersion: i32 = -1;
    positionAttr: BufferAttribute? = null;
    normalAttr: BufferAttribute? = null;
    uvAttr: BufferAttribute? = null;

    release(): void {
        releaseBuffer(this.position); this.position = null;
        releaseBuffer(this.normal); this.normal = null;
        releaseBuffer(this.uv); this.uv = null;
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

        const uv = geometry.getAttribute("uv");
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
