// three.js Ray: origin + t * direction, t >= 0. Intersections that return
// null in three.js return null here too, except distanceToPlane, which
// returns -1 for "no intersection" (a number cannot be null).

import { Vector3 } from "./Vector3";
import { Matrix4 } from "./Matrix4";
import { Sphere } from "./Sphere";
import { Plane } from "./Plane";
import { Box3 } from "./Box3";

export class Ray {
    origin: Vector3;
    /// Unit length.
    direction: Vector3;

    constructor(origin: Vector3 = new Vector3(), direction: Vector3 = new Vector3(0, 0, -1)) {
        this.origin = origin;
        this.direction = direction;
    }

    set(origin: Vector3, direction: Vector3): Ray {
        this.origin.copy(origin);
        this.direction.copy(direction);
        return this;
    }

    copy(ray: Ray): Ray { return this.set(ray.origin, ray.direction); }
    clone(): Ray { return new Ray(this.origin.clone(), this.direction.clone()); }

    at(t: f64, target: Vector3): Vector3 {
        return target.copy(this.origin).addScaledVector(this.direction, t);
    }

    lookAt(v: Vector3): Ray {
        this.direction.copy(v).sub(this.origin).normalize();
        return this;
    }

    recast(t: f64): Ray {
        this.origin.copy(this.at(t, _vector));
        return this;
    }

    closestPointToPoint(point: Vector3, target: Vector3): Vector3 {
        target.subVectors(point, this.origin);
        const d = target.dot(this.direction);
        if (d < 0) return target.copy(this.origin);
        return target.copy(this.origin).addScaledVector(this.direction, d);
    }

    distanceToPoint(point: Vector3): f64 { return Math.sqrt(this.distanceSqToPoint(point)); }

    distanceSqToPoint(point: Vector3): f64 {
        const d = _vector.subVectors(point, this.origin).dot(this.direction);
        if (d < 0) return this.origin.distanceToSquared(point);
        _vector.copy(this.origin).addScaledVector(this.direction, d);
        return _vector.distanceToSquared(point);
    }

    /// The squared distance between the ray and segment v0-v1; fills the
    /// closest points when given.
    distanceSqToSegment(v0: Vector3, v1: Vector3, optionalPointOnRay: Vector3? = null,
                        optionalPointOnSegment: Vector3? = null): f64 {
        _segCenter.copy(v0).add(v1).multiplyScalar(0.5);
        _segDir.copy(v1).sub(v0).normalize();
        _diff.copy(this.origin).sub(_segCenter);
        const segExtent = v0.distanceTo(v1) * 0.5;
        const a01 = -this.direction.dot(_segDir);
        const b0 = _diff.dot(this.direction);
        const b1 = -_diff.dot(_segDir);
        const c = _diff.lengthSq();
        const det = Math.abs(1 - a01 * a01);
        let s0: f64, s1: f64, sqrDist: f64;
        if (det > 0) {
            s0 = a01 * b1 - b0;
            s1 = a01 * b0 - b1;
            const extDet = segExtent * det;
            if (s0 >= 0) {
                if (s1 >= -extDet) {
                    if (s1 <= extDet) {
                        const invDet = 1 / det;
                        s0 *= invDet;
                        s1 *= invDet;
                        sqrDist = s0 * (s0 + a01 * s1 + 2 * b0) + s1 * (a01 * s0 + s1 + 2 * b1) + c;
                    } else {
                        s1 = segExtent;
                        s0 = Math.max(0, -(a01 * s1 + b0));
                        sqrDist = -s0 * s0 + s1 * (s1 + 2 * b1) + c;
                    }
                } else {
                    s1 = -segExtent;
                    s0 = Math.max(0, -(a01 * s1 + b0));
                    sqrDist = -s0 * s0 + s1 * (s1 + 2 * b1) + c;
                }
            } else {
                if (s1 <= -extDet) {
                    s0 = Math.max(0, -(-a01 * segExtent + b0));
                    s1 = s0 > 0 ? -segExtent : Math.min(Math.max(-segExtent, -b1), segExtent);
                    sqrDist = -s0 * s0 + s1 * (s1 + 2 * b1) + c;
                } else if (s1 <= extDet) {
                    s0 = 0;
                    s1 = Math.min(Math.max(-segExtent, -b1), segExtent);
                    sqrDist = s1 * (s1 + 2 * b1) + c;
                } else {
                    s0 = Math.max(0, -(a01 * segExtent + b0));
                    s1 = s0 > 0 ? segExtent : Math.min(Math.max(-segExtent, -b1), segExtent);
                    sqrDist = -s0 * s0 + s1 * (s1 + 2 * b1) + c;
                }
            }
        } else {
            s1 = a01 > 0 ? -segExtent : segExtent;
            s0 = Math.max(0, -(a01 * s1 + b0));
            sqrDist = -s0 * s0 + s1 * (s1 + 2 * b1) + c;
        }
        if (optionalPointOnRay != null) optionalPointOnRay.copy(this.origin).addScaledVector(this.direction, s0);
        if (optionalPointOnSegment != null) optionalPointOnSegment.copy(_segCenter).addScaledVector(_segDir, s1);
        return sqrDist;
    }

