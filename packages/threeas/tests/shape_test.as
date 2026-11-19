// Curves, shapes, triangulation and extrusion: rive . --test

import { Expect, Tests } from "rive/test";
import { Path as RivePath } from "rive/path";
import { Vector } from "rive/vector";
import { Vector2 } from "../three/math/Vector2";
import { Vector3 } from "../three/math/Vector3";
import { BufferGeometry } from "../three/core/BufferGeometry";
import { Earcut } from "../three/extras/Earcut";
import { ShapeUtils } from "../three/extras/ShapeUtils";
import { Path } from "../three/extras/core/Path";
import { Shape } from "../three/extras/core/Shape";
import { ShapePath } from "../three/extras/core/ShapePath";
import { CatmullRomCurve3, EllipseCurve, LineCurve3, CubicBezierCurve3 } from "../three/extras/curves/Curves";
import { ShapeGeometry } from "../three/geometries/ShapeGeometry";
import { ExtrudeGeometry, ExtrudeGeometryOptions } from "../three/geometries/ExtrudeGeometry";
import { TubeGeometry } from "../three/geometries/TubeGeometry";
import { shapesFromRivePath } from "../three/rive/RivePaths";

const EPS: f64 = 1e-4;

@editTime
function near(expect: Expect, actual: f64, want: f64): void {
    expect.that(Math.abs(actual - want)).lessThan(EPS);
}

/// Total area of the triangles of a flat (indexed or soup) geometry.
@editTime
function triangleArea(g: BufferGeometry): f64 {
    const p = g.getAttribute("position")!;
    const index = g.index;
    const n = index != null ? index.count : p.count;
    const a = new Vector3(), b = new Vector3(), c = new Vector3();
    let sum: f64 = 0;
    for (let t = 0; t + 2 < n; t += 3) {
        const i0 = index != null ? index.getX(t) : t, i1 = index != null ? index.getX(t + 1) : t + 1;
        const i2 = index != null ? index.getX(t + 2) : t + 2;
        a.set(p.getX(i0), p.getY(i0), p.getZ(i0));
        b.set(p.getX(i1), p.getY(i1), p.getZ(i1));
        c.set(p.getX(i2), p.getY(i2), p.getZ(i2));
        sum += b.clone().sub(a).cross(c.clone().sub(a)).length() / 2;
    }
    return sum;
}

/// Triangles of a convex solid around `center` whose CCW normal points in.
@editTime
function inwardFaces(g: BufferGeometry, center: Vector3): i32 {
    const p = g.getAttribute("position")!;
    const a = new Vector3(), b = new Vector3(), c = new Vector3(), n = new Vector3(), m = new Vector3();
    let bad = 0;
    for (let t = 0; t + 2 < p.count; t += 3) {
        a.set(p.getX(t), p.getY(t), p.getZ(t));
        b.set(p.getX(t + 1), p.getY(t + 1), p.getZ(t + 1));
        c.set(p.getX(t + 2), p.getY(t + 2), p.getZ(t + 2));
        n.subVectors(c, b).cross(a.clone().sub(b));
        if (n.lengthSq() < 1e-12) continue;
        m.copy(a).add(b).add(c).divideScalar(3).sub(center);
        if (n.dot(m) <= 0) bad++;
    }
    return bad;
}

@editTime
function square(x0: f64, y0: f64, x1: f64, y1: f64, clockwise: bool): Array<Vector2> {
    // y up: clockwise is left-top-right-bottom order going around.
    if (clockwise) return [new Vector2(x0, y0), new Vector2(x0, y1), new Vector2(x1, y1), new Vector2(x1, y0)];
    return [new Vector2(x0, y0), new Vector2(x1, y0), new Vector2(x1, y1), new Vector2(x0, y1)];
}

