// three.js Quaternion. A Quaternion and an Euler can be linked (Object3D
// links its rotation and quaternion): setting either updates the other.

import { Matrix4 } from "./Matrix4";
import { Euler } from "./Euler";
import { Vector3 } from "./Vector3";

export class Quaternion {
    private _x: f64;
    private _y: f64;
    private _z: f64;
    private _w: f64;
    /// The linked Euler, kept in sync on every change.
    linked: Euler? = null;

    constructor(x: f64 = 0, y: f64 = 0, z: f64 = 0, w: f64 = 1) {
        this._x = x;
        this._y = y;
        this._z = z;
        this._w = w;
    }

    get x(): f64 { return this._x; }
    set x(v: f64) { this._x = v; this.changed(); }
    get y(): f64 { return this._y; }
    set y(v: f64) { this._y = v; this.changed(); }
    get z(): f64 { return this._z; }
    set z(v: f64) { this._z = v; this.changed(); }
    get w(): f64 { return this._w; }
    set w(v: f64) { this._w = v; this.changed(); }

    set(x: f64, y: f64, z: f64, w: f64): Quaternion {
        this._x = x; this._y = y; this._z = z; this._w = w;
        this.changed();
        return this;
    }

    identity(): Quaternion { return this.set(0, 0, 0, 1); }
    clone(): Quaternion { return new Quaternion(this._x, this._y, this._z, this._w); }
    copy(q: Quaternion): Quaternion { return this.set(q.x, q.y, q.z, q.w); }

    setFromEuler(e: Euler): Quaternion {
        this.fromEulerSilent(e);
        this.changed();
        return this;
    }

    /// `axis` must be normalized; `angle` in radians.
    setFromAxisAngle(axis: Vector3, angle: f64): Quaternion {
        const s = Math.sin(angle / 2);
        return this.set(axis.x * s, axis.y * s, axis.z * s, Math.cos(angle / 2));
    }

    /// The rotation of the upper 3x3 of `m` (unscaled).
    setFromRotationMatrix(m: Matrix4): Quaternion {
        const e = m.elements;
        const m11: f64 = e[0], m12: f64 = e[4], m13: f64 = e[8];
        const m21: f64 = e[1], m22: f64 = e[5], m23: f64 = e[9];
        const m31: f64 = e[2], m32: f64 = e[6], m33: f64 = e[10];
        const trace = m11 + m22 + m33;
        if (trace > 0) {
            const s = 0.5 / Math.sqrt(trace + 1);
            return this.set((m32 - m23) * s, (m13 - m31) * s, (m21 - m12) * s, 0.25 / s);
        } else if (m11 > m22 && m11 > m33) {
            const s = 2 * Math.sqrt(1 + m11 - m22 - m33);
            return this.set(0.25 * s, (m12 + m21) / s, (m13 + m31) / s, (m32 - m23) / s);
        } else if (m22 > m33) {
            const s = 2 * Math.sqrt(1 + m22 - m11 - m33);
            return this.set((m12 + m21) / s, 0.25 * s, (m23 + m32) / s, (m13 - m31) / s);
        }
        const s = 2 * Math.sqrt(1 + m33 - m11 - m22);
        return this.set((m13 + m31) / s, (m23 + m32) / s, 0.25 * s, (m21 - m12) / s);
    }

    /// The rotation taking unit vector `vFrom` to unit vector `vTo`.
    setFromUnitVectors(vFrom: Vector3, vTo: Vector3): Quaternion {
        let r = vFrom.dot(vTo) + 1;
        let x: f64, y: f64, z: f64;
        if (r < 1e-8) {
            r = 0;
            if (Math.abs(vFrom.x) > Math.abs(vFrom.z)) { x = -vFrom.y; y = vFrom.x; z = 0; }
            else { x = 0; y = -vFrom.z; z = vFrom.y; }
        } else {
            x = vFrom.y * vTo.z - vFrom.z * vTo.y;
            y = vFrom.z * vTo.x - vFrom.x * vTo.z;
            z = vFrom.x * vTo.y - vFrom.y * vTo.x;
        }
        this._x = x; this._y = y; this._z = z; this._w = r;
        return this.normalize();
    }

    angleTo(q: Quaternion): f64 {
        return 2 * Math.acos(Math.abs(Math.max(-1, Math.min(1, this.dot(q)))));
    }

    rotateTowards(q: Quaternion, step: f64): Quaternion {
        const angle = this.angleTo(q);
        if (angle == 0) return this;
        const t = Math.min(1, step / angle);
        this.slerp(q, t);
        return this;
    }

    invert(): Quaternion { return this.conjugate(); }
    conjugate(): Quaternion { return this.set(-this._x, -this._y, -this._z, this._w); }
    dot(v: Quaternion): f64 { return this._x * v.x + this._y * v.y + this._z * v.z + this._w * v.w; }
    lengthSq(): f64 { return this.dot(this); }
    length(): f64 { return Math.sqrt(this.lengthSq()); }

    normalize(): Quaternion {
        const l = this.length();
        if (!(l > 0)) return this.set(0, 0, 0, 1);
        return this.set(this._x / l, this._y / l, this._z / l, this._w / l);
    }

    /// this = this * q.
    multiply(q: Quaternion): Quaternion { return this.multiplyQuaternions(this, q); }
    /// this = q * this.
    premultiply(q: Quaternion): Quaternion { return this.multiplyQuaternions(q, this); }

