// three.js's NURBSCurve addon: a NURBS curve through Vector4 control points
// (x, y, z, w = weight), a Curve<Vector3>. `startKnot` / `endKnot` (knot
// indices) trim the hidden spans of periodic curves.

import { Curve } from "../../extras/core/Curve";
import { Vector3 } from "../../math/Vector3";
import { Vector4 } from "../../math/Vector4";
import { calcBSplinePoint, calcNURBSDerivatives } from "./NURBSUtils";

export class NURBSCurve extends Curve<Vector3> {
    degree: i32;
    knots: Array<f64>;
    controlPoints: Array<Vector4> = [];
    startKnot: i32;
    endKnot: i32;

    /// `startKnot` 0 and `endKnot` -1 (or 0) span the whole knot vector, as
    /// three.js's undefined.
    constructor(degree: i32, knots: Array<f64>, controlPoints: Array<Vector4>, startKnot: i32 = 0, endKnot: i32 = -1) {
        super();
        this.type = "NURBSCurve";
        const knotsLength = knots.length > 0 ? knots.length - 1 : 0;
        this.degree = degree;
        this.knots = knots;
        this.startKnot = startKnot > 0 ? startKnot : 0;
        this.endKnot = endKnot > 0 ? endKnot : knotsLength;
        for (let i = 0; i < controlPoints.length; ++i) {
            const point = controlPoints[i];
            this.controlPoints.push(new Vector4(point.x, point.y, point.z, point.w));
        }
    }

    override getPoint(t: f64, target: Vector3 = new Vector3()): Vector3 {
        const knots = this.knots;
        const u = knots[this.startKnot] + t * (knots[this.endKnot] - knots[this.startKnot]);   // t -> u
        const hpoint = calcBSplinePoint(this.degree, knots, this.controlPoints, u);
        if (hpoint.w != 1.0) hpoint.divideScalar(hpoint.w);   // (wx, wy, wz, w) -> (x, y, z, 1)
        return target.set(hpoint.x, hpoint.y, hpoint.z);
    }

    override getTangent(t: f64, target: Vector3 = new Vector3()): Vector3 {
        const knots = this.knots;
        const u = knots[0] + t * (knots[knots.length - 1] - knots[0]);
        const ders = calcNURBSDerivatives(this.degree, knots, this.controlPoints, u, 1);
        target.copy(ders[1]).normalize();
        return target;
    }
}
