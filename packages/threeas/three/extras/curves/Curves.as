// three.js's curve classes: 2D (LineCurve, QuadraticBezierCurve,
// CubicBezierCurve, EllipseCurve, ArcCurve, SplineCurve) and 3D
// (LineCurve3, QuadraticBezierCurve3, CubicBezierCurve3, CatmullRomCurve3).

import { Curve } from "../core/Curve";
import { CatmullRom, QuadraticBezier, CubicBezier } from "../core/Interpolations";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Dynamic } from "rive/dynamic";
import { setNumber, setNumbers, setBool, jnum, jbool, jstr, jarr, jnumbers, asNumbers } from "../../core/JSON";

const EPSILON: f64 = 2.220446049250313e-16;

/// A new 2D curve of three.js's class `type` (for CurvePath.fromJSON), or
/// null for a type that is not a 2D curve.
export function createCurve2(type: string): Curve<Vector2>? {
    if (type == "LineCurve") return new LineCurve();
    if (type == "QuadraticBezierCurve") return new QuadraticBezierCurve();
    if (type == "CubicBezierCurve") return new CubicBezierCurve();
    if (type == "EllipseCurve") return new EllipseCurve();
    if (type == "ArcCurve") return new ArcCurve();
    if (type == "SplineCurve") return new SplineCurve();
    return null;
}

/// A new 3D curve of three.js's class `type`, or null.
export function createCurve3(type: string): Curve<Vector3>? {
    if (type == "LineCurve3") return new LineCurve3();
    if (type == "QuadraticBezierCurve3") return new QuadraticBezierCurve3();
    if (type == "CubicBezierCurve3") return new CubicBezierCurve3();
    if (type == "CatmullRomCurve3") return new CatmullRomCurve3();
    return null;
}

function readVector2(v: Vector2, json: Dynamic?, key: string): void {
    const a = jnumbers(json, key);
    if (a != null && a.length >= 2) v.set(a[0], a[1]);
}

function readVector3(v: Vector3, json: Dynamic?, key: string): void {
    const a = jnumbers(json, key);
    if (a != null && a.length >= 3) v.set(a[0], a[1], a[2]);
}

export class LineCurve extends Curve<Vector2> {
    readonly isLineCurve: bool = true;

    override toJSON(): Dynamic {
        const data = super.toJSON();
        setNumbers(data, "v1", this.v1.toArray());
        setNumbers(data, "v2", this.v2.toArray());
        return data;
    }

    override fromJSON(json: Dynamic?): Curve<Vector2> {
        super.fromJSON(json);
        readVector2(this.v1, json, "v1");
        readVector2(this.v2, json, "v2");
        return this;
    }
    v1: Vector2;
    v2: Vector2;

    constructor(v1: Vector2 = new Vector2(), v2: Vector2 = new Vector2()) {
        super();
        this.type = "LineCurve";
        this.v1 = v1;
        this.v2 = v2;
    }

    override getPoint(t: f64, target: Vector2 = new Vector2()): Vector2 {
        if (t == 1) return target.copy(this.v2);
        return target.copy(this.v2).sub(this.v1).multiplyScalar(t).add(this.v1);
    }

    override getPointAt(u: f64, target: Vector2 = new Vector2()): Vector2 { return this.getPoint(u, target); }

    override getTangent(t: f64, target: Vector2 = new Vector2()): Vector2 {
        return target.subVectors(this.v2, this.v1).normalize();
    }

    override pointResolution(divisions: i32): i32 { return 1; }
}

export class LineCurve3 extends Curve<Vector3> {
    readonly isLineCurve3: bool = true;

    override toJSON(): Dynamic {
        const data = super.toJSON();
        setNumbers(data, "v1", this.v1.toArray());
        setNumbers(data, "v2", this.v2.toArray());
        return data;
    }

    override fromJSON(json: Dynamic?): Curve<Vector3> {
        super.fromJSON(json);
        readVector3(this.v1, json, "v1");
        readVector3(this.v2, json, "v2");
        return this;
    }
    v1: Vector3;
    v2: Vector3;

    constructor(v1: Vector3 = new Vector3(), v2: Vector3 = new Vector3()) {
        super();
        this.type = "LineCurve3";
        this.v1 = v1;
        this.v2 = v2;
    }

    override getPoint(t: f64, target: Vector3 = new Vector3()): Vector3 {
        if (t == 1) return target.copy(this.v2);
        return target.copy(this.v2).sub(this.v1).multiplyScalar(t).add(this.v1);
    }

