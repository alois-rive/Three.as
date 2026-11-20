// three.js Matrix4, stored in a Rive `Mat4` (`mat4`): column-major f32,
// the layout three.js uses for `elements`. Multiplication, inversion and
// projections run on Rive's Mat4; `mat4` can be handed to any Rive API, and
// `mat4.writeToBuffer` uploads it.
//
// `set()` takes row-major arguments, as three.js. Projections map depth to
// [0, 1] (WebGPU), as three.js with WebGPUCoordinateSystem.

import { Mat4 } from "rive/mat4";
import { Vector3 } from "./Vector3";
import { Quaternion } from "./Quaternion";
import { Euler } from "./Euler";
import { Matrix3 } from "./Matrix3";

export class Matrix4 {
    /// The Rive matrix holding the elements. Shared, not a copy.
    readonly mat4: Mat4 = new Mat4();

    /// Row-major arguments, as three.js; identity when omitted.
    constructor(
        n11: f64 = 1, n12: f64 = 0, n13: f64 = 0, n14: f64 = 0,
        n21: f64 = 0, n22: f64 = 1, n23: f64 = 0, n24: f64 = 0,
        n31: f64 = 0, n32: f64 = 0, n33: f64 = 1, n34: f64 = 0,
        n41: f64 = 0, n42: f64 = 0, n43: f64 = 0, n44: f64 = 1,
    ) {
        this.set(n11, n12, n13, n14, n21, n22, n23, n24, n31, n32, n33, n34, n41, n42, n43, n44);
    }

    /// Column-major elements (three.js `elements`).
    get elements(): StaticArray<f32> { return this.mat4.m; }

    /// A Matrix4 holding a copy of a Rive Mat4.
    static fromMat4(m: Mat4): Matrix4 { return new Matrix4().copyMat4(m); }

    set(
        n11: f64, n12: f64, n13: f64, n14: f64,
        n21: f64, n22: f64, n23: f64, n24: f64,
        n31: f64, n32: f64, n33: f64, n34: f64,
        n41: f64, n42: f64, n43: f64, n44: f64,
    ): Matrix4 {
        const te = this.mat4.m;
        te[0] = <f32>n11; te[4] = <f32>n12; te[8] = <f32>n13; te[12] = <f32>n14;
        te[1] = <f32>n21; te[5] = <f32>n22; te[9] = <f32>n23; te[13] = <f32>n24;
        te[2] = <f32>n31; te[6] = <f32>n32; te[10] = <f32>n33; te[14] = <f32>n34;
        te[3] = <f32>n41; te[7] = <f32>n42; te[11] = <f32>n43; te[15] = <f32>n44;
        return this;
    }

    identity(): Matrix4 {
        return this.set(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1);
    }

    clone(): Matrix4 { return new Matrix4().copy(this); }

    copy(m: Matrix4): Matrix4 { return this.copyMat4(m.mat4); }

    copyMat4(m: Mat4): Matrix4 {
        const te = this.mat4.m, me = m.m;
        for (let i = 0; i < 16; i++) te[i] = me[i];
        return this;
    }

    copyPosition(m: Matrix4): Matrix4 {
        const te = this.mat4.m, me = m.elements;
        te[12] = me[12]; te[13] = me[13]; te[14] = me[14];
        return this;
    }

    setFromMatrix3(m: Matrix3): Matrix4 {
        const me = m.elements;
        return this.set(
            me[0], me[3], me[6], 0,
            me[1], me[4], me[7], 0,
            me[2], me[5], me[8], 0,
            0, 0, 0, 1);
    }

    extractBasis(xAxis: Vector3, yAxis: Vector3, zAxis: Vector3): Matrix4 {
        xAxis.setFromMatrixColumn(this, 0);
        yAxis.setFromMatrixColumn(this, 1);
        zAxis.setFromMatrixColumn(this, 2);
        return this;
    }

    makeBasis(xAxis: Vector3, yAxis: Vector3, zAxis: Vector3): Matrix4 {
        return this.set(
            xAxis.x, yAxis.x, zAxis.x, 0,
            xAxis.y, yAxis.y, zAxis.y, 0,
            xAxis.z, yAxis.z, zAxis.z, 0,
            0, 0, 0, 1);
    }

