// three.js Vector3.

import { Matrix3 } from "./Matrix3";
import { Matrix4 } from "./Matrix4";
import { Quaternion } from "./Quaternion";
import { Euler } from "./Euler";
import { Camera } from "../cameras/Camera";

export class Vector3 {
    x: f64;
    y: f64;
    z: f64;

    constructor(x: f64 = 0, y: f64 = 0, z: f64 = 0) {
        this.x = x;
        this.y = y;
        this.z = z;
    }

    set(x: f64, y: f64, z: f64): Vector3 { this.x = x; this.y = y; this.z = z; return this; }
    setScalar(s: f64): Vector3 { this.x = s; this.y = s; this.z = s; return this; }
    setX(x: f64): Vector3 { this.x = x; return this; }
    setY(y: f64): Vector3 { this.y = y; return this; }
    setZ(z: f64): Vector3 { this.z = z; return this; }
    setComponent(index: i32, value: f64): Vector3 {
        if (index == 0) this.x = value;
        else if (index == 1) this.y = value;
        else this.z = value;
        return this;
    }
    getComponent(index: i32): f64 { return index == 0 ? this.x : index == 1 ? this.y : this.z; }
    clone(): Vector3 { return new Vector3(this.x, this.y, this.z); }
    copy(v: Vector3): Vector3 { this.x = v.x; this.y = v.y; this.z = v.z; return this; }

    add(v: Vector3): Vector3 { this.x += v.x; this.y += v.y; this.z += v.z; return this; }
    addScalar(s: f64): Vector3 { this.x += s; this.y += s; this.z += s; return this; }
    addVectors(a: Vector3, b: Vector3): Vector3 { this.x = a.x + b.x; this.y = a.y + b.y; this.z = a.z + b.z; return this; }
    addScaledVector(v: Vector3, s: f64): Vector3 { this.x += v.x * s; this.y += v.y * s; this.z += v.z * s; return this; }
    sub(v: Vector3): Vector3 { this.x -= v.x; this.y -= v.y; this.z -= v.z; return this; }
    subScalar(s: f64): Vector3 { this.x -= s; this.y -= s; this.z -= s; return this; }
    subVectors(a: Vector3, b: Vector3): Vector3 { this.x = a.x - b.x; this.y = a.y - b.y; this.z = a.z - b.z; return this; }
    multiply(v: Vector3): Vector3 { this.x *= v.x; this.y *= v.y; this.z *= v.z; return this; }
    multiplyScalar(s: f64): Vector3 { this.x *= s; this.y *= s; this.z *= s; return this; }
    multiplyVectors(a: Vector3, b: Vector3): Vector3 { this.x = a.x * b.x; this.y = a.y * b.y; this.z = a.z * b.z; return this; }
    divide(v: Vector3): Vector3 { this.x /= v.x; this.y /= v.y; this.z /= v.z; return this; }
    divideScalar(s: f64): Vector3 { return this.multiplyScalar(1 / s); }
    negate(): Vector3 { this.x = -this.x; this.y = -this.y; this.z = -this.z; return this; }

    applyEuler(euler: Euler): Vector3 {
        return this.applyQuaternion(_quaternion.setFromEuler(euler));
    }

    applyAxisAngle(axis: Vector3, angle: f64): Vector3 {
        return this.applyQuaternion(_quaternion.setFromAxisAngle(axis, angle));
    }

    applyMatrix3(m: Matrix3): Vector3 {
        const x = this.x, y = this.y, z = this.z;
        const e = m.elements;
        this.x = e[0] * x + e[3] * y + e[6] * z;
        this.y = e[1] * x + e[4] * y + e[7] * z;
        this.z = e[2] * x + e[5] * y + e[8] * z;
        return this;
    }

    applyNormalMatrix(m: Matrix3): Vector3 { return this.applyMatrix3(m).normalize(); }

    /// This point transformed by `m`, with the perspective divide.
    applyMatrix4(m: Matrix4): Vector3 {
        const x = this.x, y = this.y, z = this.z;
        const e = m.elements;
        const w = 1 / (<f64>e[3] * x + <f64>e[7] * y + <f64>e[11] * z + <f64>e[15]);
        this.x = (<f64>e[0] * x + <f64>e[4] * y + <f64>e[8] * z + <f64>e[12]) * w;
        this.y = (<f64>e[1] * x + <f64>e[5] * y + <f64>e[9] * z + <f64>e[13]) * w;
        this.z = (<f64>e[2] * x + <f64>e[6] * y + <f64>e[10] * z + <f64>e[14]) * w;
        return this;
    }

