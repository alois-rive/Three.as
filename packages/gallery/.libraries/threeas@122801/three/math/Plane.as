// three.js Plane: the points p with normal . p + constant = 0.

import { Vector3 } from "./Vector3";
import { Matrix3 } from "./Matrix3";
import { Matrix4 } from "./Matrix4";
import { Sphere } from "./Sphere";
import { Box3 } from "./Box3";
import { Line3 } from "./Line3";

export class Plane {
    readonly isPlane: bool = true;
    normal: Vector3;
    constant: f64;

    constructor(normal: Vector3 = new Vector3(1, 0, 0), constant: f64 = 0) {
        this.normal = normal;
        this.constant = constant;
    }

    set(normal: Vector3, constant: f64): Plane {
        this.normal.copy(normal);
        this.constant = constant;
        return this;
    }

    setComponents(x: f64, y: f64, z: f64, w: f64): Plane {
        this.normal.set(x, y, z);
        this.constant = w;
        return this;
    }

    setFromNormalAndCoplanarPoint(normal: Vector3, point: Vector3): Plane {
        this.normal.copy(normal);
        this.constant = -point.dot(this.normal);
        return this;
    }

    /// Counter-clockwise a, b, c face the normal.
    setFromCoplanarPoints(a: Vector3, b: Vector3, c: Vector3): Plane {
        const normal = _v1.subVectors(c, b).cross(_v2.subVectors(a, b)).normalize();
        return this.setFromNormalAndCoplanarPoint(normal, a);
    }

    copy(plane: Plane): Plane {
        this.normal.copy(plane.normal);
        this.constant = plane.constant;
        return this;
    }

    clone(): Plane { return new Plane(this.normal.clone(), this.constant); }

    normalize(): Plane {
        const inverseNormalLength = 1 / this.normal.length();
        this.normal.multiplyScalar(inverseNormalLength);
        this.constant *= inverseNormalLength;
        return this;
    }

    negate(): Plane {
        this.constant *= -1;
        this.normal.negate();
        return this;
    }

    distanceToPoint(point: Vector3): f64 { return this.normal.dot(point) + this.constant; }

    distanceToSphere(sphere: Sphere): f64 { return this.distanceToPoint(sphere.center) - sphere.radius; }

    projectPoint(point: Vector3, target: Vector3): Vector3 {
        return target.copy(point).addScaledVector(this.normal, -this.distanceToPoint(point));
    }

    /// Where `line` crosses the plane, or null.
    intersectLine(line: Line3, target: Vector3): Vector3? {
        const direction = line.delta(_v1);
        const denominator = this.normal.dot(direction);
        if (denominator == 0) {
            if (this.distanceToPoint(line.start) == 0) return target.copy(line.start);
            return null;
        }
        const t = -(line.start.dot(this.normal) + this.constant) / denominator;
        if (t < 0 || t > 1) return null;
        return target.copy(line.start).addScaledVector(direction, t);
    }

    intersectsLine(line: Line3): bool {
        const startSign = this.distanceToPoint(line.start);
        const endSign = this.distanceToPoint(line.end);
        return (startSign < 0 && endSign > 0) || (endSign < 0 && startSign > 0);
    }

    intersectsBox(box: Box3): bool { return box.intersectsPlane(this); }

    intersectsSphere(sphere: Sphere): bool { return sphere.intersectsPlane(this); }

    coplanarPoint(target: Vector3): Vector3 {
        return target.copy(this.normal).multiplyScalar(-this.constant);
    }

    applyMatrix4(matrix: Matrix4, optionalNormalMatrix: Matrix3? = null): Plane {
        const normalMatrix = optionalNormalMatrix != null ? optionalNormalMatrix : _m.getNormalMatrix(matrix);
        const referencePoint = this.coplanarPoint(_v1).applyMatrix4(matrix);
        const normal = this.normal.applyMatrix3(normalMatrix).normalize();
        this.constant = -referencePoint.dot(normal);
        return this;
    }

    translate(offset: Vector3): Plane {
        this.constant -= offset.dot(this.normal);
        return this;
    }

    equals(plane: Plane): bool {
        return plane.normal.equals(this.normal) && plane.constant == this.constant;
    }
}

const _v1: Vector3 = new Vector3();
const _v2: Vector3 = new Vector3();
const _m: Matrix3 = new Matrix3();
