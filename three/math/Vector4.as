// three.js Vector4.

import { Matrix4 } from "./Matrix4";

export class Vector4 {
    x: f64;
    y: f64;
    z: f64;
    w: f64;

    constructor(x: f64 = 0, y: f64 = 0, z: f64 = 0, w: f64 = 1) {
        this.x = x;
        this.y = y;
        this.z = z;
        this.w = w;
    }

    get width(): f64 { return this.z; }
    set width(v: f64) { this.z = v; }
    get height(): f64 { return this.w; }
    set height(v: f64) { this.w = v; }

    set(x: f64, y: f64, z: f64, w: f64): Vector4 { this.x = x; this.y = y; this.z = z; this.w = w; return this; }
    setScalar(s: f64): Vector4 { this.x = s; this.y = s; this.z = s; this.w = s; return this; }
    clone(): Vector4 { return new Vector4(this.x, this.y, this.z, this.w); }
    copy(v: Vector4): Vector4 { this.x = v.x; this.y = v.y; this.z = v.z; this.w = v.w; return this; }
    add(v: Vector4): Vector4 { this.x += v.x; this.y += v.y; this.z += v.z; this.w += v.w; return this; }
    addScaledVector(v: Vector4, s: f64): Vector4 {
        this.x += v.x * s; this.y += v.y * s; this.z += v.z * s; this.w += v.w * s;
        return this;
    }
    sub(v: Vector4): Vector4 { this.x -= v.x; this.y -= v.y; this.z -= v.z; this.w -= v.w; return this; }
    multiplyScalar(s: f64): Vector4 { this.x *= s; this.y *= s; this.z *= s; this.w *= s; return this; }
    divideScalar(s: f64): Vector4 { return this.multiplyScalar(1 / s); }

    applyMatrix4(m: Matrix4): Vector4 {
        const x = this.x, y = this.y, z = this.z, w = this.w;
        const e = m.elements;
        this.x = <f64>e[0] * x + <f64>e[4] * y + <f64>e[8] * z + <f64>e[12] * w;
        this.y = <f64>e[1] * x + <f64>e[5] * y + <f64>e[9] * z + <f64>e[13] * w;
        this.z = <f64>e[2] * x + <f64>e[6] * y + <f64>e[10] * z + <f64>e[14] * w;
        this.w = <f64>e[3] * x + <f64>e[7] * y + <f64>e[11] * z + <f64>e[15] * w;
        return this;
    }

    dot(v: Vector4): f64 { return this.x * v.x + this.y * v.y + this.z * v.z + this.w * v.w; }
    lengthSq(): f64 { return this.dot(this); }
    length(): f64 { return Math.sqrt(this.lengthSq()); }
    normalize(): Vector4 { const l = this.length(); return this.divideScalar(l > 0 ? l : 1); }
    lerp(v: Vector4, t: f64): Vector4 {
        this.x += (v.x - this.x) * t;
        this.y += (v.y - this.y) * t;
        this.z += (v.z - this.z) * t;
        this.w += (v.w - this.w) * t;
        return this;
    }
    equals(v: Vector4): bool { return this.x == v.x && this.y == v.y && this.z == v.z && this.w == v.w; }
}