    multiplyQuaternions(a: Quaternion, b: Quaternion): Quaternion {
        const ax = a.x, ay = a.y, az = a.z, aw = a.w;
        const bx = b.x, by = b.y, bz = b.z, bw = b.w;
        return this.set(
            ax * bw + aw * bx + ay * bz - az * by,
            ay * bw + aw * by + az * bx - ax * bz,
            az * bw + aw * bz + ax * by - ay * bx,
            aw * bw - ax * bx - ay * by - az * bz);
    }

    /// Shortest-arc spherical interpolation towards `qb` by `t`.
    slerp(qb: Quaternion, t: f64): Quaternion {
        if (t <= 0) return this;
        if (t >= 1) return this.copy(qb);
        let bx = qb.x, by = qb.y, bz = qb.z, bw = qb.w;
        const ax = this._x, ay = this._y, az = this._z, aw = this._w;
        let d = ax * bx + ay * by + az * bz + aw * bw;
        if (d < 0) { d = -d; bx = -bx; by = -by; bz = -bz; bw = -bw; }
        let wa: f64, wb: f64;
        if (d > 0.9995) {
            wa = 1 - t;
            wb = t;
        } else {
            const th = Math.acos(Math.min(d, 1));
            const s = Math.sin(th);
            wa = Math.sin((1 - t) * th) / s;
            wb = Math.sin(t * th) / s;
        }
        this._x = ax * wa + bx * wb;
        this._y = ay * wa + by * wb;
        this._z = az * wa + bz * wb;
        this._w = aw * wa + bw * wb;
        return this.normalize();
    }

    slerpQuaternions(qa: Quaternion, qb: Quaternion, t: f64): Quaternion {
        if (t <= 0) return this.copy(qa);
        if (t >= 1) return this.copy(qb);
        this._x = qa.x; this._y = qa.y; this._z = qa.z; this._w = qa.w;
        return this.slerp(qb, t);
    }

    random(): Quaternion {
        const theta1 = 2 * Math.PI * Math.random();
        const theta2 = 2 * Math.PI * Math.random();
        const x0 = Math.random();
        const r1 = Math.sqrt(1 - x0);
        const r2 = Math.sqrt(x0);
        return this.set(r1 * Math.sin(theta1), r1 * Math.cos(theta1), r2 * Math.sin(theta2), r2 * Math.cos(theta2));
    }

    equals(q: Quaternion): bool {
        return this._x == q.x && this._y == q.y && this._z == q.z && this._w == q.w;
    }

    fromArray(array: Array<f64>, offset: i32 = 0): Quaternion {
        return this.set(array[offset], array[offset + 1], array[offset + 2], array[offset + 3]);
    }

    toArray(array: Array<f64> = [], offset: i32 = 0): Array<f64> {
        while (array.length < offset + 4) array.push(0);
        array[offset] = this._x; array[offset + 1] = this._y;
        array[offset + 2] = this._z; array[offset + 3] = this._w;
        return array;
    }

    /// Sets the components from `e` without notifying the link.
    fromEulerSilent(e: Euler): void {
        const c1 = Math.cos(e.x / 2), c2 = Math.cos(e.y / 2), c3 = Math.cos(e.z / 2);
        const s1 = Math.sin(e.x / 2), s2 = Math.sin(e.y / 2), s3 = Math.sin(e.z / 2);
        const o = e.order;
        if (o == "XYZ") {
            this._x = s1 * c2 * c3 + c1 * s2 * s3; this._y = c1 * s2 * c3 - s1 * c2 * s3;
            this._z = c1 * c2 * s3 + s1 * s2 * c3; this._w = c1 * c2 * c3 - s1 * s2 * s3;
        } else if (o == "YXZ") {
            this._x = s1 * c2 * c3 + c1 * s2 * s3; this._y = c1 * s2 * c3 - s1 * c2 * s3;
            this._z = c1 * c2 * s3 - s1 * s2 * c3; this._w = c1 * c2 * c3 + s1 * s2 * s3;
        } else if (o == "ZXY") {
            this._x = s1 * c2 * c3 - c1 * s2 * s3; this._y = c1 * s2 * c3 + s1 * c2 * s3;
            this._z = c1 * c2 * s3 + s1 * s2 * c3; this._w = c1 * c2 * c3 - s1 * s2 * s3;
        } else if (o == "ZYX") {
            this._x = s1 * c2 * c3 - c1 * s2 * s3; this._y = c1 * s2 * c3 + s1 * c2 * s3;
            this._z = c1 * c2 * s3 - s1 * s2 * c3; this._w = c1 * c2 * c3 + s1 * s2 * s3;
        } else if (o == "YZX") {
            this._x = s1 * c2 * c3 + c1 * s2 * s3; this._y = c1 * s2 * c3 + s1 * c2 * s3;
            this._z = c1 * c2 * s3 - s1 * s2 * c3; this._w = c1 * c2 * c3 - s1 * s2 * s3;
        } else if (o == "XZY") {
            this._x = s1 * c2 * c3 - c1 * s2 * s3; this._y = c1 * s2 * c3 - s1 * c2 * s3;
            this._z = c1 * c2 * s3 + s1 * s2 * c3; this._w = c1 * c2 * c3 + s1 * s2 * s3;
        } else {
            this._x = s1 * c2 * c3 + c1 * s2 * s3; this._y = c1 * s2 * c3 - s1 * c2 * s3;
            this._z = c1 * c2 * s3 + s1 * s2 * c3; this._w = c1 * c2 * c3 - s1 * s2 * s3;
        }
    }

    private changed(): void {
        const e = this.linked;
        if (e != null) e.fromQuaternionSilent(this);
    }
}
