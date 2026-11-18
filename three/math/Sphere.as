// three.js Sphere. Empty is radius < 0.

import { Vector3 } from "./Vector3";
import { Matrix4 } from "./Matrix4";
import { Box3 } from "./Box3";
import { Plane } from "./Plane";

export class Sphere {
    readonly isSphere: bool = true;
    center: Vector3;
    radius: f64;

    constructor(center: Vector3 = new Vector3(), radius: f64 = -1) {
        this.center = center;
        this.radius = radius;
    }

    set(center: Vector3, radius: f64): Sphere {
        this.center.copy(center);
        this.radius = radius;
        return this;
    }

    /// The smallest sphere around `optionalCenter` (default: the points'
    /// bounding box centre) holding every point.
    setFromPoints(points: Array<Vector3>, optionalCenter: Vector3? = null): Sphere {
        const center = this.center;
        if (optionalCenter != null) center.copy(optionalCenter);
        else _box.setFromPoints(points).getCenter(center);
        let maxRadiusSq: f64 = 0;
        for (let i = 0; i < points.length; i++) maxRadiusSq = Math.max(maxRadiusSq, center.distanceToSquared(points[i]));
        this.radius = Math.sqrt(maxRadiusSq);
        return this;
    }

    copy(sphere: Sphere): Sphere {
        this.center.copy(sphere.center);
        this.radius = sphere.radius;
        return this;
    }

    clone(): Sphere { return new Sphere(this.center.clone(), this.radius); }

    isEmpty(): bool { return this.radius < 0; }

    makeEmpty(): Sphere {
        this.center.set(0, 0, 0);
        this.radius = -1;
        return this;
    }

    containsPoint(point: Vector3): bool {
        return point.distanceToSquared(this.center) <= this.radius * this.radius;
    }

    distanceToPoint(point: Vector3): f64 { return point.distanceTo(this.center) - this.radius; }

    intersectsSphere(sphere: Sphere): bool {
        const r = this.radius + sphere.radius;
        return sphere.center.distanceToSquared(this.center) <= r * r;
    }

    intersectsBox(box: Box3): bool { return box.intersectsSphere(this); }

    intersectsPlane(plane: Plane): bool { return Math.abs(plane.distanceToPoint(this.center)) <= this.radius; }

    clampPoint(point: Vector3, target: Vector3): Vector3 {
        const d = this.center.distanceToSquared(point);
        target.copy(point);
        if (d > this.radius * this.radius) {
            target.sub(this.center).normalize();
            target.multiplyScalar(this.radius).add(this.center);
        }
        return target;
    }

    getBoundingBox(target: Box3): Box3 {
        if (this.isEmpty()) {
            target.makeEmpty();
            return target;
        }
        target.set(this.center, this.center);
        target.expandByScalar(this.radius);
        return target;
    }

    applyMatrix4(matrix: Matrix4): Sphere {
        this.center.applyMatrix4(matrix);
        this.radius = this.radius * matrix.getMaxScaleOnAxis();
        return this;
    }

    translate(offset: Vector3): Sphere {
        this.center.add(offset);
        return this;
    }

    expandByPoint(point: Vector3): Sphere {
        if (this.isEmpty()) {
            this.center.copy(point);
            this.radius = 0;
            return this;
        }
        _v.subVectors(point, this.center);
        const lengthSq = _v.lengthSq();
        if (lengthSq > this.radius * this.radius) {
            const length = Math.sqrt(lengthSq);
            const delta = (length - this.radius) * 0.5;
            this.center.addScaledVector(_v, delta / length);
            this.radius += delta;
        }
        return this;
    }

    union(sphere: Sphere): Sphere {
        if (sphere.isEmpty()) return this;
        if (this.isEmpty()) return this.copy(sphere);
        if (this.center.equals(sphere.center)) {
            this.radius = Math.max(this.radius, sphere.radius);
        } else {
            _v2.subVectors(sphere.center, this.center).setLength(sphere.radius);
            this.expandByPoint(_v.copy(sphere.center).add(_v2));
            this.expandByPoint(_v.copy(sphere.center).sub(_v2));
        }
        return this;
    }

    equals(sphere: Sphere): bool {
        return sphere.center.equals(this.center) && sphere.radius == this.radius;
    }
}

const _box: Box3 = new Box3();
const _v: Vector3 = new Vector3();
const _v2: Vector3 = new Vector3();
