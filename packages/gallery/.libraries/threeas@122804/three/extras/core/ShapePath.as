// three.js ShapePath: sub-paths drawn with canvas-like commands, turned
// into Shapes with holes by winding (toShapes).

import { Path } from "./Path";
import { Shape } from "./Shape";
import { Vector2 } from "../../math/Vector2";
import { Color } from "../../math/Color";
import { ShapeUtils } from "../ShapeUtils";

const EPSILON: f64 = 2.220446049250313e-16;

class SolidEntry {
    s: Shape;
    p: Array<Vector2>;

    constructor(s: Shape, p: Array<Vector2>) {
        this.s = s;
        this.p = p;
    }
}

class HoleEntry {
    h: Path;
    p: Vector2;

    constructor(h: Path, p: Vector2) {
        this.h = h;
        this.p = p;
    }
}

export class ShapePath {
    readonly type: string = "ShapePath";
    color: Color = new Color();
    subPaths: Array<Path> = [];
    currentPath: Path? = null;

    moveTo(x: f64, y: f64): ShapePath {
        const path = new Path();
        this.currentPath = path;
        this.subPaths.push(path);
        path.moveTo(x, y);
        return this;
    }

    lineTo(x: f64, y: f64): ShapePath {
        this.path().lineTo(x, y);
        return this;
    }

    quadraticCurveTo(aCPx: f64, aCPy: f64, aX: f64, aY: f64): ShapePath {
        this.path().quadraticCurveTo(aCPx, aCPy, aX, aY);
        return this;
    }

    bezierCurveTo(aCP1x: f64, aCP1y: f64, aCP2x: f64, aCP2y: f64, aX: f64, aY: f64): ShapePath {
        this.path().bezierCurveTo(aCP1x, aCP1y, aCP2x, aCP2y, aX, aY);
        return this;
    }

    splineThru(pts: Array<Vector2>): ShapePath {
        this.path().splineThru(pts);
        return this;
    }

    private path(): Path {
        let p = this.currentPath;
        if (p == null) {
            p = new Path();
            this.currentPath = p;
            this.subPaths.push(p);
        }
        return p;
    }

    /// The sub-paths as shapes: clockwise ones are solids and the others
    /// holes (the reverse with isCCW), each hole given to the solid it is in.
    toShapes(isCCW: bool = false): Array<Shape> {
        const subPaths = this.subPaths;
        const shapes: Array<Shape> = [];
        if (subPaths.length == 0) return shapes;
        if (subPaths.length == 1) {
            const s = new Shape();
            s.curves = subPaths[0].curves;
            shapes.push(s);
            return shapes;
        }
        let holesFirst = !ShapeUtils.isClockWise(subPaths[0].getPoints());
        holesFirst = isCCW ? !holesFirst : holesFirst;
        const newShapes: Array<SolidEntry?> = [null];
        let newShapeHoles: Array<Array<HoleEntry>> = [[]];
        let mainIdx = 0;
        for (let i = 0; i < subPaths.length; i++) {
            const tmpPath = subPaths[i];
            const tmpPoints = tmpPath.getPoints();
            let solid = ShapeUtils.isClockWise(tmpPoints);
            solid = isCCW ? !solid : solid;
            if (solid) {
                if (!holesFirst && newShapes[mainIdx] != null) mainIdx++;
                const s = new Shape();
                s.curves = tmpPath.curves;
                setAt<SolidEntry?>(newShapes, mainIdx, new SolidEntry(s, tmpPoints), null);
                if (holesFirst) mainIdx++;
                setAt<Array<HoleEntry>>(newShapeHoles, mainIdx, [], []);
            } else {
                while (newShapeHoles.length <= mainIdx) newShapeHoles.push([]);
                newShapeHoles[mainIdx].push(new HoleEntry(tmpPath, tmpPoints[0]));
            }
        }
        if (newShapes[0] == null) {
            for (let i = 0; i < subPaths.length; i++) {
                const s = new Shape();
                s.curves = subPaths[i].curves;
                shapes.push(s);
            }
            return shapes;
        }
        if (newShapes.length > 1) {
            let ambiguous = false;
            let toChange = 0;
            const better: Array<Array<HoleEntry>> = [];
            for (let s = 0; s < newShapes.length; s++) better.push([]);
            for (let s = 0; s < newShapes.length; s++) {
                if (s >= newShapeHoles.length) continue;
                const sho = newShapeHoles[s];
                for (let h = 0; h < sho.length; h++) {
                    const ho = sho[h];
                    let unassigned = true;
                    for (let s2 = 0; s2 < newShapes.length; s2++) {
                        const entry = newShapes[s2];
                        if (entry != null && isPointInsidePolygon(ho.p, entry.p)) {
                            if (s != s2) toChange++;
                            if (unassigned) {
                                unassigned = false;
                                better[s2].push(ho);
                            } else {
                                ambiguous = true;
                            }
                        }
                    }
                    if (unassigned) better[s].push(ho);
                }
            }
            if (toChange > 0 && !ambiguous) newShapeHoles = better;
        }
        for (let i = 0; i < newShapes.length; i++) {
            const entry = newShapes[i];
            if (entry == null) continue;
            shapes.push(entry.s);
            if (i < newShapeHoles.length) {
                const holes = newShapeHoles[i];
                for (let j = 0; j < holes.length; j++) entry.s.holes.push(holes[j].h);
            }
        }
        return shapes;
    }
}

function setAt<T>(array: Array<T>, index: i32, value: T, fill: T): void {
    while (array.length <= index) array.push(fill);
    array[index] = value;
}

function isPointInsidePolygon(inPt: Vector2, inPolygon: Array<Vector2>): bool {
    const polyLen = inPolygon.length;
    let inside = false;
    for (let p = polyLen - 1, q = 0; q < polyLen; p = q++) {
        let edgeLowPt = inPolygon[p];
        let edgeHighPt = inPolygon[q];
        let edgeDx = edgeHighPt.x - edgeLowPt.x;
        let edgeDy = edgeHighPt.y - edgeLowPt.y;
        if (Math.abs(edgeDy) > EPSILON) {
            if (edgeDy < 0) {
                edgeLowPt = inPolygon[q]; edgeDx = -edgeDx;
                edgeHighPt = inPolygon[p]; edgeDy = -edgeDy;
            }
            if (inPt.y < edgeLowPt.y || inPt.y > edgeHighPt.y) continue;
            if (inPt.y == edgeLowPt.y) {
                if (inPt.x == edgeLowPt.x) return true;
            } else {
                const perpEdge = edgeDy * (inPt.x - edgeLowPt.x) - edgeDx * (inPt.y - edgeLowPt.y);
                if (perpEdge == 0) return true;
                if (perpEdge < 0) continue;
                inside = !inside;
            }
        } else {
            if (inPt.y != edgeLowPt.y) continue;
            if ((edgeHighPt.x <= inPt.x && inPt.x <= edgeLowPt.x) || (edgeLowPt.x <= inPt.x && inPt.x <= edgeHighPt.x)) {
                return true;
            }
        }
    }
    return inside;
}
