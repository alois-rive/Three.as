// The convex hull of a point set (three.js examples/jsm/math/ConvexHull.js
// has the same purpose): an incremental hull. Start from a tetrahedron,
// then each point outside sees some faces; they are removed and the
// horizon is joined to the point. Faces are counter-clockwise from
// outside. Fine for the hundreds to thousands of points a ConvexGeometry
// takes.

import { Vector3 } from "../../math/Vector3";
import { Object3D } from "../../core/Object3D";
import { geometryOf } from "../../core/geometryOf";

export class HullFace {
    a: i32;
    b: i32;
    c: i32;
    normal: Vector3 = new Vector3();
    constant: f64 = 0;

    constructor(a: i32, b: i32, c: i32) {
        this.a = a;
        this.b = b;
        this.c = c;
    }
}

const _ab = new Vector3();
const _ac = new Vector3();

export class ConvexHull {
    points: Array<Vector3> = [];
    faces: Array<HullFace> = [];
    tolerance: f64 = 0;

    setFromPoints(points: Array<Vector3>): ConvexHull {
        this.points = [];
        for (let i = 0; i < points.length; i++) this.points.push(points[i].clone());
        this.faces = [];
        if (this.points.length < 4) return this;
        this.build();
        return this;
    }

    /// The hull of an object's vertices, in world space.
    setFromObject(object: Object3D): ConvexHull {
        const points: Array<Vector3> = [];
        object.updateMatrixWorld(true);
        collect(object, points);
        return this.setFromPoints(points);
    }

    containsPoint(point: Vector3): bool {
        for (let i = 0; i < this.faces.length; i++) {
            const f = this.faces[i];
            if (f.normal.dot(point) - f.constant > this.tolerance) return false;
        }
        return true;
    }

    private makeFace(a: i32, b: i32, c: i32): HullFace {
        const f = new HullFace(a, b, c);
        const p = this.points;
        _ab.subVectors(p[b], p[a]);
        _ac.subVectors(p[c], p[a]);
        f.normal.crossVectors(_ab, _ac).normalize();
        f.constant = f.normal.dot(p[a]);
        return f;
    }

    private build(): void {
        const p = this.points;
        const n = p.length;
        // Tolerance from the extent, as three.js.
        let maxAbs: f64 = 0;
        for (let i = 0; i < n; i++) {
            maxAbs = Math.max(maxAbs, Math.max(Math.abs(p[i].x), Math.max(Math.abs(p[i].y), Math.abs(p[i].z))));
        }
        this.tolerance = 3 * 2.220446049250313e-16 * maxAbs * 3;
        const eps = Math.max(this.tolerance, 1e-10 * Math.max(1, maxAbs));
        // Initial tetrahedron: the extreme pair, the farthest from their
        // line, the farthest from their plane.
        let i0 = 0, i1 = 0;
        let best: f64 = -1;
        for (let axis = 0; axis < 3; axis++) {
            let lo = 0, hi = 0;
            for (let i = 1; i < n; i++) {
                if (p[i].getComponent(axis) < p[lo].getComponent(axis)) lo = i;
                if (p[i].getComponent(axis) > p[hi].getComponent(axis)) hi = i;
            }
            const d = p[hi].getComponent(axis) - p[lo].getComponent(axis);
            if (d > best) { best = d; i0 = lo; i1 = hi; }
        }
        let i2 = -1;
        best = -1;
        const line = new Vector3().subVectors(p[i1], p[i0]).normalize();
        const t = new Vector3();
        for (let i = 0; i < n; i++) {
            t.subVectors(p[i], p[i0]);
            const d = t.addScaledVector(line, -t.dot(line)).lengthSq();
            if (d > best) { best = d; i2 = i; }
        }
        const base = this.makeFace(i0, i1, i2);
        let i3 = -1;
        best = -1;
        for (let i = 0; i < n; i++) {
            const d = Math.abs(base.normal.dot(p[i]) - base.constant);
            if (d > best) { best = d; i3 = i; }
        }
        if (best <= eps) return;   // flat: no volume
        // Orient the faces outward (the fourth point behind the base).
        let faces: Array<HullFace>;
        if (base.normal.dot(p[i3]) - base.constant > 0) {
            faces = [this.makeFace(i0, i2, i1), this.makeFace(i0, i1, i3), this.makeFace(i1, i2, i3), this.makeFace(i2, i0, i3)];
        } else {
            faces = [this.makeFace(i0, i1, i2), this.makeFace(i0, i3, i1), this.makeFace(i1, i3, i2), this.makeFace(i2, i3, i0)];
        }
        // Add the other points.
        for (let i = 0; i < n; i++) {
            if (i == i0 || i == i1 || i == i2 || i == i3) continue;
            const visible: Array<bool> = [];
            let any = false;
            for (let f = 0; f < faces.length; f++) {
                const v = faces[f].normal.dot(p[i]) - faces[f].constant > eps;
                visible.push(v);
                if (v) any = true;
            }
            if (!any) continue;
            // Horizon: directed edges of visible faces whose twin is not visible.
            const edges = new Map<i64, bool>();
            for (let f = 0; f < faces.length; f++) {
                if (!visible[f]) continue;
                const fc = faces[f];
                edges.set(edgeKey(fc.a, fc.b), true);
                edges.set(edgeKey(fc.b, fc.c), true);
                edges.set(edgeKey(fc.c, fc.a), true);
            }
            const next: Array<HullFace> = [];
            for (let f = 0; f < faces.length; f++) {
                const fc = faces[f];
                if (!visible[f]) {
                    next.push(fc);
                    continue;
                }
                const es: StaticArray<i32> = [fc.a, fc.b, fc.b, fc.c, fc.c, fc.a];
                for (let e = 0; e < 6; e += 2) {
                    if (!edges.has(edgeKey(es[e + 1], es[e]))) next.push(this.makeFace(es[e], es[e + 1], i));
                }
            }
            faces = next;
        }
        this.faces = faces;
    }
}

function edgeKey(a: i32, b: i32): i64 { return (<i64>a << 32) | <i64>b; }

function collect(o: Object3D, out: Array<Vector3>): void {
    const g = geometryOf(o);
    if (g != null) {
        const position = g.getAttribute("position");
        if (position != null) {
            for (let i = 0; i < position.count; i++) {
                out.push(new Vector3().fromBufferAttribute(position, i).applyMatrix4(o.matrixWorld));
            }
        }
    }
    for (let i = 0; i < o.children.length; i++) collect(o.children[i], out);
}