export class ShapeTests extends Tests {
    override run(): void {
        group("Earcut and ShapeUtils", () => {
            test("a square is two triangles", (expect) => {
                expect.that(<f64>Earcut.triangulate([0, 0, 1, 0, 1, 1, 0, 1]).length).is(6);
            });
            test("a square with a hole covers the right area", (expect) => {
                const faces = ShapeUtils.triangulateShape(square(0, 0, 10, 10, true), [square(2, 2, 8, 8, false)]);
                const pts = square(0, 0, 10, 10, true).concat(square(2, 2, 8, 8, false));
                let area: f64 = 0;
                for (let i = 0; i < faces.length; i++) {
                    const f = faces[i];
                    area += Math.abs(ShapeUtils.area([pts[f[0]], pts[f[1]], pts[f[2]]]));
                }
                near(expect, area, 100 - 36);
                expect.that(<f64>faces.length).is(8);
            });
            test("winding", (expect) => {
                expect.that(ShapeUtils.isClockWise(square(0, 0, 1, 1, true))).is(true);
                expect.that(ShapeUtils.isClockWise(square(0, 0, 1, 1, false))).is(false);
                near(expect, ShapeUtils.area(square(0, 0, 2, 3, false)), 6);
            });
            test("a concave polygon (a C) covers its area", (expect) => {
                const c = [0.0, 0, 3, 0, 3, 1, 1, 1, 1, 2, 3, 2, 3, 3, 0, 3];
                const t = Earcut.triangulate(c);
                let area: f64 = 0;
                for (let i = 0; i < t.length; i += 3) {
                    const a = new Vector2(c[t[i] * 2], c[t[i] * 2 + 1]);
                    const b = new Vector2(c[t[i + 1] * 2], c[t[i + 1] * 2 + 1]);
                    const d = new Vector2(c[t[i + 2] * 2], c[t[i + 2] * 2 + 1]);
                    area += Math.abs(ShapeUtils.area([a, b, d]));
                }
                near(expect, area, 9 - 2);
            });
        });

        group("Curves", () => {
            test("Catmull-Rom passes through its points", (expect) => {
                const curve = new CatmullRomCurve3([new Vector3(0, 0, 0), new Vector3(1, 1, 0), new Vector3(2, 0, 0), new Vector3(3, 1, 1)]);
                const start = curve.getPoint(0), end = curve.getPoint(1);
                near(expect, start.distanceTo(new Vector3(0, 0, 0)), 0);
                near(expect, end.distanceTo(new Vector3(3, 1, 1)), 0);
                expect.that(curve.getLength()).greaterThan(3);
            });
            test("spaced points are evenly spaced", (expect) => {
                const curve = new CubicBezierCurve3(new Vector3(0, 0, 0), new Vector3(0, 3, 0), new Vector3(3, 3, 0), new Vector3(3, 0, 0));
                const pts = curve.getSpacedPoints(10);
                const d0 = pts[0].distanceTo(pts[1]);
                for (let i = 1; i < 10; i++) expect.that(Math.abs(pts[i].distanceTo(pts[i + 1]) - d0)).lessThan(0.02);
            });
            test("line length and tangent", (expect) => {
                const line = new LineCurve3(new Vector3(0, 0, 0), new Vector3(0, 3, 4));
                near(expect, line.getLength(), 5);
                const t = line.getTangent(0.5);
                near(expect, t.y, 0.6);
            });
            test("a path with an arc", (expect) => {
                const path = new Path();
                path.moveTo(0, 0);
                path.lineTo(1, 0);
                path.absarc(1, 1, 1, -Math.PI / 2, 0, false);
                const pts = path.getPoints(4);
                near(expect, pts[pts.length - 1].x, 2);
                near(expect, pts[pts.length - 1].y, 1);
                near(expect, path.getLength(), 1 + Math.PI / 2);
                const e = new EllipseCurve(0, 0, 2, 1);
                near(expect, e.getPoint(0.25).y, 1);
            });
        });

        group("Shapes", () => {
            test("ShapePath.toShapes finds the hole", (expect) => {
                const sp = new ShapePath();
                const outer = square(0, 0, 10, 10, true), inner = square(2, 2, 8, 8, false);
                sp.moveTo(outer[0].x, outer[0].y);
                for (let i = 1; i < 4; i++) sp.lineTo(outer[i].x, outer[i].y);
                sp.moveTo(inner[0].x, inner[0].y);
                for (let i = 1; i < 4; i++) sp.lineTo(inner[i].x, inner[i].y);
                const shapes = sp.toShapes();
                expect.that(<f64>shapes.length).is(1);
                expect.that(<f64>shapes[0].holes.length).is(1);
            });
            test("ShapeGeometry covers the shape's area", (expect) => {
                const shape = new Shape(square(0, 0, 10, 10, false));
                shape.holes.push(new Path(square(2, 2, 8, 8, true)));
                near(expect, triangleArea(new ShapeGeometry([shape])), 64);
            });
            test("ExtrudeGeometry: counts and outward faces", (expect) => {
                const shape = new Shape(square(-1, -1, 1, 1, false));
                const flat = new ExtrudeGeometryOptions();
                flat.bevelEnabled = false;
                flat.depth = 2;
                const g = new ExtrudeGeometry([shape], flat);
                expect.that(<f64>g.getAttribute("position")!.count).is(36);
                expect.that(<f64>inwardFaces(g, new Vector3(0, 0, 1))).is(0);
                expect.that(<f64>g.groups.length).is(2);
                const bevelled = new ExtrudeGeometry([shape]);
                expect.that(<f64>bevelled.getAttribute("position")!.count).is(180);
                expect.that(<f64>inwardFaces(bevelled, new Vector3(0, 0, 0.5))).is(0);
            });
            test("ExtrudeGeometry along a path", (expect) => {
                const o = new ExtrudeGeometryOptions();
                o.steps = 8;
                o.extrudePath = new LineCurve3(new Vector3(0, 0, 0), new Vector3(0, 0, 5));
                const g = new ExtrudeGeometry([new Shape(square(-1, -1, 1, 1, false))], o);
                g.computeBoundingBox();
                near(expect, g.boundingBox!.max.z - g.boundingBox!.min.z, 5);
            });
            test("TubeGeometry counts", (expect) => {
                const g = new TubeGeometry(new LineCurve3(new Vector3(0, 0, 0), new Vector3(0, 0, 4)), 8, 0.5, 6);
                expect.that(<f64>g.getAttribute("position")!.count).is(9 * 7);
                expect.that(<f64>g.index!.count).is(8 * 6 * 6);
            });
            test("a Rive path becomes a shape (y flipped)", (expect) => {
                const rp = new RivePath();
                rp.moveTo(Vector.xy(0, 0));
                rp.lineTo(Vector.xy(10, 0));
                rp.lineTo(Vector.xy(10, 10));
                rp.lineTo(Vector.xy(0, 10));
                rp.close();
                const shapes = shapesFromRivePath(rp, 0.1, true);
                expect.that(<f64>shapes.length).is(1);
                near(expect, Math.abs(ShapeUtils.area(shapes[0].getPoints())), 1);
                near(expect, shapes[0].getPoints()[2].y, -1);
            });
        });
    }
}