    override getPointAt(u: f64, target: Vector3 = new Vector3()): Vector3 { return this.getPoint(u, target); }

    override getTangent(t: f64, target: Vector3 = new Vector3()): Vector3 {
        return target.subVectors(this.v2, this.v1).normalize();
    }

    override pointResolution(divisions: i32): i32 { return 1; }
}

export class QuadraticBezierCurve extends Curve<Vector2> {
    override toJSON(): Dynamic {
        const data = super.toJSON();
        setNumbers(data, "v0", this.v0.toArray());
        setNumbers(data, "v1", this.v1.toArray());
        setNumbers(data, "v2", this.v2.toArray());
        return data;
    }

    override fromJSON(json: Dynamic?): Curve<Vector2> {
        super.fromJSON(json);
        readVector2(this.v0, json, "v0");
        readVector2(this.v1, json, "v1");
        readVector2(this.v2, json, "v2");
        return this;
    }

    v0: Vector2;
    v1: Vector2;
    v2: Vector2;

    constructor(v0: Vector2 = new Vector2(), v1: Vector2 = new Vector2(), v2: Vector2 = new Vector2()) {
        super();
        this.type = "QuadraticBezierCurve";
        this.v0 = v0; this.v1 = v1; this.v2 = v2;
    }

    override getPoint(t: f64, target: Vector2 = new Vector2()): Vector2 {
        return target.set(
            QuadraticBezier(t, this.v0.x, this.v1.x, this.v2.x),
            QuadraticBezier(t, this.v0.y, this.v1.y, this.v2.y));
    }
}

export class QuadraticBezierCurve3 extends Curve<Vector3> {
    override toJSON(): Dynamic {
        const data = super.toJSON();
        setNumbers(data, "v0", this.v0.toArray());
        setNumbers(data, "v1", this.v1.toArray());
        setNumbers(data, "v2", this.v2.toArray());
        return data;
    }

    override fromJSON(json: Dynamic?): Curve<Vector3> {
        super.fromJSON(json);
        readVector3(this.v0, json, "v0");
        readVector3(this.v1, json, "v1");
        readVector3(this.v2, json, "v2");
        return this;
    }

    v0: Vector3;
    v1: Vector3;
    v2: Vector3;

    constructor(v0: Vector3 = new Vector3(), v1: Vector3 = new Vector3(), v2: Vector3 = new Vector3()) {
        super();
        this.type = "QuadraticBezierCurve3";
        this.v0 = v0; this.v1 = v1; this.v2 = v2;
    }

    override getPoint(t: f64, target: Vector3 = new Vector3()): Vector3 {
        return target.set(
            QuadraticBezier(t, this.v0.x, this.v1.x, this.v2.x),
            QuadraticBezier(t, this.v0.y, this.v1.y, this.v2.y),
            QuadraticBezier(t, this.v0.z, this.v1.z, this.v2.z));
    }
}

export class CubicBezierCurve extends Curve<Vector2> {
    override toJSON(): Dynamic {
        const data = super.toJSON();
        setNumbers(data, "v0", this.v0.toArray());
        setNumbers(data, "v1", this.v1.toArray());
        setNumbers(data, "v2", this.v2.toArray());
        setNumbers(data, "v3", this.v3.toArray());
        return data;
    }

    override fromJSON(json: Dynamic?): Curve<Vector2> {
        super.fromJSON(json);
        readVector2(this.v0, json, "v0");
        readVector2(this.v1, json, "v1");
        readVector2(this.v2, json, "v2");
        readVector2(this.v3, json, "v3");
        return this;
    }

    v0: Vector2;
    v1: Vector2;
    v2: Vector2;
    v3: Vector2;

    constructor(v0: Vector2 = new Vector2(), v1: Vector2 = new Vector2(), v2: Vector2 = new Vector2(),
                v3: Vector2 = new Vector2()) {
        super();
        this.type = "CubicBezierCurve";
        this.v0 = v0; this.v1 = v1; this.v2 = v2; this.v3 = v3;
    }

    override getPoint(t: f64, target: Vector2 = new Vector2()): Vector2 {
        return target.set(
            CubicBezier(t, this.v0.x, this.v1.x, this.v2.x, this.v3.x),
            CubicBezier(t, this.v0.y, this.v1.y, this.v2.y, this.v3.y));
    }
}

