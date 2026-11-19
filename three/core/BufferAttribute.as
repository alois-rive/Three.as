// three.js BufferAttribute. Vertex attributes are f32 (`Float32Array`);
// indices are `Uint32BufferAttribute`s (uploaded as 16 bit when they fit).

import { Matrix3 } from "../math/Matrix3";
import { Matrix4 } from "../math/Matrix4";
import { Vector3 } from "../math/Vector3";
import { Dynamic } from "rive/dynamic";
import { numbersOf } from "./JSON";

export class BufferAttribute {
    readonly isBufferAttribute: bool = true;
    name: string = "";
    array: Float32Array;
    itemSize: i32;
    normalized: bool;
    /// Bumped by `needsUpdate = true`; the renderer re-uploads on change.
    version: i32 = 0;

    constructor(array: Float32Array, itemSize: i32, normalized: bool = false) {
        this.array = array;
        this.itemSize = itemSize;
        this.normalized = normalized;
    }

    get count(): i32 { return this.array.length / this.itemSize; }

    set needsUpdate(value: bool) { if (value) this.version++; }

    getComponent(index: i32, component: i32): f64 { return this.array[index * this.itemSize + component]; }
    setComponent(index: i32, component: i32, value: f64): BufferAttribute {
        this.array[index * this.itemSize + component] = <f32>value;
        return this;
    }

    getX(index: i32): f64 { return this.array[index * this.itemSize]; }
    getY(index: i32): f64 { return this.array[index * this.itemSize + 1]; }
    getZ(index: i32): f64 { return this.array[index * this.itemSize + 2]; }
    getW(index: i32): f64 { return this.array[index * this.itemSize + 3]; }
    setX(index: i32, x: f64): BufferAttribute { this.array[index * this.itemSize] = <f32>x; return this; }
    setY(index: i32, y: f64): BufferAttribute { this.array[index * this.itemSize + 1] = <f32>y; return this; }
    setZ(index: i32, z: f64): BufferAttribute { this.array[index * this.itemSize + 2] = <f32>z; return this; }
    setW(index: i32, w: f64): BufferAttribute { this.array[index * this.itemSize + 3] = <f32>w; return this; }

    setXY(index: i32, x: f64, y: f64): BufferAttribute {
        const o = index * this.itemSize;
        this.array[o] = <f32>x; this.array[o + 1] = <f32>y;
        return this;
    }

    setXYZ(index: i32, x: f64, y: f64, z: f64): BufferAttribute {
        const o = index * this.itemSize;
        this.array[o] = <f32>x; this.array[o + 1] = <f32>y; this.array[o + 2] = <f32>z;
        return this;
    }

    setXYZW(index: i32, x: f64, y: f64, z: f64, w: f64): BufferAttribute {
        const o = index * this.itemSize;
        this.array[o] = <f32>x; this.array[o + 1] = <f32>y; this.array[o + 2] = <f32>z; this.array[o + 3] = <f32>w;
        return this;
    }

    /// Copies `array` in at element `offset`.
    set(array: Array<f64>, offset: i32 = 0): BufferAttribute {
        for (let i = 0; i < array.length; i++) this.array[offset + i] = <f32>array[i];
        return this;
    }

    copy(source: BufferAttribute): BufferAttribute {
        this.name = source.name;
        this.array = source.array.slice();
        this.itemSize = source.itemSize;
        this.normalized = source.normalized;
        return this;
    }

    clone(): BufferAttribute { return new BufferAttribute(this.array.slice(), this.itemSize, this.normalized); }

    /// three.js's JSON: { itemSize, type, array, normalized, name }. The
    /// array is always a "Float32Array" here (interleaved attributes are
    /// written de-interleaved).
    toJSON(): Dynamic {
        const data = Dynamic.newTable();
        data.set("itemSize", Dynamic.fromNumber(<f64>this.itemSize));
        data.set("type", Dynamic.fromString("Float32Array"));
        data.set("array", numbersOf(this.array));
        data.set("normalized", Dynamic.fromBool(this.normalized));
        if (this.name != "") data.set("name", Dynamic.fromString(this.name));
        return data;
    }

    applyMatrix3(m: Matrix3): BufferAttribute {
        for (let i = 0, l = this.count; i < l; i++) {
            _v.set(this.getX(i), this.getY(i), this.getZ(i)).applyMatrix3(m);
            this.setXYZ(i, _v.x, _v.y, _v.z);
        }
        return this;
    }

    applyMatrix4(m: Matrix4): BufferAttribute {
        for (let i = 0, l = this.count; i < l; i++) {
            _v.set(this.getX(i), this.getY(i), this.getZ(i)).applyMatrix4(m);
            this.setXYZ(i, _v.x, _v.y, _v.z);
        }
        return this;
    }

    applyNormalMatrix(m: Matrix3): BufferAttribute {
        for (let i = 0, l = this.count; i < l; i++) {
            _v.set(this.getX(i), this.getY(i), this.getZ(i)).applyNormalMatrix(m);
            this.setXYZ(i, _v.x, _v.y, _v.z);
        }
        return this;
    }

    transformDirection(m: Matrix4): BufferAttribute {
        for (let i = 0, l = this.count; i < l; i++) {
            _v.set(this.getX(i), this.getY(i), this.getZ(i)).transformDirection(m);
            this.setXYZ(i, _v.x, _v.y, _v.z);
        }
        return this;
    }
}

/// A float attribute from a plain number array, as three.js.
export class Float32BufferAttribute extends BufferAttribute {
    constructor(array: Array<f64>, itemSize: i32, normalized: bool = false) {
        const a = new Float32Array(array.length);
        for (let i = 0; i < array.length; i++) a[i] = <f32>array[i];
        super(a, itemSize, normalized);
    }
}

/// An index attribute. The renderer uploads it as 16 bit indices when every
/// index fits.
export class Uint32BufferAttribute {
    readonly isBufferAttribute: bool = true;
    array: Uint32Array;
    readonly itemSize: i32 = 1;
    version: i32 = 0;

    constructor(array: Array<i32>) {
        const a = new Uint32Array(array.length);
        for (let i = 0; i < array.length; i++) a[i] = <u32>array[i];
        this.array = a;
    }

    get count(): i32 { return this.array.length; }
    set needsUpdate(value: bool) { if (value) this.version++; }
    getX(index: i32): i32 { return <i32>this.array[index]; }
    setX(index: i32, value: i32): Uint32BufferAttribute { this.array[index] = <u32>value; return this; }

    /// three.js's index JSON: { type, array }, "Uint16Array" when every
    /// index fits 16 bits, else "Uint32Array".
    toJSON(): Dynamic {
        const a = this.array;
        const values = new Array<f64>(a.length);
        let max: u32 = 0;
        for (let i = 0; i < a.length; i++) {
            values[i] = <f64>a[i];
            if (a[i] > max) max = a[i];
        }
        const data = Dynamic.newTable();
        data.set("type", Dynamic.fromString(max < 65535 ? "Uint16Array" : "Uint32Array"));
        data.set("array", Dynamic.fromNumbers(values));
        return data;
    }
}

/// Same storage as Uint32BufferAttribute (kept for three.js signatures).
export class Uint16BufferAttribute extends Uint32BufferAttribute {
    constructor(array: Array<i32>) {
        super(array);
    }
}

const _v: Vector3 = new Vector3();
