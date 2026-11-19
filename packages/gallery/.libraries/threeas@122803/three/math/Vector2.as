// three.js Vector2.

import { Vector } from "rive/vector";
import { Matrix3 } from "./Matrix3";

export class Vector2 {
    x: f64;
    y: f64;

    constructor(x: f64 = 0, y: f64 = 0) {
        this.x = x;
        this.y = y;
    }

    get width(): f64 { return this.x; }
    set width(v: f64) { this.x = v; }
    get height(): f64 { return this.y; }
    set height(v: f64) { this.y = v; }

    set(x: f64, y: f64): Vector2 { this.x = x; this.y = y; return this; }
    setScalar(s: f64): Vector2 { this.x = s; this.y = s; return this; }
    setX(x: f64): Vector2 { this.x = x; return this; }
    setY(y: f64): Vector2 { this.y = y; return this; }
    clone(): Vector2 { return new Vector2(this.x, this.y); }
    copy(v: Vector2): Vector2 { this.x = v.x; this.y = v.y; return this; }

    add(v: Vector2): Vector2 { this.x += v.x; this.y += v.y; return this; }
    addScalar(s: f64): Vector2 { this.x += s; this.y += s; return this; }
    addVectors(a: Vector2, b: Vector2): Vector2 { this.x = a.x + b.x; this.y = a.y + b.y; return this; }
    addScaledVector(v: Vector2, s: f64): Vector2 { this.x += v.x * s; this.y += v.y * s; return this; }
    sub(v: Vector2): Vector2 { this.x -= v.x; this.y -= v.y; return this; }
    subScalar(s: f64): Vector2 { this.x -= s; this.y -= s; return this; }
    subVectors(a: Vector2, b: Vector2): Vector2 { this.x = a.x - b.x; this.y = a.y - b.y; return this; }
    multiply(v: Vector2): Vector2 { this.x *= v.x; this.y *= v.y; return this; }
    multiplyScalar(s: f64): Vector2 { this.x *= s; this.y *= s; return this; }
    divide(v: Vector2): Vector2 { this.x /= v.x; this.y /= v.y; return this; }
    divideScalar(s: f64): Vector2 { return this.multiplyScalar(1 / s); }
    negate(): Vector2 { this.x = -this.x; this.y = -this.y; return this; }

    applyMatrix3(m: Matrix3): Vector2 {
        const x = this.x, y = this.y;
        const e = m.elements;
        this.x = e[0] * x + e[3] * y + e[6];
        this.y = e[1] * x + e[4] * y + e[7];
        return this;
    }

    min(v: Vector2): Vector2 { this.x = Math.min(this.x, v.x); this.y = Math.min(this.y, v.y); return this; }
    max(v: Vector2): Vector2 { this.x = Math.max(this.x, v.x); this.y = Math.max(this.y, v.y); return this; }
    clamp(min: Vector2, max: Vector2): Vector2 {
        this.x = Math.max(min.x, Math.min(max.x, this.x));
        this.y = Math.max(min.y, Math.min(max.y, this.y));
        return this;
    }
    floor(): Vector2 { this.x = Math.floor(this.x); this.y = Math.floor(this.y); return this; }
    ceil(): Vector2 { this.x = Math.ceil(this.x); this.y = Math.ceil(this.y); return this; }
    round(): Vector2 { this.x = Math.round(this.x); this.y = Math.round(this.y); return this; }

    dot(v: Vector2): f64 { return this.x * v.x + this.y * v.y; }
    cross(v: Vector2): f64 { return this.x * v.y - this.y * v.x; }
    lengthSq(): f64 { return this.x * this.x + this.y * this.y; }
    length(): f64 { return Math.sqrt(this.lengthSq()); }
    manhattanLength(): f64 { return Math.abs(this.x) + Math.abs(this.y); }
    normalize(): Vector2 { const l = this.length(); return this.divideScalar(l > 0 ? l : 1); }
    angle(): f64 { return Math.atan2(-this.y, -this.x) + Math.PI; }
    distanceTo(v: Vector2): f64 { return Math.sqrt(this.distanceToSquared(v)); }
    distanceToSquared(v: Vector2): f64 { const dx = this.x - v.x, dy = this.y - v.y; return dx * dx + dy * dy; }
    setLength(l: f64): Vector2 { return this.normalize().multiplyScalar(l); }
    lerp(v: Vector2, t: f64): Vector2 { this.x += (v.x - this.x) * t; this.y += (v.y - this.y) * t; return this; }
    lerpVectors(a: Vector2, b: Vector2, t: f64): Vector2 {
        this.x = a.x + (b.x - a.x) * t;
        this.y = a.y + (b.y - a.y) * t;
        return this;
    }
    equals(v: Vector2): bool { return this.x == v.x && this.y == v.y; }

    rotateAround(center: Vector2, angle: f64): Vector2 {
        const c = Math.cos(angle), s = Math.sin(angle);
        const x = this.x - center.x, y = this.y - center.y;
        this.x = x * c - y * s + center.x;
        this.y = x * s + y * c + center.y;
        return this;
    }

    fromArray(array: Array<f64>, offset: i32 = 0): Vector2 { this.x = array[offset]; this.y = array[offset + 1]; return this; }
    toArray(array: Array<f64> = [], offset: i32 = 0): Array<f64> {
        while (array.length < offset + 2) array.push(0);
        array[offset] = this.x; array[offset + 1] = this.y;
        return array;
    }

    // Rive interop.

    /// Sets from a Rive `Vector` (pointer positions, node positions).
    setFromVector(v: Vector): Vector2 { this.x = <f64>v.x; this.y = <f64>v.y; return this; }
    /// This as a Rive `Vector`.
    toVector(): Vector { return Vector.xy(<f32>this.x, <f32>this.y); }
}
