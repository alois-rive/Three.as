// three.js Matrix3 (column-major `elements`; `set()` takes row-major
// arguments).

import { Matrix4 } from "./Matrix4";
import { Vector2 } from "./Vector2";

export class Matrix3 {
    elements: StaticArray<f64> = new StaticArray<f64>(9);

    constructor(
        n11: f64 = 1, n12: f64 = 0, n13: f64 = 0,
        n21: f64 = 0, n22: f64 = 1, n23: f64 = 0,
        n31: f64 = 0, n32: f64 = 0, n33: f64 = 1,
    ) {
        this.set(n11, n12, n13, n21, n22, n23, n31, n32, n33);
    }

    set(n11: f64, n12: f64, n13: f64, n21: f64, n22: f64, n23: f64, n31: f64, n32: f64, n33: f64): Matrix3 {
        const te = this.elements;
        te[0] = n11; te[1] = n21; te[2] = n31;
        te[3] = n12; te[4] = n22; te[5] = n32;
        te[6] = n13; te[7] = n23; te[8] = n33;
        return this;
    }

    identity(): Matrix3 { return this.set(1, 0, 0, 0, 1, 0, 0, 0, 1); }

    clone(): Matrix3 { return new Matrix3().copy(this); }

    copy(m: Matrix3): Matrix3 {
        for (let i = 0; i < 9; i++) this.elements[i] = m.elements[i];
        return this;
    }

    /// The upper 3x3 of `m`.
    setFromMatrix4(m: Matrix4): Matrix3 {
        const me = m.elements;
        return this.set(me[0], me[4], me[8], me[1], me[5], me[9], me[2], me[6], me[10]);
    }

    multiply(m: Matrix3): Matrix3 { return this.multiplyMatrices(this, m); }
    premultiply(m: Matrix3): Matrix3 { return this.multiplyMatrices(m, this); }

    multiplyMatrices(a: Matrix3, b: Matrix3): Matrix3 {
        const ae = a.elements, be = b.elements;
        const a11 = ae[0], a12 = ae[3], a13 = ae[6];
        const a21 = ae[1], a22 = ae[4], a23 = ae[7];
        const a31 = ae[2], a32 = ae[5], a33 = ae[8];
        const b11 = be[0], b12 = be[3], b13 = be[6];
        const b21 = be[1], b22 = be[4], b23 = be[7];
        const b31 = be[2], b32 = be[5], b33 = be[8];
        return this.set(
            a11 * b11 + a12 * b21 + a13 * b31, a11 * b12 + a12 * b22 + a13 * b32, a11 * b13 + a12 * b23 + a13 * b33,
            a21 * b11 + a22 * b21 + a23 * b31, a21 * b12 + a22 * b22 + a23 * b32, a21 * b13 + a22 * b23 + a23 * b33,
            a31 * b11 + a32 * b21 + a33 * b31, a31 * b12 + a32 * b22 + a33 * b32, a31 * b13 + a32 * b23 + a33 * b33);
    }

    multiplyScalar(s: f64): Matrix3 {
        for (let i = 0; i < 9; i++) this.elements[i] *= s;
        return this;
    }

    determinant(): f64 {
        const te = this.elements;
        const a = te[0], b = te[1], c = te[2], d = te[3], e = te[4], f = te[5], g = te[6], h = te[7], i = te[8];
        return a * e * i - a * f * h - b * d * i + b * f * g + c * d * h - c * e * g;
    }

    /// Inverts in place; a singular matrix becomes all zeros, as three.js.
    invert(): Matrix3 {
        const te = this.elements;
        const n11 = te[0], n21 = te[1], n31 = te[2];
        const n12 = te[3], n22 = te[4], n32 = te[5];
        const n13 = te[6], n23 = te[7], n33 = te[8];
        const t11 = n33 * n22 - n32 * n23;
        const t12 = n32 * n13 - n33 * n12;
        const t13 = n23 * n12 - n22 * n13;
        const det = n11 * t11 + n21 * t12 + n31 * t13;
        if (det == 0) return this.set(0, 0, 0, 0, 0, 0, 0, 0, 0);
        const d = 1 / det;
        te[0] = t11 * d;
        te[1] = (n31 * n23 - n33 * n21) * d;
        te[2] = (n32 * n21 - n31 * n22) * d;
        te[3] = t12 * d;
        te[4] = (n33 * n11 - n31 * n13) * d;
        te[5] = (n31 * n12 - n32 * n11) * d;
        te[6] = t13 * d;
        te[7] = (n21 * n13 - n23 * n11) * d;
        te[8] = (n22 * n11 - n21 * n12) * d;
        return this;
    }

    transpose(): Matrix3 {
        const m = this.elements;
        let t: f64;
        t = m[1]; m[1] = m[3]; m[3] = t;
        t = m[2]; m[2] = m[6]; m[6] = t;
        t = m[5]; m[5] = m[7]; m[7] = t;
        return this;
    }

    /// The inverse transpose of the upper 3x3 of `matrix4`.
    getNormalMatrix(matrix4: Matrix4): Matrix3 {
        return this.setFromMatrix4(matrix4).invert().transpose();
    }

    /// A 2D UV transform: offset, repeat, rotation about (cx, cy).
    setUvTransform(tx: f64, ty: f64, sx: f64, sy: f64, rotation: f64, cx: f64, cy: f64): Matrix3 {
        const c = Math.cos(rotation), s = Math.sin(rotation);
        return this.set(
            sx * c, sx * s, -sx * (c * cx + s * cy) + cx + tx,
            -sy * s, sy * c, -sy * (-s * cx + c * cy) + cy + ty,
            0, 0, 1);
    }

    // 2D transforms, as three.js.

    scale(sx: f64, sy: f64): Matrix3 { return this.premultiply(_m3.makeScale(sx, sy)); }
    rotate(theta: f64): Matrix3 { return this.premultiply(_m3.makeRotation(-theta)); }
    translate(tx: f64, ty: f64): Matrix3 { return this.premultiply(_m3.makeTranslation(tx, ty)); }

    /// `makeTranslation(x, y)` or `makeTranslation(vector2)`.
    makeTranslation<T>(x: T, y: f64 = 0): Matrix3 {
        if (isReference<T>()) {
            const v = x as Vector2;
            return this.set(1, 0, v.x, 0, 1, v.y, 0, 0, 1);
        }
        return this.set(1, 0, <f64>x, 0, 1, y, 0, 0, 1);
    }

    makeRotation(theta: f64): Matrix3 {
        const c = Math.cos(theta), s = Math.sin(theta);
        return this.set(c, -s, 0, s, c, 0, 0, 0, 1);
    }

    makeScale(x: f64, y: f64): Matrix3 { return this.set(x, 0, 0, 0, y, 0, 0, 0, 1); }

    equals(m: Matrix3): bool {
        for (let i = 0; i < 9; i++) if (this.elements[i] != m.elements[i]) return false;
        return true;
    }
}

const _m3 = new Matrix3();
