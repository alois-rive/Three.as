// three.js Euler: angles in radians applied in `order` ("XYZ": X first).

import { Matrix4 } from "./Matrix4";
import { Quaternion } from "./Quaternion";
import { Vector3 } from "./Vector3";

export class Euler {
    static DEFAULT_ORDER: string = "XYZ";

    private _x: f64;
    private _y: f64;
    private _z: f64;
    private _order: string;
    /// The linked Quaternion, kept in sync on every change.
    linked: Quaternion? = null;

    /// `order` is one of XYZ YXZ ZXY ZYX YZX XZY.
    constructor(x: f64 = 0, y: f64 = 0, z: f64 = 0, order: string = "XYZ") {
        this._x = x;
        this._y = y;
        this._z = z;
        this._order = order;
    }

    get x(): f64 { return this._x; }
    set x(v: f64) { this._x = v; this.changed(); }
    get y(): f64 { return this._y; }
    set y(v: f64) { this._y = v; this.changed(); }
    get z(): f64 { return this._z; }
    set z(v: f64) { this._z = v; this.changed(); }
    get order(): string { return this._order; }
    set order(v: string) { this._order = v; this.changed(); }

    set(x: f64, y: f64, z: f64, order: string = ""): Euler {
        this._x = x; this._y = y; this._z = z;
        if (order.length > 0) this._order = order;
        this.changed();
        return this;
    }

    clone(): Euler { return new Euler(this._x, this._y, this._z, this._order); }
    copy(e: Euler): Euler { return this.set(e.x, e.y, e.z, e.order); }

    /// The angles of the upper 3x3 of `m` (unscaled), in `order` (default:
    /// this one's).
    setFromRotationMatrix(m: Matrix4, order: string = ""): Euler {
        if (order.length > 0) this._order = order;
        this.fromMatrixSilent(m);
        this.changed();
        return this;
    }

    setFromQuaternion(q: Quaternion, order: string = ""): Euler {
        if (order.length > 0) this._order = order;
        this.fromQuaternionSilent(q);
        this.changed();
        return this;
    }

    setFromVector3(v: Vector3, order: string = ""): Euler {
        return this.set(v.x, v.y, v.z, order);
    }

    reorder(newOrder: string): Euler {
        _q.setFromEuler(this);
        return this.setFromQuaternion(_q, newOrder);
    }

    equals(e: Euler): bool {
        return this._x == e.x && this._y == e.y && this._z == e.z && this._order == e.order;
    }

    /// Sets the angles from `q` without notifying the link.
    fromQuaternionSilent(q: Quaternion): void {
        _m.makeRotationFromQuaternion(q);
        this.fromMatrixSilent(_m);
    }

    private fromMatrixSilent(m: Matrix4): void {
        const e = m.elements;
        const m11: f64 = e[0], m12: f64 = e[4], m13: f64 = e[8];
        const m21: f64 = e[1], m22: f64 = e[5], m23: f64 = e[9];
        const m31: f64 = e[2], m32: f64 = e[6], m33: f64 = e[10];
        const o = this._order;
        const lim = 0.9999999;
        if (o == "YXZ") {
            this._x = Math.asin(-clamp1(m23));
            if (Math.abs(m23) < lim) { this._y = Math.atan2(m13, m33); this._z = Math.atan2(m21, m22); }
            else { this._y = Math.atan2(-m31, m11); this._z = 0; }
        } else if (o == "ZXY") {
            this._x = Math.asin(clamp1(m32));
            if (Math.abs(m32) < lim) { this._y = Math.atan2(-m31, m33); this._z = Math.atan2(-m12, m22); }
            else { this._y = 0; this._z = Math.atan2(m21, m11); }
        } else if (o == "ZYX") {
            this._y = Math.asin(-clamp1(m31));
            if (Math.abs(m31) < lim) { this._x = Math.atan2(m32, m33); this._z = Math.atan2(m21, m11); }
            else { this._x = 0; this._z = Math.atan2(-m12, m22); }
        } else if (o == "YZX") {
            this._z = Math.asin(clamp1(m21));
            if (Math.abs(m21) < lim) { this._x = Math.atan2(-m23, m22); this._y = Math.atan2(-m31, m11); }
            else { this._x = 0; this._y = Math.atan2(m13, m33); }
        } else if (o == "XZY") {
            this._z = Math.asin(-clamp1(m12));
            if (Math.abs(m12) < lim) { this._x = Math.atan2(m32, m22); this._y = Math.atan2(m13, m11); }
            else { this._x = Math.atan2(-m23, m33); this._y = 0; }
        } else { // XYZ
            this._y = Math.asin(clamp1(m13));
            if (Math.abs(m13) < lim) { this._x = Math.atan2(-m23, m33); this._z = Math.atan2(-m12, m11); }
            else { this._x = Math.atan2(m32, m22); this._z = 0; }
        }
    }

    private changed(): void {
        const q = this.linked;
        if (q != null) q.fromEulerSilent(this);
    }
}

function clamp1(v: f64): f64 {
    return Math.max(-1, Math.min(1, v));
}

const _m: Matrix4 = new Matrix4();
const _q: Quaternion = new Quaternion();
