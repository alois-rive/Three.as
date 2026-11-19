// three.js examples/jsm/lines/LineGeometry.js: a polyline (a strip of
// points) as wide line segments.

import { LineSegmentsGeometry } from "./LineSegmentsGeometry";
import { Vector3 } from "../../math/Vector3";
import { Line } from "../../objects/Line";

export class LineGeometry extends LineSegmentsGeometry {
    readonly isLineGeometry: bool = true;

    constructor() {
        super();
        this.type = "LineGeometry";
    }

    /// Points along the line, three numbers each.
    override setPositions(array: Array<f64>): LineSegmentsGeometry {
        return super.setPositions(stripToSegments(array));
    }

    /// Colours at the points, three numbers each.
    override setColors(array: Array<f64>): LineSegmentsGeometry {
        return super.setColors(stripToSegments(array));
    }

    setFromPoints(points: Array<Vector3>): LineGeometry {
        const a: Array<f64> = [];
        for (let i = 0; i < points.length; i++) { a.push(points[i].x); a.push(points[i].y); a.push(points[i].z); }
        this.setPositions(a);
        return this;
    }

    fromLine(line: Line): LineGeometry {
        const p = line.geometry.getAttribute("position");
        const a: Array<f64> = [];
        if (p != null) for (let i = 0; i < p.array.length; i++) a.push(<f64>p.array[i]);
        this.setPositions(a);
        return this;
    }
}

function stripToSegments(array: Array<f64>): Array<f64> {
    const out: Array<f64> = [];
    const n = array.length / 3;
    for (let i = 0; i + 1 < n; i++) {
        for (let k = 0; k < 3; k++) out.push(array[i * 3 + k]);
        for (let k = 0; k < 3; k++) out.push(array[(i + 1) * 3 + k]);
    }
    return out;
}