    /// The rotation of `m` (its columns normalised), translation cleared.
    extractRotation(m: Matrix4): Matrix4 {
        const te = this.mat4.m, me = m.elements;
        const sx = 1 / _v1.setFromMatrixColumn(m, 0).length();
        const sy = 1 / _v1.setFromMatrixColumn(m, 1).length();
        const sz = 1 / _v1.setFromMatrixColumn(m, 2).length();
        te[0] = <f32>(me[0] * sx); te[1] = <f32>(me[1] * sx); te[2] = <f32>(me[2] * sx); te[3] = 0;
        te[4] = <f32>(me[4] * sy); te[5] = <f32>(me[5] * sy); te[6] = <f32>(me[6] * sy); te[7] = 0;
        te[8] = <f32>(me[8] * sz); te[9] = <f32>(me[9] * sz); te[10] = <f32>(me[10] * sz); te[11] = 0;
        te[12] = 0; te[13] = 0; te[14] = 0; te[15] = 1;
        return this;
    }

    makeRotationFromEuler(e: Euler): Matrix4 {
        _q1.setFromEuler(e);
        return this.makeRotationFromQuaternion(_q1);
    }

    makeRotationFromQuaternion(q: Quaternion): Matrix4 {
        return this.compose(_zero, q, _one);
    }

    /// Rotation such that the +Z axis points from `target` to `eye`.
    lookAt(eye: Vector3, target: Vector3, up: Vector3): Matrix4 {
        const te = this.mat4.m;
        _z.subVectors(eye, target);
        if (_z.lengthSq() == 0) _z.z = 1;
        _z.normalize();
        _x.crossVectors(up, _z);
        if (_x.lengthSq() == 0) {
            // up and z are parallel
            if (Math.abs(up.z) == 1) _z.x += 0.0001;
            else _z.z += 0.0001;
            _z.normalize();
            _x.crossVectors(up, _z);
        }
        _x.normalize();
        _y.crossVectors(_z, _x);
        te[0] = <f32>_x.x; te[4] = <f32>_y.x; te[8] = <f32>_z.x;
        te[1] = <f32>_x.y; te[5] = <f32>_y.y; te[9] = <f32>_z.y;
        te[2] = <f32>_x.z; te[6] = <f32>_y.z; te[10] = <f32>_z.z;
        return this;
    }

    /// this = this * m.
    multiply(m: Matrix4): Matrix4 { return this.multiplyMatrices(this, m); }

    /// this = m * this.
    premultiply(m: Matrix4): Matrix4 { return this.multiplyMatrices(m, this); }

    /// this = a * b.
    multiplyMatrices(a: Matrix4, b: Matrix4): Matrix4 {
        const ae = a.mat4.m, be = b.mat4.m;
        if (ae[3] == 0 && ae[7] == 0 && ae[11] == 0 && ae[15] == 1
                && be[3] == 0 && be[7] == 0 && be[11] == 0 && be[15] == 1) {
            Mat4.multiplyAffine(this.mat4, a.mat4, b.mat4);
        } else {
            Mat4.multiply(this.mat4, a.mat4, b.mat4);
        }
        return this;
    }

    multiplyScalar(s: f64): Matrix4 {
        const te = this.mat4.m;
        for (let i = 0; i < 16; i++) te[i] = <f32>(<f64>te[i] * s);
        return this;
    }

    determinant(): f64 {
        const te = this.mat4.m;
        const n11: f64 = te[0], n12: f64 = te[4], n13: f64 = te[8], n14: f64 = te[12];
        const n21: f64 = te[1], n22: f64 = te[5], n23: f64 = te[9], n24: f64 = te[13];
        const n31: f64 = te[2], n32: f64 = te[6], n33: f64 = te[10], n34: f64 = te[14];
        const n41: f64 = te[3], n42: f64 = te[7], n43: f64 = te[11], n44: f64 = te[15];
        // Affine (the usual case): the other three terms are zero.
        if (n41 == 0 && n42 == 0 && n43 == 0) {
            return n44 * (-n13 * n22 * n31 - n11 * n23 * n32 + n11 * n22 * n33 + n13 * n21 * n32 - n12 * n21 * n33 + n12 * n23 * n31);
        }
        return n41 *(+n14 * n23 * n32 - n13 * n24 * n32 - n14 * n22 * n33 + n12 * n24 * n33 + n13 * n22 * n34 - n12 * n23 * n34)
            + n42 * (+n11 * n23 * n34 - n11 * n24 * n33 + n14 * n21 * n33 - n13 * n21 * n34 + n13 * n24 * n31 - n14 * n23 * n31)
            + n43 * (+n11 * n24 * n32 - n11 * n22 * n34 - n14 * n21 * n32 + n12 * n21 * n34 + n14 * n22 * n31 - n12 * n24 * n31)
            + n44 * (-n13 * n22 * n31 - n11 * n23 * n32 + n11 * n22 * n33 + n13 * n21 * n32 - n12 * n21 * n33 + n12 * n23 * n31);
    }