    applyQuaternion(q: Quaternion): Vector3 {
        // t = 2 q.xyz x v; v' = v + w t + q.xyz x t
        const vx = this.x, vy = this.y, vz = this.z;
        const qx = q.x, qy = q.y, qz = q.z, qw = q.w;
        const tx = 2 * (qy * vz - qz * vy);
        const ty = 2 * (qz * vx - qx * vz);
        const tz = 2 * (qx * vy - qy * vx);
        this.x = vx + qw * tx + qy * tz - qz * ty;
        this.y = vy + qw * ty + qz * tx - qx * tz;
        this.z = vz + qw * tz + qx * ty - qy * tx;
        return this;
    }

    /// Projects this world point to normalized device coordinates (x and y
    /// in [-1, 1], z in [0, 1]).
    project(camera: Camera): Vector3 {
        return this.applyMatrix4(camera.matrixWorldInverse).applyMatrix4(camera.projectionMatrix);
    }

    unproject(camera: Camera): Vector3 {
        return this.applyMatrix4(camera.projectionMatrixInverse).applyMatrix4(camera.matrixWorld);
    }

    /// This direction transformed by the upper 3x3 of `m`, normalized.
    transformDirection(m: Matrix4): Vector3 {
        const x = this.x, y = this.y, z = this.z;
        const e = m.elements;
        this.x = <f64>e[0] * x + <f64>e[4] * y + <f64>e[8] * z;
        this.y = <f64>e[1] * x + <f64>e[5] * y + <f64>e[9] * z;
        this.z = <f64>e[2] * x + <f64>e[6] * y + <f64>e[10] * z;
        return this.normalize();
    }

    min(v: Vector3): Vector3 {
        this.x = Math.min(this.x, v.x); this.y = Math.min(this.y, v.y); this.z = Math.min(this.z, v.z);
        return this;
    }
    max(v: Vector3): Vector3 {
        this.x = Math.max(this.x, v.x); this.y = Math.max(this.y, v.y); this.z = Math.max(this.z, v.z);
        return this;
    }
    clamp(min: Vector3, max: Vector3): Vector3 {
        this.x = Math.max(min.x, Math.min(max.x, this.x));
        this.y = Math.max(min.y, Math.min(max.y, this.y));
        this.z = Math.max(min.z, Math.min(max.z, this.z));
        return this;
    }
    clampScalar(min: f64, max: f64): Vector3 {
        this.x = Math.max(min, Math.min(max, this.x));
        this.y = Math.max(min, Math.min(max, this.y));
        this.z = Math.max(min, Math.min(max, this.z));
        return this;
    }
    clampLength(min: f64, max: f64): Vector3 {
        const l = this.length();
        return this.divideScalar(l > 0 ? l : 1).multiplyScalar(Math.max(min, Math.min(max, l)));
    }
    floor(): Vector3 { this.x = Math.floor(this.x); this.y = Math.floor(this.y); this.z = Math.floor(this.z); return this; }
    ceil(): Vector3 { this.x = Math.ceil(this.x); this.y = Math.ceil(this.y); this.z = Math.ceil(this.z); return this; }
    round(): Vector3 { this.x = Math.round(this.x); this.y = Math.round(this.y); this.z = Math.round(this.z); return this; }

    dot(v: Vector3): f64 { return this.x * v.x + this.y * v.y + this.z * v.z; }
    lengthSq(): f64 { return this.x * this.x + this.y * this.y + this.z * this.z; }
    length(): f64 { return Math.sqrt(this.lengthSq()); }
    manhattanLength(): f64 { return Math.abs(this.x) + Math.abs(this.y) + Math.abs(this.z); }
    normalize(): Vector3 { const l = this.length(); return this.divideScalar(l > 0 ? l : 1); }
    setLength(l: f64): Vector3 { return this.normalize().multiplyScalar(l); }

    lerp(v: Vector3, t: f64): Vector3 {
        this.x += (v.x - this.x) * t;
        this.y += (v.y - this.y) * t;
        this.z += (v.z - this.z) * t;
        return this;
    }

    lerpVectors(a: Vector3, b: Vector3, t: f64): Vector3 {
        this.x = a.x + (b.x - a.x) * t;
        this.y = a.y + (b.y - a.y) * t;
        this.z = a.z + (b.z - a.z) * t;
        return this;
    }

