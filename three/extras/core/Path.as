// three.js Path: a 2D CurvePath drawn with canvas-like commands.

import { CurvePath } from "./CurvePath";
import { Curve } from "./Curve";
import {
    LineCurve, QuadraticBezierCurve, CubicBezierCurve, EllipseCurve, SplineCurve, createCurve2,
} from "../curves/Curves";
import { Dynamic } from "rive/dynamic";
import { jnumbers } from "../../core/JSON";
import { Vector2 } from "../../math/Vector2";

export class Path extends CurvePath<Vector2> {
    currentPoint: Vector2 = new Vector2();

    constructor(points: Array<Vector2> = []) {
        super();
        this.type = "Path";
        if (points.length > 0) this.setFromPoints(points);
    }

    override toJSON(): Dynamic {
        const data = super.toJSON();
        data.set("currentPoint", Dynamic.fromNumbers(this.currentPoint.toArray()));
        return data;
    }

    override fromJSON(json: Dynamic?): Curve<Vector2> {
        super.fromJSON(json);
        const p = jnumbers(json, "currentPoint");
        if (p != null && p.length >= 2) this.currentPoint.set(p[0], p[1]);
        return this;
    }

    protected override createCurve(type: string): Curve<Vector2>? { return createCurve2(type); }

    setFromPoints(points: Array<Vector2>): Path {
        this.moveTo(points[0].x, points[0].y);
        for (let i = 1; i < points.length; i++) this.lineTo(points[i].x, points[i].y);
        return this;
    }

    moveTo(x: f64, y: f64): Path {
        this.currentPoint.set(x, y);
        return this;
    }

    lineTo(x: f64, y: f64): Path {
        this.curves.push(new LineCurve(this.currentPoint.clone(), new Vector2(x, y)));
        this.currentPoint.set(x, y);
        return this;
    }

    quadraticCurveTo(aCPx: f64, aCPy: f64, aX: f64, aY: f64): Path {
        this.curves.push(new QuadraticBezierCurve(this.currentPoint.clone(), new Vector2(aCPx, aCPy), new Vector2(aX, aY)));
        this.currentPoint.set(aX, aY);
        return this;
    }

    bezierCurveTo(aCP1x: f64, aCP1y: f64, aCP2x: f64, aCP2y: f64, aX: f64, aY: f64): Path {
        this.curves.push(new CubicBezierCurve(this.currentPoint.clone(), new Vector2(aCP1x, aCP1y),
            new Vector2(aCP2x, aCP2y), new Vector2(aX, aY)));
        this.currentPoint.set(aX, aY);
        return this;
    }

    splineThru(pts: Array<Vector2>): Path {
        const npts: Array<Vector2> = [this.currentPoint.clone()];
        for (let i = 0; i < pts.length; i++) npts.push(pts[i]);
        this.curves.push(new SplineCurve(npts));
        this.currentPoint.copy(pts[pts.length - 1]);
        return this;
    }

    arc(aX: f64, aY: f64, aRadius: f64, aStartAngle: f64, aEndAngle: f64, aClockwise: bool = false): Path {
        const x0 = this.currentPoint.x, y0 = this.currentPoint.y;
        return this.absarc(aX + x0, aY + y0, aRadius, aStartAngle, aEndAngle, aClockwise);
    }

    absarc(aX: f64, aY: f64, aRadius: f64, aStartAngle: f64, aEndAngle: f64, aClockwise: bool = false): Path {
        return this.absellipse(aX, aY, aRadius, aRadius, aStartAngle, aEndAngle, aClockwise, 0);
    }

    ellipse(aX: f64, aY: f64, xRadius: f64, yRadius: f64, aStartAngle: f64, aEndAngle: f64,
            aClockwise: bool = false, aRotation: f64 = 0): Path {
        const x0 = this.currentPoint.x, y0 = this.currentPoint.y;
        return this.absellipse(aX + x0, aY + y0, xRadius, yRadius, aStartAngle, aEndAngle, aClockwise, aRotation);
    }

    absellipse(aX: f64, aY: f64, xRadius: f64, yRadius: f64, aStartAngle: f64, aEndAngle: f64,
               aClockwise: bool = false, aRotation: f64 = 0): Path {
        const curve = new EllipseCurve(aX, aY, xRadius, yRadius, aStartAngle, aEndAngle, aClockwise, aRotation);
        if (this.curves.length > 0) {
            const first = curve.getPoint(0);
            if (!first.equals(this.currentPoint)) this.lineTo(first.x, first.y);
        }
        this.curves.push(curve);
        this.currentPoint.copy(curve.getPoint(1));
        return this;
    }

    /// Joins the end back to the start with a line.
    closePath(): Path {
        if (this.curves.length == 0) return this;
        const start = this.curves[0].getPoint(0, new Vector2());
        const end = this.curves[this.curves.length - 1].getPoint(1, new Vector2());
        if (!start.equals(end)) this.curves.push(new LineCurve(end, start));
        return this;
    }
}
