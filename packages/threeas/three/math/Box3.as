// three.js Box3: an axis-aligned bounding box. Empty is min = +Infinity,
// max = -Infinity.

import { Vector3 } from "./Vector3";
import { Matrix4 } from "./Matrix4";
import { Sphere } from "./Sphere";
import { Plane } from "./Plane";
import { Triangle } from "./Triangle";
import { BufferAttribute } from "../core/BufferAttribute";
import { Object3D } from "../core/Object3D";
import { geometryOf } from "../core/geometryOf";

export class Box3 {
    readonly isBox3: bool = true;
    min: Vector3;
    max: Vector3;

    constructor(min: Vector3 = new Vector3(Infinity, Infinity, Infinity),
                max: Vector3 = new Vector3(-Infinity, -Infinity, -Infinity)) {
        this.min = min;
        this.max = max;
    }

    set(min: Vector3, max: Vector3): Box3 {
        this.min.copy(min);
        this.max.copy(max);
        return this;
    }

    setFromArray(array: Array<f64>): Box3 {
        this.makeEmpty();
        for (let i = 0; i + 2 < array.length; i += 3) this.expandByPoint(_v.fromArray(array, i));
        return this;
    }

    setFromBufferAttribute(attribute: BufferAttribute): Box3 {
        this.makeEmpty();
        for (let i = 0, l = attribute.count; i < l; i++) {
            this.expandByPoint(_v.set(attribute.getX(i), attribute.getY(i), attribute.getZ(i)));
        }
        return this;
    }

    setFromPoints(points: Array<Vector3>): Box3 {
        this.makeEmpty();
        for (let i = 0; i < points.length; i++) this.expandByPoint(points[i]);
        return this;
    }

    setFromCenterAndSize(center: Vector3, size: Vector3): Box3 {
        const half = _v.copy(size).multiplyScalar(0.5);
        this.min.copy(center).sub(half);
        this.max.copy(center).add(half);
        return this;
    }

    /// The world-space box of `object` and its descendants' geometry.
    /// `precise` transforms every vertex instead of the geometry's box.
    setFromObject(object: Object3D, precise: bool = false): Box3 {
        this.makeEmpty();
        return this.expandByObject(object, precise);
    }

    clone(): Box3 { return new Box3(this.min.clone(), this.max.clone()); }
    copy(box: Box3): Box3 { this.min.copy(box.min); this.max.copy(box.max); return this; }

    makeEmpty(): Box3 {
        this.min.set(Infinity, Infinity, Infinity);
        this.max.set(-Infinity, -Infinity, -Infinity);
        return this;
    }

    isEmpty(): bool {
        return this.max.x < this.min.x || this.max.y < this.min.y || this.max.z < this.min.z;
    }

    getCenter(target: Vector3): Vector3 {
        return this.isEmpty() ? target.set(0, 0, 0) : target.addVectors(this.min, this.max).multiplyScalar(0.5);
    }

    getSize(target: Vector3): Vector3 {
        return this.isEmpty() ? target.set(0, 0, 0) : target.subVectors(this.max, this.min);
    }

    expandByPoint(point: Vector3): Box3 {
        this.min.min(point);
        this.max.max(point);
        return this;
    }

    expandByVector(vector: Vector3): Box3 {
        this.min.sub(vector);
        this.max.add(vector);
        return this;
    }

    expandByScalar(scalar: f64): Box3 {
        this.min.addScalar(-scalar);
        this.max.addScalar(scalar);
        return this;
    }

    expandByObject(object: Object3D, precise: bool = false): Box3 {
        object.updateWorldMatrix(false, false);
        const geometry = geometryOf(object);
        if (geometry != null) {
            const position = geometry.getAttribute("position");
            if (precise && position != null) {
                for (let i = 0, l = position.count; i < l; i++) {
                    _v.set(position.getX(i), position.getY(i), position.getZ(i)).applyMatrix4(object.matrixWorld);
                    this.expandByPoint(_v);
                }
            } else {
                if (geometry.boundingBox == null) geometry.computeBoundingBox();
                _box.copy(geometry.boundingBox!);
                _box.applyMatrix4(object.matrixWorld);
                this.union(_box);
            }
        }
        const children = object.children;
        for (let i = 0; i < children.length; i++) this.expandByObject(children[i], precise);
        return this;
    }

    containsPoint(point: Vector3): bool {
        return !(point.x < this.min.x || point.x > this.max.x || point.y < this.min.y
            || point.y > this.max.y || point.z < this.min.z || point.z > this.max.z);
    }

    containsBox(box: Box3): bool {
        return this.min.x <= box.min.x && box.max.x <= this.max.x
            && this.min.y <= box.min.y && box.max.y <= this.max.y
            && this.min.z <= box.min.z && box.max.z <= this.max.z;
    }

    /// Where `point` lies in the box, 0 to 1 per axis.
    getParameter(point: Vector3, target: Vector3): Vector3 {
        return target.set(
            (point.x - this.min.x) / (this.max.x - this.min.x),
            (point.y - this.min.y) / (this.max.y - this.min.y),
            (point.z - this.min.z) / (this.max.z - this.min.z));
    }

    intersectsBox(box: Box3): bool {
        return !(box.max.x < this.min.x || box.min.x > this.max.x || box.max.y < this.min.y
            || box.min.y > this.max.y || box.max.z < this.min.z || box.min.z > this.max.z);
    }

    intersectsSphere(sphere: Sphere): bool {
        this.clampPoint(sphere.center, _v);
        return _v.distanceToSquared(sphere.center) <= sphere.radius * sphere.radius;
    }