export class CubicBezierCurve3 extends Curve<Vector3> {
    override toJSON(): Dynamic {
        const data = super.toJSON();
        setNumbers(data, "v0", this.v0.toArray());
        setNumbers(data, "v1", this.v1.toArray());
        setNumbers(data, "v2", this.v2.toArray());
        setNumbers(data, "v3", this.v3.toArray());
        return data;
    }

    override fromJSON(json: Dynamic?): Curve<Vector3> {
        super.fromJSON(json);
        readVector3(this.v0, json, "v0");
        readVector3(this.v1, json, "v1");
        readVector3(this.v2, json, "v2");
        readVector3(this.v3, json, "v3");
        return this;
    }

    v0: Vector3;
    v1: Vector3;
    v2: Vector3;
    v3: Vector3;

    constructor(v0: Vector3 = new Vector3(), v1: Vector3 = new Vector3(), v2: Vector3 = new Vector3(),
                v3: Vector3 = new Vector3()) {
        super();
        this.type = "CubicBezierCurve3";
        this.v0 = v0; this.v1 = v1; this.v2 = v2; this.v3 = v3;
    }

    override getPoint(t: f64, target: Vector3 = new Vector3()): Vector3 {
        return target.set(
            CubicBezier(t, this.v0.x, this.v1.x, this.v2.x, this.v3.x),
            CubicBezier(t, this.v0.y, this.v1.y, this.v2.y, this.v3.y),
            CubicBezier(t, this.v0.z, this.v1.z, this.v2.z, this.v3.z));
    }
}

export class EllipseCurve extends Curve<Vector2> {
    readonly isEllipseCurve: bool = true;

    override toJSON(): Dynamic {
        const data = super.toJSON();
        setNumber(data, "aX", this.aX);
        setNumber(data, "aY", this.aY);
        setNumber(data, "xRadius", this.xRadius);
        setNumber(data, "yRadius", this.yRadius);
        setNumber(data, "aStartAngle", this.aStartAngle);
        setNumber(data, "aEndAngle", this.aEndAngle);
        setBool(data, "aClockwise", this.aClockwise);
        setNumber(data, "aRotation", this.aRotation);
        return data;
    }

    override fromJSON(json: Dynamic?): Curve<Vector2> {
        super.fromJSON(json);
        this.aX = jnum(json, "aX", this.aX);
        this.aY = jnum(json, "aY", this.aY);
        this.xRadius = jnum(json, "xRadius", this.xRadius);
        this.yRadius = jnum(json, "yRadius", this.yRadius);
        this.aStartAngle = jnum(json, "aStartAngle", this.aStartAngle);
        this.aEndAngle = jnum(json, "aEndAngle", this.aEndAngle);
        this.aClockwise = jbool(json, "aClockwise", this.aClockwise);
        this.aRotation = jnum(json, "aRotation", this.aRotation);
        return this;
    }
    aX: f64;
    aY: f64;
    xRadius: f64;
    yRadius: f64;
    aStartAngle: f64;
    aEndAngle: f64;
    aClockwise: bool;
    aRotation: f64;

    constructor(aX: f64 = 0, aY: f64 = 0, xRadius: f64 = 1, yRadius: f64 = 1, aStartAngle: f64 = 0,
                aEndAngle: f64 = Math.PI * 2, aClockwise: bool = false, aRotation: f64 = 0) {
        super();
        this.type = "EllipseCurve";
        this.aX = aX; this.aY = aY; this.xRadius = xRadius; this.yRadius = yRadius;
        this.aStartAngle = aStartAngle; this.aEndAngle = aEndAngle;
        this.aClockwise = aClockwise; this.aRotation = aRotation;
    }

    override getPoint(t: f64, target: Vector2 = new Vector2()): Vector2 {
        const twoPi = Math.PI * 2;
        let deltaAngle = this.aEndAngle - this.aStartAngle;
        const samePoints = Math.abs(deltaAngle) < EPSILON;
        while (deltaAngle < 0) deltaAngle += twoPi;
        while (deltaAngle > twoPi) deltaAngle -= twoPi;
        if (deltaAngle < EPSILON) deltaAngle = samePoints ? 0 : twoPi;
        if (this.aClockwise && !samePoints) {
            if (deltaAngle == twoPi) deltaAngle = -twoPi;
            else deltaAngle = deltaAngle - twoPi;
        }
        const angle = this.aStartAngle + t * deltaAngle;
        let x = this.aX + this.xRadius * Math.cos(angle);
        let y = this.aY + this.yRadius * Math.sin(angle);
        if (this.aRotation != 0) {
            const cos = Math.cos(this.aRotation), sin = Math.sin(this.aRotation);
            const tx = x - this.aX, ty = y - this.aY;
            x = tx * cos - ty * sin + this.aX;
            y = tx * sin + ty * cos + this.aY;
        }
        return target.set(x, y);
    }

