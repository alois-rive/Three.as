// three.js Curve, generic over its point type: Curve<Vector2> for 2D
// curves, Curve<Vector3> for 3D. Subclasses implement getPoint(t, target).
// Arc-length parameterization (getPointAt, getSpacedPoints) as three.js.

import { Vector3 } from "../../math/Vector3";
import { Matrix4 } from "../../math/Matrix4";

export class FrenetFrames {
    tangents: Array<Vector3> = [];
    normals: Array<Vector3> = [];
    binormals: Array<Vector3> = [];
}

export class Curve<V> {
    readonly isCurve: bool = true;
    type: string = "Curve";
    /// Samples used to measure arc length.
    arcLengthDivisions: i32 = 200;
    /// Set to true after changing the curve, to remeasure it.
    needsUpdate: bool = false;
    protected cacheArcLengths: Array<f64> = [];

    /// The point at `t` in [0, 1] (curve parameter, not arc length).
    getPoint(t: f64, target: V): V {
        return target;
    }

    /// The point at `u` in [0, 1] of the arc length.
    getPointAt(u: f64, target: V): V {
        return this.getPoint(this.getUtoTmapping(u), target);
    }

    getPoints(divisions: i32 = 5): Array<V> {
        const points: Array<V> = [];
        for (let d = 0; d <= divisions; d++) points.push(this.getPoint(<f64>d / <f64>divisions, instantiate<V>()));
        return points;
    }

    getSpacedPoints(divisions: i32 = 5): Array<V> {
        const points: Array<V> = [];
        for (let d = 0; d <= divisions; d++) points.push(this.getPointAt(<f64>d / <f64>divisions, instantiate<V>()));
        return points;
    }

    getLength(): f64 {
        const lengths = this.getLengths();
        return lengths[lengths.length - 1];
    }

    getLengths(divisions: i32 = -1): Array<f64> {
        if (divisions < 0) divisions = this.arcLengthDivisions;
        if (this.cacheArcLengths.length == divisions + 1 && !this.needsUpdate) return this.cacheArcLengths;
        this.needsUpdate = false;
        const cache: Array<f64> = [0];
        let last = this.getPoint(0, instantiate<V>());
        let sum: f64 = 0;
        for (let p = 1; p <= divisions; p++) {
            const current = this.getPoint(<f64>p / <f64>divisions, instantiate<V>());
            sum += current.distanceTo(last);
            cache.push(sum);
            last = current;
        }
        this.cacheArcLengths = cache;
        return cache;
    }

    updateArcLengths(): void {
        this.needsUpdate = true;
        this.getLengths();
    }

    /// The curve parameter t at arc-length fraction u (or at `distance`
    /// along the curve when >= 0).
    getUtoTmapping(u: f64, distance: f64 = -1): f64 {
        const arcLengths = this.getLengths();
        const il = arcLengths.length;
        const targetArcLength = distance >= 0 ? distance : u * arcLengths[il - 1];
        let low = 0, high = il - 1;
        let i = 0;
        while (low <= high) {
            i = low + (high - low) / 2;
            const comparison = arcLengths[i] - targetArcLength;
            if (comparison < 0) low = i + 1;
            else if (comparison > 0) high = i - 1;
            else {
                high = i;
                break;
            }
        }
        i = max<i32>(0, high);
        if (arcLengths[i] == targetArcLength) return <f64>i / <f64>(il - 1);
        if (i + 1 >= il) return 1;
        const lengthBefore = arcLengths[i];
        const segmentLength = arcLengths[i + 1] - lengthBefore;
        const segmentFraction = segmentLength > 0 ? (targetArcLength - lengthBefore) / segmentLength : 0;
        return (<f64>i + segmentFraction) / <f64>(il - 1);
    }

    /// The unit tangent at t (finite difference).
    getTangent(t: f64, target: V): V {
        const delta = 0.0001;
        const t1 = Math.max(0, t - delta);
        const t2 = Math.min(1, t + delta);
        const pt1 = this.getPoint(t1, instantiate<V>());
        this.getPoint(t2, target);
        target.sub(pt1);
        target.normalize();
        return target;
    }

    getTangentAt(u: f64, target: V): V {
        return this.getTangent(this.getUtoTmapping(u), target);
    }

    /// How finely CurvePath.getPoints samples this curve.
    pointResolution(divisions: i32): i32 {
        return divisions;
    }
}

/// Parallel-transport frames along a 3D curve (three.js's
/// Curve.computeFrenetFrames), for TubeGeometry and path extrusion.
export function computeFrenetFrames(curve: Curve<Vector3>, segments: i32, closed: bool): FrenetFrames {
    const frames = new FrenetFrames();
    const tangents = frames.tangents, normals = frames.normals, binormals = frames.binormals;
    const vec = new Vector3();
    const mat = new Matrix4();
    for (let i = 0; i <= segments; i++) tangents.push(curve.getTangentAt(<f64>i / <f64>segments, new Vector3()));
    normals.push(new Vector3());
    binormals.push(new Vector3());
    let min = Infinity;
    const tx = Math.abs(tangents[0].x), ty = Math.abs(tangents[0].y), tz = Math.abs(tangents[0].z);
    const normal = new Vector3();
    if (tx <= min) { min = tx; normal.set(1, 0, 0); }
    if (ty <= min) { min = ty; normal.set(0, 1, 0); }
    if (tz <= min) normal.set(0, 0, 1);
    vec.crossVectors(tangents[0], normal).normalize();
    normals[0].crossVectors(tangents[0], vec);
    binormals[0].crossVectors(tangents[0], normals[0]);
    for (let i = 1; i <= segments; i++) {
        normals.push(normals[i - 1].clone());
        binormals.push(binormals[i - 1].clone());
        vec.crossVectors(tangents[i - 1], tangents[i]);
        if (vec.length() > 2.220446049250313e-16) {
            vec.normalize();
            const theta = Math.acos(Math.max(-1, Math.min(1, tangents[i - 1].dot(tangents[i]))));
            normals[i].applyMatrix4(mat.makeRotationAxis(vec, theta));
        }
        binormals[i].crossVectors(tangents[i], normals[i]);
    }
    if (closed) {
        let theta = Math.acos(Math.max(-1, Math.min(1, normals[0].dot(normals[segments]))));
        theta /= <f64>segments;
        if (tangents[0].dot(vec.crossVectors(normals[0], normals[segments])) > 0) theta = -theta;
        for (let i = 1; i <= segments; i++) {
            normals[i].applyMatrix4(mat.makeRotationAxis(tangents[i], theta * <f64>i));
            binormals[i].crossVectors(tangents[i], normals[i]);
        }
    }
    return frames;
}
