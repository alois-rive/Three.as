// three.js CurvePath: curves joined end to end, parameterized by length.

import { Curve } from "./Curve";

export class CurvePath<V> extends Curve<V> {
    curves: Array<Curve<V>> = [];
    /// Close the point list back to its start (getPoints, getSpacedPoints).
    autoClose: bool = false;
    protected cacheLengths: Array<f64> = [];

    constructor() {
        super();
        this.type = "CurvePath";
    }

    add(curve: Curve<V>): void {
        this.curves.push(curve);
    }

    override getPoint(t: f64, target: V): V {
        const d = t * this.getLength();
        const curveLengths = this.getCurveLengths();
        for (let i = 0; i < curveLengths.length; i++) {
            if (curveLengths[i] >= d) {
                const diff = curveLengths[i] - d;
                const curve = this.curves[i];
                const segmentLength = curve.getLength();
                const u = segmentLength == 0 ? 0 : 1 - diff / segmentLength;
                return curve.getPointAt(u, target);
            }
        }
        return target;
    }

    override getLength(): f64 {
        const lens = this.getCurveLengths();
        return lens.length > 0 ? lens[lens.length - 1] : 0;
    }

    override updateArcLengths(): void {
        this.needsUpdate = true;
        this.cacheLengths = [];
        this.getCurveLengths();
    }

    getCurveLengths(): Array<f64> {
        if (this.cacheLengths.length == this.curves.length && !this.needsUpdate) return this.cacheLengths;
        this.needsUpdate = false;
        const lengths: Array<f64> = [];
        let sums: f64 = 0;
        for (let i = 0; i < this.curves.length; i++) {
            sums += this.curves[i].getLength();
            lengths.push(sums);
        }
        this.cacheLengths = lengths;
        return lengths;
    }

    override getSpacedPoints(divisions: i32 = 40): Array<V> {
        const points: Array<V> = [];
        for (let i = 0; i <= divisions; i++) points.push(this.getPoint(<f64>i / <f64>divisions, instantiate<V>()));
        if (this.autoClose && points.length > 0) points.push(points[0]);
        return points;
    }

    override getPoints(divisions: i32 = 12): Array<V> {
        const points: Array<V> = [];
        let last: V? = null;
        const curves = this.curves;
        for (let i = 0; i < curves.length; i++) {
            const curve = curves[i];
            const pts = curve.getPoints(curve.pointResolution(divisions));
            for (let j = 0; j < pts.length; j++) {
                const point = pts[j];
                if (last != null && last.equals(point)) continue;
                points.push(point);
                last = point;
            }
        }
        if (this.autoClose && points.length > 1 && !points[points.length - 1].equals(points[0])) {
            points.push(points[0]);
        }
        return points;
    }
}
