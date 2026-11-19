// three.js Triangle.

import { Vector3 } from "./Vector3";
import { Plane } from "./Plane";
import { Box3 } from "./Box3";
import { BufferAttribute } from "../core/BufferAttribute";

export class Triangle {
    a: Vector3;
    b: Vector3;
    c: Vector3;

    constructor(a: Vector3 = new Vector3(), b: Vector3 = new Vector3(), c: Vector3 = new Vector3()) {
        this.a = a;
        this.b = b;
        this.c = c;
    }

    static getNormal(a: Vector3, b: Vector3, c: Vector3, target: Vector3): Vector3 {
        target.subVectors(c, b);
        _v0.subVectors(a, b);
        target.cross(_v0);
        const l = target.lengthSq();
        if (l > 0) return target.multiplyScalar(1 / Math.sqrt(l));
        return target.set(0, 0, 0);
    }

    /// The barycentric coordinates of `point`, or null for a degenerate
    /// triangle (target is then zeroed).
    static getBarycoord(point: Vector3, a: Vector3, b: Vector3, c: Vector3, target: Vector3): Vector3? {
        _v0.subVectors(c, a);
        _v1.subVectors(b, a);
        _v2.subVectors(point, a);
        const dot00 = _v0.dot(_v0), dot01 = _v0.dot(_v1), dot02 = _v0.dot(_v2);
        const dot11 = _v1.dot(_v1), dot12 = _v1.dot(_v2);
        const denom = dot00 * dot11 - dot01 * dot01;
        if (denom == 0) {
            target.set(0, 0, 0);
            return null;
        }
        const invDenom = 1 / denom;
        const u = (dot11 * dot02 - dot01 * dot12) * invDenom;
        const v = (dot00 * dot12 - dot01 * dot02) * invDenom;
        return target.set(1 - u - v, v, u);
    }

    static containsPoint(point: Vector3, a: Vector3, b: Vector3, c: Vector3): bool {
        if (Triangle.getBarycoord(point, a, b, c, _v3) == null) return false;
        return _v3.x >= 0 && _v3.y >= 0 && (_v3.x + _v3.y) <= 1;
    }

    /// Interpolates per-vertex values v1, v2, v3 (Vector2, Vector3 or
    /// Vector4) at `point`. A degenerate triangle gives zero (three.js
    /// returns null).
    static getInterpolation<V>(point: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
                               v1: V, v2: V, v3: V, target: V): V {
        if (Triangle.getBarycoord(point, p1, p2, p3, _v3) == null) {
            target.setScalar(0);
            return target;
        }
        target.setScalar(0);
        target.addScaledVector(v1, _v3.x);
        target.addScaledVector(v2, _v3.y);
        target.addScaledVector(v3, _v3.z);
        return target;
    }

    static isFrontFacing(a: Vector3, b: Vector3, c: Vector3, direction: Vector3): bool {
        _v0.subVectors(c, b);
        _v1.subVectors(a, b);
        return _v0.cross(_v1).dot(direction) < 0;
    }

    set(a: Vector3, b: Vector3, c: Vector3): Triangle {
        this.a.copy(a);
        this.b.copy(b);
        this.c.copy(c);
        return this;
    }

    setFromPointsAndIndices(points: Array<Vector3>, i0: i32, i1: i32, i2: i32): Triangle {
        return this.set(points[i0], points[i1], points[i2]);
    }

    setFromAttributeAndIndices(attribute: BufferAttribute, i0: i32, i1: i32, i2: i32): Triangle {
        this.a.set(attribute.getX(i0), attribute.getY(i0), attribute.getZ(i0));
        this.b.set(attribute.getX(i1), attribute.getY(i1), attribute.getZ(i1));
        this.c.set(attribute.getX(i2), attribute.getY(i2), attribute.getZ(i2));
        return this;
    }

    clone(): Triangle { return new Triangle(this.a.clone(), this.b.clone(), this.c.clone()); }
    copy(t: Triangle): Triangle { return this.set(t.a, t.b, t.c); }

    getArea(): f64 {
        _v0.subVectors(this.c, this.b);
        _v1.subVectors(this.a, this.b);
        return _v0.cross(_v1).length() * 0.5;
    }

    getMidpoint(target: Vector3): Vector3 {
        return target.addVectors(this.a, this.b).add(this.c).multiplyScalar(1.0 / 3);
    }

    getNormal(target: Vector3): Vector3 { return Triangle.getNormal(this.a, this.b, this.c, target); }

    getPlane(target: Plane): Plane { return target.setFromCoplanarPoints(this.a, this.b, this.c); }

    getBarycoord(point: Vector3, target: Vector3): Vector3? {
        return Triangle.getBarycoord(point, this.a, this.b, this.c, target);
    }

    containsPoint(point: Vector3): bool { return Triangle.containsPoint(point, this.a, this.b, this.c); }

    isFrontFacing(direction: Vector3): bool { return Triangle.isFrontFacing(this.a, this.b, this.c, direction); }

    intersectsBox(box: Box3): bool { return box.intersectsTriangle(this); }

    closestPointToPoint(p: Vector3, target: Vector3): Vector3 {
        const a = this.a, b = this.b, c = this.c;
        _vab.subVectors(b, a);
        _vac.subVectors(c, a);
        _vap.subVectors(p, a);
        const d1 = _vab.dot(_vap);
        const d2 = _vac.dot(_vap);
        if (d1 <= 0 && d2 <= 0) return target.copy(a);
        _vbp.subVectors(p, b);
        const d3 = _vab.dot(_vbp);
        const d4 = _vac.dot(_vbp);
        if (d3 >= 0 && d4 <= d3) return target.copy(b);
        const vc = d1 * d4 - d3 * d2;
        if (vc <= 0 && d1 >= 0 && d3 <= 0) return target.copy(a).addScaledVector(_vab, d1 / (d1 - d3));
        _vcp.subVectors(p, c);
        const d5 = _vab.dot(_vcp);
        const d6 = _vac.dot(_vcp);
        if (d6 >= 0 && d5 <= d6) return target.copy(c);
        const vb = d5 * d2 - d1 * d6;
        if (vb <= 0 && d2 >= 0 && d6 <= 0) return target.copy(a).addScaledVector(_vac, d2 / (d2 - d6));
        const va = d3 * d6 - d5 * d4;
        if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
            _vbc.subVectors(c, b);
            return target.copy(b).addScaledVector(_vbc, (d4 - d3) / ((d4 - d3) + (d5 - d6)));
        }
        const denom = 1 / (va + vb + vc);
        return target.copy(a).addScaledVector(_vab, vb * denom).addScaledVector(_vac, vc * denom);
    }

    equals(t: Triangle): bool { return t.a.equals(this.a) && t.b.equals(this.b) && t.c.equals(this.c); }
}

const _v0: Vector3 = new Vector3();
const _v1: Vector3 = new Vector3();
const _v2: Vector3 = new Vector3();
const _v3: Vector3 = new Vector3();
const _vab: Vector3 = new Vector3();
const _vac: Vector3 = new Vector3();
const _vbc: Vector3 = new Vector3();
const _vap: Vector3 = new Vector3();
const _vbp: Vector3 = new Vector3();
const _vcp: Vector3 = new Vector3();