    cross(v: Vector3): Vector3 { return this.crossVectors(this, v); }

    crossVectors(a: Vector3, b: Vector3): Vector3 {
        const ax = a.x, ay = a.y, az = a.z;
        const bx = b.x, by = b.y, bz = b.z;
        this.x = ay * bz - az * by;
        this.y = az * bx - ax * bz;
        this.z = ax * by - ay * bx;
        return this;
    }

    projectOnVector(v: Vector3): Vector3 {
        const d = v.lengthSq();
        if (d == 0) return this.set(0, 0, 0);
        const s = v.dot(this) / d;
        return this.copy(v).multiplyScalar(s);
    }

    projectOnPlane(planeNormal: Vector3): Vector3 {
        _vector.copy(this).projectOnVector(planeNormal);
        return this.sub(_vector);
    }

    reflect(normal: Vector3): Vector3 {
        return this.sub(_vector.copy(normal).multiplyScalar(2 * this.dot(normal)));
    }

    angleTo(v: Vector3): f64 {
        const d = Math.sqrt(this.lengthSq() * v.lengthSq());
        if (d == 0) return Math.PI / 2;
        const theta = this.dot(v) / d;
        return Math.acos(Math.max(-1, Math.min(1, theta)));
    }

    distanceTo(v: Vector3): f64 { return Math.sqrt(this.distanceToSquared(v)); }
    distanceToSquared(v: Vector3): f64 {
        const dx = this.x - v.x, dy = this.y - v.y, dz = this.z - v.z;
        return dx * dx + dy * dy + dz * dz;
    }
    manhattanDistanceTo(v: Vector3): f64 {
        return Math.abs(this.x - v.x) + Math.abs(this.y - v.y) + Math.abs(this.z - v.z);
    }

    setFromSphericalCoords(radius: f64, phi: f64, theta: f64): Vector3 {
        const s = Math.sin(phi) * radius;
        this.x = s * Math.sin(theta);
        this.y = Math.cos(phi) * radius;
        this.z = s * Math.cos(theta);
        return this;
    }

    setFromCylindricalCoords(radius: f64, theta: f64, y: f64): Vector3 {
        this.x = radius * Math.sin(theta);
        this.y = y;
        this.z = radius * Math.cos(theta);
        return this;
    }

    setFromMatrixPosition(m: Matrix4): Vector3 {
        const e = m.elements;
        this.x = e[12]; this.y = e[13]; this.z = e[14];
        return this;
    }

    setFromMatrixScale(m: Matrix4): Vector3 {
        const sx = this.setFromMatrixColumn(m, 0).length();
        const sy = this.setFromMatrixColumn(m, 1).length();
        const sz = this.setFromMatrixColumn(m, 2).length();
        this.x = sx; this.y = sy; this.z = sz;
        return this;
    }

    setFromMatrixColumn(m: Matrix4, index: i32): Vector3 {
        const e = m.elements;
        const o = index * 4;
        this.x = e[o]; this.y = e[o + 1]; this.z = e[o + 2];
        return this;
    }

    setFromMatrix3Column(m: Matrix3, index: i32): Vector3 {
        const e = m.elements;
        const o = index * 3;
        this.x = e[o]; this.y = e[o + 1]; this.z = e[o + 2];
        return this;
    }

    setFromEuler(e: Euler): Vector3 { this.x = e.x; this.y = e.y; this.z = e.z; return this; }

    equals(v: Vector3): bool { return this.x == v.x && this.y == v.y && this.z == v.z; }

    fromArray(array: Array<f64>, offset: i32 = 0): Vector3 {
        this.x = array[offset]; this.y = array[offset + 1]; this.z = array[offset + 2];
        return this;
    }

    toArray(array: Array<f64> = [], offset: i32 = 0): Array<f64> {
        while (array.length < offset + 3) array.push(0);
        array[offset] = this.x; array[offset + 1] = this.y; array[offset + 2] = this.z;
        return array;
    }

    random(): Vector3 { this.x = Math.random(); this.y = Math.random(); this.z = Math.random(); return this; }

    randomDirection(): Vector3 {
        const theta = Math.random() * Math.PI * 2;
        const u = Math.random() * 2 - 1;
        const c = Math.sqrt(1 - u * u);
        this.x = c * Math.cos(theta);
        this.y = u;
        this.z = c * Math.sin(theta);
        return this;
    }
}

const _vector: Vector3 = new Vector3();
const _quaternion: Quaternion = new Quaternion();