    override pointResolution(divisions: i32): i32 { return divisions * 2; }
}

export class ArcCurve extends EllipseCurve {
    readonly isArcCurve: bool = true;

    constructor(aX: f64 = 0, aY: f64 = 0, aRadius: f64 = 1, aStartAngle: f64 = 0, aEndAngle: f64 = Math.PI * 2,
                aClockwise: bool = false) {
        super(aX, aY, aRadius, aRadius, aStartAngle, aEndAngle, aClockwise, 0);
        this.type = "ArcCurve";
    }
}

export class SplineCurve extends Curve<Vector2> {
    readonly isSplineCurve: bool = true;

    override toJSON(): Dynamic {
        const data = super.toJSON();
        const points = Dynamic.newTable();
        for (let i = 0; i < this.points.length; i++) points.push(Dynamic.fromNumbers(this.points[i].toArray()));
        data.set("points", points);
        return data;
    }

    override fromJSON(json: Dynamic?): Curve<Vector2> {
        super.fromJSON(json);
        this.points = [];
        const items = jarr(json, "points");
        for (let i = 0; i < items.length; i++) {
            const a = asNumbers(items[i]);
            if (a != null && a.length >= 2) this.points.push(new Vector2(a[0], a[1]));
        }
        return this;
    }
    points: Array<Vector2>;

    constructor(points: Array<Vector2> = []) {
        super();
        this.type = "SplineCurve";
        this.points = points;
    }

    override getPoint(t: f64, target: Vector2 = new Vector2()): Vector2 {
        const points = this.points;
        const n = points.length;
        if (n == 0) return target;
        const p = <f64>(n - 1) * t;
        const intPoint = <i32>Math.floor(p);
        const weight = p - <f64>intPoint;
        const p0 = points[intPoint == 0 ? intPoint : intPoint - 1];
        const p1 = points[min<i32>(intPoint, n - 1)];
        const p2 = points[intPoint > n - 2 ? n - 1 : intPoint + 1];
        const p3 = points[intPoint > n - 3 ? n - 1 : intPoint + 2];
        return target.set(CatmullRom(weight, p0.x, p1.x, p2.x, p3.x), CatmullRom(weight, p0.y, p1.y, p2.y, p3.y));
    }

    override pointResolution(divisions: i32): i32 { return divisions * this.points.length; }
}

class CubicPoly {
    c0: f64 = 0; c1: f64 = 0; c2: f64 = 0; c3: f64 = 0;

    init(x0: f64, x1: f64, t0: f64, t1: f64): void {
        this.c0 = x0;
        this.c1 = t0;
        this.c2 = -3 * x0 + 3 * x1 - 2 * t0 - t1;
        this.c3 = 2 * x0 - 2 * x1 + t0 + t1;
    }

    initCatmullRom(x0: f64, x1: f64, x2: f64, x3: f64, tension: f64): void {
        this.init(x1, x2, tension * (x2 - x0), tension * (x3 - x1));
    }

    initNonuniformCatmullRom(x0: f64, x1: f64, x2: f64, x3: f64, dt0: f64, dt1: f64, dt2: f64): void {
        let t1 = (x1 - x0) / dt0 - (x2 - x0) / (dt0 + dt1) + (x2 - x1) / dt1;
        let t2 = (x2 - x1) / dt1 - (x3 - x1) / (dt1 + dt2) + (x3 - x2) / dt2;
        t1 *= dt1;
        t2 *= dt1;
        this.init(x1, x2, t1, t2);
    }

    calc(t: f64): f64 {
        const t2 = t * t;
        return this.c0 + this.c1 * t + this.c2 * t2 + this.c3 * t2 * t;
    }
}

/// A smooth curve through `points` ("centripetal" by default, "chordal" or
/// "catmullrom" with `tension`).
export class CatmullRomCurve3 extends Curve<Vector3> {
    readonly isCatmullRomCurve3: bool = true;