    transpose(): Matrix4 {
        const te = this.mat4.m;
        let t: f32;
        t = te[1]; te[1] = te[4]; te[4] = t;
        t = te[2]; te[2] = te[8]; te[8] = t;
        t = te[6]; te[6] = te[9]; te[9] = t;
        t = te[3]; te[3] = te[12]; te[12] = t;
        t = te[7]; te[7] = te[13]; te[13] = t;
        t = te[11]; te[11] = te[14]; te[14] = t;
        return this;
    }

    setPosition(x: f64, y: f64, z: f64): Matrix4 {
        const te = this.mat4.m;
        te[12] = <f32>x; te[13] = <f32>y; te[14] = <f32>z;
        return this;
    }

    /// Inverts in place; a singular matrix becomes all zeros, as three.js.
    invert(): Matrix4 {
        const te = this.mat4.m;
        if (te[3] == 0 && te[7] == 0 && te[11] == 0 && te[15] == 1) {
            if (Mat4.invertAffine(this.mat4, this.mat4)) return this;
        } else if (Mat4.invert(_scratch, this.mat4)) {
            return this.copyMat4(_scratch);
        }
        for (let i = 0; i < 16; i++) te[i] = 0;
        return this;
    }

    scale(v: Vector3): Matrix4 {
        const te = this.mat4.m;
        const x = <f32>v.x, y = <f32>v.y, z = <f32>v.z;
        te[0] *= x; te[4] *= y; te[8] *= z;
        te[1] *= x; te[5] *= y; te[9] *= z;
        te[2] *= x; te[6] *= y; te[10] *= z;
        te[3] *= x; te[7] *= y; te[11] *= z;
        return this;
    }

    getMaxScaleOnAxis(): f64 {
        const te = this.mat4.m;
        const sx = <f64>te[0] * te[0] + <f64>te[1] * te[1] + <f64>te[2] * te[2];
        const sy = <f64>te[4] * te[4] + <f64>te[5] * te[5] + <f64>te[6] * te[6];
        const sz = <f64>te[8] * te[8] + <f64>te[9] * te[9] + <f64>te[10] * te[10];
        return Math.sqrt(Math.max(sx, Math.max(sy, sz)));
    }

    makeTranslation(x: f64, y: f64, z: f64): Matrix4 {
        return this.set(1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z, 0, 0, 0, 1);
    }

    makeRotationX(theta: f64): Matrix4 {
        const c = Math.cos(theta), s = Math.sin(theta);
        return this.set(1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0, 0, 0, 0, 1);
    }

    makeRotationY(theta: f64): Matrix4 {
        const c = Math.cos(theta), s = Math.sin(theta);
        return this.set(c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, 0, 0, 0, 1);
    }

    makeRotationZ(theta: f64): Matrix4 {
        const c = Math.cos(theta), s = Math.sin(theta);
        return this.set(c, -s, 0, 0, s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1);
    }

    /// Rotation about unit `axis` by `angle` radians.
    makeRotationAxis(axis: Vector3, angle: f64): Matrix4 {
        const c = Math.cos(angle), s = Math.sin(angle), t = 1 - c;
        const x = axis.x, y = axis.y, z = axis.z;
        const tx = t * x, ty = t * y;
        return this.set(
            tx * x + c, tx * y - s * z, tx * z + s * y, 0,
            tx * y + s * z, ty * y + c, ty * z - s * x, 0,
            tx * z - s * y, ty * z + s * x, t * z * z + c, 0,
            0, 0, 0, 1);
    }

    makeScale(x: f64, y: f64, z: f64): Matrix4 {
        return this.set(x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1);
    }