    intersectsPlane(plane: Plane): bool {
        let min: f64, max: f64;
        const n = plane.normal;
        if (n.x > 0) { min = n.x * this.min.x; max = n.x * this.max.x; }
        else { min = n.x * this.max.x; max = n.x * this.min.x; }
        if (n.y > 0) { min += n.y * this.min.y; max += n.y * this.max.y; }
        else { min += n.y * this.max.y; max += n.y * this.min.y; }
        if (n.z > 0) { min += n.z * this.min.z; max += n.z * this.max.z; }
        else { min += n.z * this.max.z; max += n.z * this.min.z; }
        return min <= -plane.constant && max >= -plane.constant;
    }

    /// Separating axis test against `triangle`.
    intersectsTriangle(triangle: Triangle): bool {
        if (this.isEmpty()) return false;
        this.getCenter(_center);
        _extents.subVectors(this.max, _center);
        _v0.subVectors(triangle.a, _center);
        _v1.subVectors(triangle.b, _center);
        _v2.subVectors(triangle.c, _center);
        _f0.subVectors(_v1, _v0);
        _f1.subVectors(_v2, _v1);
        _f2.subVectors(_v0, _v2);
        // three.js's axes arrays, one axis at a time (no arrays to allocate:
        // Octree.split calls this for every triangle and cell).
        // The nine cross products of the box's axes and the edges:
        if (!satAxis(0, -_f0.z, _f0.y) || !satAxis(0, -_f1.z, _f1.y) || !satAxis(0, -_f2.z, _f2.y)) return false;
        if (!satAxis(_f0.z, 0, -_f0.x) || !satAxis(_f1.z, 0, -_f1.x) || !satAxis(_f2.z, 0, -_f2.x)) return false;
        if (!satAxis(-_f0.y, _f0.x, 0) || !satAxis(-_f1.y, _f1.x, 0) || !satAxis(-_f2.y, _f2.x, 0)) return false;
        // The box's axes:
        if (!satAxis(1, 0, 0) || !satAxis(0, 1, 0) || !satAxis(0, 0, 1)) return false;
        // The triangle's normal:
        _normal.crossVectors(_f0, _f1);
        return satAxis(_normal.x, _normal.y, _normal.z);
    }

    clampPoint(point: Vector3, target: Vector3): Vector3 {
        return target.copy(point).clamp(this.min, this.max);
    }

    distanceToPoint(point: Vector3): f64 {
        return this.clampPoint(point, _v).distanceTo(point);
    }

    getBoundingSphere(target: Sphere): Sphere {
        if (this.isEmpty()) {
            target.makeEmpty();
        } else {
            this.getCenter(target.center);
            target.radius = this.getSize(_v).length() * 0.5;
        }
        return target;
    }

    intersect(box: Box3): Box3 {
        this.min.max(box.min);
        this.max.min(box.max);
        if (this.isEmpty()) this.makeEmpty();
        return this;
    }

    union(box: Box3): Box3 {
        this.min.min(box.min);
        this.max.max(box.max);
        return this;
    }

    applyMatrix4(matrix: Matrix4): Box3 {
        if (this.isEmpty()) return this;
        const mn = this.min, mx = this.max;
        _corners[0].set(mn.x, mn.y, mn.z).applyMatrix4(matrix);
        _corners[1].set(mn.x, mn.y, mx.z).applyMatrix4(matrix);
        _corners[2].set(mn.x, mx.y, mn.z).applyMatrix4(matrix);
        _corners[3].set(mn.x, mx.y, mx.z).applyMatrix4(matrix);
        _corners[4].set(mx.x, mn.y, mn.z).applyMatrix4(matrix);
        _corners[5].set(mx.x, mn.y, mx.z).applyMatrix4(matrix);
        _corners[6].set(mx.x, mx.y, mn.z).applyMatrix4(matrix);
        _corners[7].set(mx.x, mx.y, mx.z).applyMatrix4(matrix);
        return this.setFromPoints(_corners);
    }

    translate(offset: Vector3): Box3 {
        this.min.add(offset);
        this.max.add(offset);
        return this;
    }

    equals(box: Box3): bool { return box.min.equals(this.min) && box.max.equals(this.max); }
}

// three.js's satForAxes for one axis, on intersectsTriangle's _v0, _v1,
// _v2 and _extents.
function satAxis(x: f64, y: f64, z: f64): bool {
    _testAxis.set(x, y, z);
    const r = _extents.x * Math.abs(_testAxis.x) + _extents.y * Math.abs(_testAxis.y) + _extents.z * Math.abs(_testAxis.z);
    const p0 = _v0.dot(_testAxis), p1 = _v1.dot(_testAxis), p2 = _v2.dot(_testAxis);
    return !(Math.max(-Math.max(p0, Math.max(p1, p2)), Math.min(p0, Math.min(p1, p2))) > r);
}

const _v: Vector3 = new Vector3();
const _box: Box3 = new Box3();
const _corners: Array<Vector3> = [
    new Vector3(), new Vector3(), new Vector3(), new Vector3(),
    new Vector3(), new Vector3(), new Vector3(), new Vector3(),
];
const _center: Vector3 = new Vector3();
const _extents: Vector3 = new Vector3();
const _v0: Vector3 = new Vector3();
const _v1: Vector3 = new Vector3();
const _v2: Vector3 = new Vector3();
const _f0: Vector3 = new Vector3();
const _f1: Vector3 = new Vector3();
const _f2: Vector3 = new Vector3();
const _normal: Vector3 = new Vector3();
const _testAxis: Vector3 = new Vector3();
