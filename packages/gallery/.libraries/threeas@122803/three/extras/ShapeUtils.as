// three.js ShapeUtils.

import { Vector2 } from "../math/Vector2";
import { Earcut } from "./Earcut";

export class ShapeUtils {
    /// Signed area (positive counter-clockwise).
    static area(contour: Array<Vector2>): f64 {
        const n = contour.length;
        let a: f64 = 0;
        for (let p = n - 1, q = 0; q < n; p = q++) a += contour[p].x * contour[q].y - contour[q].x * contour[p].y;
        return a * 0.5;
    }

    static isClockWise(pts: Array<Vector2>): bool {
        return ShapeUtils.area(pts) < 0;
    }

    /// Triangles (index triples) of `contour` with `holes`; indices count the
    /// contour's points, then each hole's.
    static triangulateShape(contour: Array<Vector2>, holes: Array<Array<Vector2>>): Array<Array<i32>> {
        const vertices: Array<f64> = [];
        const holeIndices: Array<i32> = [];
        removeDupEndPts(contour);
        addContour(vertices, contour);
        let holeIndex = contour.length;
        for (let i = 0; i < holes.length; i++) removeDupEndPts(holes[i]);
        for (let i = 0; i < holes.length; i++) {
            holeIndices.push(holeIndex);
            holeIndex += holes[i].length;
            addContour(vertices, holes[i]);
        }
        const triangles = Earcut.triangulate(vertices, holeIndices);
        const faces: Array<Array<i32>> = [];
        for (let i = 0; i + 2 < triangles.length; i += 3) faces.push([triangles[i], triangles[i + 1], triangles[i + 2]]);
        return faces;
    }
}

function removeDupEndPts(points: Array<Vector2>): void {
    const l = points.length;
    if (l > 2 && points[l - 1].equals(points[0])) points.pop();
}

function addContour(vertices: Array<f64>, contour: Array<Vector2>): void {
    for (let i = 0; i < contour.length; i++) {
        vertices.push(contour[i].x);
        vertices.push(contour[i].y);
    }
}