    /// this = T * R * S.
    compose(position: Vector3, quaternion: Quaternion, scale: Vector3): Matrix4 {
        const te = this.mat4.m;
        const x = quaternion.x, y = quaternion.y, z = quaternion.z, w = quaternion.w;
        const x2 = x + x, y2 = y + y, z2 = z + z;
        const xx = x * x2, xy = x * y2, xz = x * z2;
        const yy = y * y2, yz = y * z2, zz = z * z2;
        const wx = w * x2, wy = w * y2, wz = w * z2;
        const sx = scale.x, sy = scale.y, sz = scale.z;
        te[0] = <f32>((1 - (yy + zz)) * sx); te[1] = <f32>((xy + wz) * sx); te[2] = <f32>((xz - wy) * sx); te[3] = 0;
        te[4] = <f32>((xy - wz) * sy); te[5] = <f32>((1 - (xx + zz)) * sy); te[6] = <f32>((yz + wx) * sy); te[7] = 0;
        te[8] = <f32>((xz + wy) * sz); te[9] = <f32>((yz - wx) * sz); te[10] = <f32>((1 - (xx + yy)) * sz); te[11] = 0;
        te[12] = <f32>position.x; te[13] = <f32>position.y; te[14] = <f32>position.z; te[15] = 1;
        return this;
    }

    /// Splits this affine matrix into translation, rotation and scale (a
    /// mirrored matrix gets a negative X scale).
    decompose(position: Vector3, quaternion: Quaternion, scale: Vector3): Matrix4 {
        const te = this.mat4.m;
        let sx = _v1.set(te[0], te[1], te[2]).length();
        const sy = _v1.set(te[4], te[5], te[6]).length();
        const sz = _v1.set(te[8], te[9], te[10]).length();
        if (this.determinant() < 0) sx = -sx;
        position.set(te[12], te[13], te[14]);
        _m1.copy(this);
        const r = _m1.mat4.m;
        const ix = sx != 0 ? 1 / sx : 0, iy = sy != 0 ? 1 / sy : 0, iz = sz != 0 ? 1 / sz : 0;
        r[0] = <f32>(te[0] * ix); r[1] = <f32>(te[1] * ix); r[2] = <f32>(te[2] * ix);
        r[4] = <f32>(te[4] * iy); r[5] = <f32>(te[5] * iy); r[6] = <f32>(te[6] * iy);
        r[8] = <f32>(te[8] * iz); r[9] = <f32>(te[9] * iz); r[10] = <f32>(te[10] * iz);
        quaternion.setFromRotationMatrix(_m1);
        scale.set(sx, sy, sz);
        return this;
    }

    /// An off-axis perspective projection, depth in [0, 1].
    makePerspective(left: f64, right: f64, top: f64, bottom: f64, near: f64, far: f64): Matrix4 {
        const x = 2 * near / (right - left);
        const y = 2 * near / (top - bottom);
        const a = (right + left) / (right - left);
        const b = (top + bottom) / (top - bottom);
        const c = -far / (far - near);
        const d = -far * near / (far - near);
        return this.set(
            x, 0, a, 0,
            0, y, b, 0,
            0, 0, c, d,
            0, 0, -1, 0);
    }

    /// An orthographic projection, depth in [0, 1].
    makeOrthographic(left: f64, right: f64, top: f64, bottom: f64, near: f64, far: f64): Matrix4 {
        Mat4.orthoInto(this.mat4, <f32>left, <f32>right, <f32>bottom, <f32>top, <f32>near, <f32>far);
        return this;
    }

    equals(m: Matrix4): bool {
        const te = this.mat4.m, me = m.elements;
        for (let i = 0; i < 16; i++) if (te[i] != me[i]) return false;
        return true;
    }

    fromArray(array: Array<f64>, offset: i32 = 0): Matrix4 {
        const te = this.mat4.m;
        for (let i = 0; i < 16; i++) te[i] = <f32>array[i + offset];
        return this;
    }

    toArray(array: Array<f64> = [], offset: i32 = 0): Array<f64> {
        const te = this.mat4.m;
        while (array.length < offset + 16) array.push(0);
        for (let i = 0; i < 16; i++) array[offset + i] = te[i];
        return array;
    }
}

const _scratch: Mat4 = Mat4.identity();
const _m1: Matrix4 = new Matrix4();
const _v1: Vector3 = new Vector3();
const _x: Vector3 = new Vector3();
const _y: Vector3 = new Vector3();
const _z: Vector3 = new Vector3();
const _q1: Quaternion = new Quaternion();
const _zero: Vector3 = new Vector3(0, 0, 0);
const _one: Vector3 = new Vector3(1, 1, 1);