    override toJSON(): Dynamic {
        const data = super.toJSON();
        const points = Dynamic.newTable();
        for (let i = 0; i < this.points.length; i++) points.push(Dynamic.fromNumbers(this.points[i].toArray()));
        data.set("points", points);
        setBool(data, "closed", this.closed);
        data.set("curveType", Dynamic.fromString(this.curveType));
        setNumber(data, "tension", this.tension);
        return data;
    }

    override fromJSON(json: Dynamic?): Curve<Vector3> {
        super.fromJSON(json);
        this.points = [];
        const items = jarr(json, "points");
        for (let i = 0; i < items.length; i++) {
            const a = asNumbers(items[i]);
            if (a != null && a.length >= 3) this.points.push(new Vector3(a[0], a[1], a[2]));
        }
        this.closed = jbool(json, "closed", this.closed);
        this.curveType = jstr(json, "curveType", this.curveType);
        this.tension = jnum(json, "tension", this.tension);
        return this;
    }
    points: Array<Vector3>;
    closed: bool;
    curveType: string;
    tension: f64;
    private px: CubicPoly = new CubicPoly();
    private py: CubicPoly = new CubicPoly();
    private pz: CubicPoly = new CubicPoly();
    private tmp0: Vector3 = new Vector3();
    private tmp: Vector3 = new Vector3();

    constructor(points: Array<Vector3> = [], closed: bool = false, curveType: string = "centripetal",
                tension: f64 = 0.5) {
        super();
        this.type = "CatmullRomCurve3";
        this.points = points;
        this.closed = closed;
        this.curveType = curveType;
        this.tension = tension;
    }

    override getPoint(t: f64, target: Vector3 = new Vector3()): Vector3 {
        const points = this.points;
        const l = points.length;
        if (l < 2) return l == 1 ? target.copy(points[0]) : target;
        const p = <f64>(l - (this.closed ? 0 : 1)) * t;
        let intPoint = <i32>Math.floor(p);
        let weight = p - <f64>intPoint;
        if (this.closed) {
            intPoint += intPoint > 0 ? 0 : (<i32>Math.floor(<f64>Math.abs(intPoint) / <f64>l) + 1) * l;
        } else if (weight == 0 && intPoint == l - 1) {
            intPoint = l - 2;
            weight = 1;
        }
        let p0: Vector3, p3: Vector3;
        if (this.closed || intPoint > 0) {
            p0 = points[(intPoint - 1) % l];
        } else {
            p0 = this.tmp0.subVectors(points[0], points[1]).add(points[0]);
        }
        const p1 = points[intPoint % l];
        const p2 = points[(intPoint + 1) % l];
        if (this.closed || intPoint + 2 < l) {
            p3 = points[(intPoint + 2) % l];
        } else {
            p3 = this.tmp.subVectors(points[l - 1], points[l - 2]).add(points[l - 1]);
        }
        if (this.curveType == "centripetal" || this.curveType == "chordal") {
            let dt0 = Math.sqrt(p0.distanceToSquared(p1));
            let dt1 = Math.sqrt(p1.distanceToSquared(p2));
            let dt2 = Math.sqrt(p2.distanceToSquared(p3));
            if (this.curveType == "centripetal") {
                dt0 = Math.sqrt(dt0);
                dt1 = Math.sqrt(dt1);
                dt2 = Math.sqrt(dt2);
            }
            if (dt1 < 1e-4) dt1 = 1.0;
            if (dt0 < 1e-4) dt0 = dt1;
            if (dt2 < 1e-4) dt2 = dt1;
            this.px.initNonuniformCatmullRom(p0.x, p1.x, p2.x, p3.x, dt0, dt1, dt2);
            this.py.initNonuniformCatmullRom(p0.y, p1.y, p2.y, p3.y, dt0, dt1, dt2);
            this.pz.initNonuniformCatmullRom(p0.z, p1.z, p2.z, p3.z, dt0, dt1, dt2);
        } else {
            this.px.initCatmullRom(p0.x, p1.x, p2.x, p3.x, this.tension);
            this.py.initCatmullRom(p0.y, p1.y, p2.y, p3.y, this.tension);
            this.pz.initCatmullRom(p0.z, p1.z, p2.z, p3.z, this.tension);
        }
        return target.set(this.px.calc(weight), this.py.calc(weight), this.pz.calc(weight));
    }
}
