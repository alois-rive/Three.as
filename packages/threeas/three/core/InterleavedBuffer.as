// three.js InterleavedBuffer and InterleavedBufferAttribute: several
// attributes in one array, `stride` floats per vertex. The renderer uploads
// attributes separately, so an InterleavedBufferAttribute is a
// BufferAttribute whose `array` is its own (dense) copy, kept in step:
// its setters write both, and `buffer.needsUpdate = true` (after writing
// `buffer.array` directly) refreshes every attribute made from it.

import { BufferAttribute } from "./BufferAttribute";

export class InterleavedBuffer {
    readonly isInterleavedBuffer: bool = true;
    array: Float32Array;
    stride: i32;
    version: i32 = 0;
    /// The attributes reading this buffer (internal).
    attributes: Array<InterleavedBufferAttribute> = [];

    constructor(array: Float32Array, stride: i32) {
        this.array = array;
        this.stride = stride;
    }

    get count(): i32 { return this.array.length / this.stride; }

    set needsUpdate(value: bool) {
        if (!value) return;
        this.version++;
        for (let i = 0; i < this.attributes.length; i++) this.attributes[i].pull();
    }

    clone(): InterleavedBuffer {
        return new InterleavedBuffer(this.array.slice(), this.stride);
    }
}

export class InterleavedBufferAttribute extends BufferAttribute {
    readonly isInterleavedBufferAttribute: bool = true;
    data: InterleavedBuffer;
    offset: i32;

    constructor(interleavedBuffer: InterleavedBuffer, itemSize: i32, offset: i32, normalized: bool = false) {
        super(new Float32Array(interleavedBuffer.count * itemSize), itemSize, normalized);
        this.data = interleavedBuffer;
        this.offset = offset;
        interleavedBuffer.attributes.push(this);
        this.pull();
    }

    /// Copies this attribute's components out of the interleaved array.
    pull(): void {
        const n = this.data.count, size = this.itemSize, stride = this.data.stride, src = this.data.array;
        if (this.array.length != n * size) this.array = new Float32Array(n * size);
        for (let i = 0; i < n; i++) {
            for (let k = 0; k < size; k++) this.array[i * size + k] = src[i * stride + this.offset + k];
        }
        this.version++;
    }

    override setComponent(index: i32, component: i32, value: f64): BufferAttribute {
        super.setComponent(index, component, value);
        this.data.array[index * this.data.stride + this.offset + component] = <f32>value;
        return this;
    }

    override setXYZ(index: i32, x: f64, y: f64, z: f64): BufferAttribute {
        super.setXYZ(index, x, y, z);
        const o = index * this.data.stride + this.offset;
        const a = this.data.array;
        a[o] = <f32>x;
        if (this.itemSize > 1) a[o + 1] = <f32>y;
        if (this.itemSize > 2) a[o + 2] = <f32>z;
        return this;
    }

    private put(index: i32, component: i32, value: f64): void {
        this.data.array[index * this.data.stride + this.offset + component] = <f32>value;
    }

    override setX(index: i32, x: f64): BufferAttribute { super.setX(index, x); this.put(index, 0, x); return this; }
    override setY(index: i32, y: f64): BufferAttribute { super.setY(index, y); this.put(index, 1, y); return this; }
    override setZ(index: i32, z: f64): BufferAttribute { super.setZ(index, z); this.put(index, 2, z); return this; }
    override setW(index: i32, w: f64): BufferAttribute { super.setW(index, w); this.put(index, 3, w); return this; }

    override setXY(index: i32, x: f64, y: f64): BufferAttribute {
        super.setXY(index, x, y);
        this.put(index, 0, x); this.put(index, 1, y);
        return this;
    }

    override setXYZW(index: i32, x: f64, y: f64, z: f64, w: f64): BufferAttribute {
        super.setXYZW(index, x, y, z, w);
        this.put(index, 0, x); this.put(index, 1, y); this.put(index, 2, z); this.put(index, 3, w);
        return this;
    }

    /// A plain BufferAttribute of the same data (three.js's clone without
    /// the interleaved buffer).
    override clone(): BufferAttribute {
        return new BufferAttribute(this.array.slice(), this.itemSize, this.normalized);
    }
}