    intersectSphere(sphere: Sphere, target: Vector3): Vector3? {
        _vector.subVectors(sphere.center, this.origin);
        const tca = _vector.dot(this.direction);
        const d2 = _vector.dot(_vector) - tca * tca;
        const radius2 = sphere.radius * sphere.radius;
        if (d2 > radius2) return null;
        const thc = Math.sqrt(radius2 - d2);
        const t0 = tca - thc;
        const t1 = tca + thc;
        if (t1 < 0) return null;
        if (t0 < 0) return this.at(t1, target);
        return this.at(t0, target);
    }

    intersectsSphere(sphere: Sphere): bool {
        return this.distanceSqToPoint(sphere.center) <= sphere.radius * sphere.radius;
    }

    /// The distance along the ray to `plane`, or -1 when it never reaches it
    /// (three.js returns null).
    distanceToPlane(plane: Plane): f64 {
        const denominator = plane.normal.dot(this.direction);
        if (denominator == 0) {
            if (plane.distanceToPoint(this.origin) == 0) return 0;
            return -1;
        }
        const t = -(this.origin.dot(plane.normal) + plane.constant) / denominator;
        return t >= 0 ? t : -1;
    }

    intersectPlane(plane: Plane, target: Vector3): Vector3? {
        const t = this.distanceToPlane(plane);
        if (t < 0) return null;
        return this.at(t, target);
    }

    intersectsPlane(plane: Plane): bool {
        const distToPoint = plane.distanceToPoint(this.origin);
        if (distToPoint == 0) return true;
        const denominator = plane.normal.dot(this.direction);
        return denominator * distToPoint < 0;
    }

    intersectBox(box: Box3, target: Vector3): Vector3? {
        let tmin: f64, tmax: f64, tymin: f64, tymax: f64, tzmin: f64, tzmax: f64;
        const invdirx = 1 / this.direction.x, invdiry = 1 / this.direction.y, invdirz = 1 / this.direction.z;
        const origin = this.origin;
        if (invdirx >= 0) { tmin = (box.min.x - origin.x) * invdirx; tmax = (box.max.x - origin.x) * invdirx; }
        else { tmin = (box.max.x - origin.x) * invdirx; tmax = (box.min.x - origin.x) * invdirx; }
        if (invdiry >= 0) { tymin = (box.min.y - origin.y) * invdiry; tymax = (box.max.y - origin.y) * invdiry; }
        else { tymin = (box.max.y - origin.y) * invdiry; tymax = (box.min.y - origin.y) * invdiry; }
        if (tmin > tymax || tymin > tmax) return null;
        if (tymin > tmin || isNaN(tmin)) tmin = tymin;
        if (tymax < tmax || isNaN(tmax)) tmax = tymax;
        if (invdirz >= 0) { tzmin = (box.min.z - origin.z) * invdirz; tzmax = (box.max.z - origin.z) * invdirz; }
        else { tzmin = (box.max.z - origin.z) * invdirz; tzmax = (box.min.z - origin.z) * invdirz; }
        if (tmin > tzmax || tzmin > tmax) return null;
        if (tzmin > tmin || isNaN(tmin)) tmin = tzmin;
        if (tzmax < tmax || isNaN(tmax)) tmax = tzmax;
        if (tmax < 0) return null;
        return this.at(tmin >= 0 ? tmin : tmax, target);
    }

    intersectsBox(box: Box3): bool { return this.intersectBox(box, _vector) != null; }

    /// Möller–Trumbore; null on a miss (or a back face when culling).
    intersectTriangle(a: Vector3, b: Vector3, c: Vector3, backfaceCulling: bool, target: Vector3): Vector3? {
        _edge1.subVectors(b, a);
        _edge2.subVectors(c, a);
        _normal.crossVectors(_edge1, _edge2);
        let DdN = this.direction.dot(_normal);
        let sign: f64;
        if (DdN > 0) {
            if (backfaceCulling) return null;
            sign = 1;
        } else if (DdN < 0) {
            sign = -1;
            DdN = -DdN;
        } else {
            return null;
        }
        _diff.subVectors(this.origin, a);
        const DdQxE2 = sign * this.direction.dot(_edge2.crossVectors(_diff, _edge2));
        if (DdQxE2 < 0) return null;
        const DdE1xQ = sign * this.direction.dot(_edge1.cross(_diff));
        if (DdE1xQ < 0) return null;
        if (DdQxE2 + DdE1xQ > DdN) return null;
        const QdN = -sign * _diff.dot(_normal);
        if (QdN < 0) return null;
        return this.at(QdN / DdN, target);
    }

    applyMatrix4(matrix4: Matrix4): Ray {
        this.origin.applyMatrix4(matrix4);
        this.direction.transformDirection(matrix4);
        return this;
    }

    equals(ray: Ray): bool { return ray.origin.equals(this.origin) && ray.direction.equals(this.direction); }
}

const _vector: Vector3 = new Vector3();
const _segCenter: Vector3 = new Vector3();
const _segDir: Vector3 = new Vector3();
const _diff: Vector3 = new Vector3();
const _edge1: Vector3 = new Vector3();
const _edge2: Vector3 = new Vector3();
const _normal: Vector3 = new Vector3();
