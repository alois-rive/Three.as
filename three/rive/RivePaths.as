// Rive paths as three.js shapes: a Rive `Path` (drawn by a script, or read
// from a node with `NodeData.asPath()`) to a ShapePath, so Rive vector
// art extrudes or fills in 3D. Rive's y points down, three.js's up, so
// y is flipped (and scaled by `scale`). And back: rivePathFromShapePath
// makes a Rive path of a ShapePath (SVGLoader's paths, drawn by Rive).

import { Path as RivePath } from "rive/path";
import { Vector } from "rive/vector";
import { ShapePath } from "../extras/core/ShapePath";
import { Shape } from "../extras/core/Shape";
import { LineCurve, QuadraticBezierCurve, CubicBezierCurve, EllipseCurve } from "../extras/curves/Curves";
import { Vector2 } from "../math/Vector2";

/// The Rive path as a ShapePath (one sub-path per contour).
export function shapePathFromRivePath(path: RivePath, scale: f64 = 1, flipY: bool = true): ShapePath {
    const out = new ShapePath();
    const sy = flipY ? -scale : scale;
    for (let i = 0; i < path.length; i++) {
        const c = path[i];
        const type = c.type;
        if (type == "moveTo") {
            const p = c[0];
            out.moveTo(<f64>p.x * scale, <f64>p.y * sy);
        } else if (type == "lineTo") {
            const p = c[0];
            out.lineTo(<f64>p.x * scale, <f64>p.y * sy);
        } else if (type == "quadTo") {
            const a = c[0], b = c[1];
            out.quadraticCurveTo(<f64>a.x * scale, <f64>a.y * sy, <f64>b.x * scale, <f64>b.y * sy);
        } else if (type == "cubicTo") {
            const a = c[0], b = c[1], d = c[2];
            out.bezierCurveTo(<f64>a.x * scale, <f64>a.y * sy, <f64>b.x * scale, <f64>b.y * sy,
                <f64>d.x * scale, <f64>d.y * sy);
        }
        // "close": shapes are closed implicitly.
    }
    return out;
}

/// The Rive path's contours as shapes with holes (ShapePath.toShapes).
export function shapesFromRivePath(path: RivePath, scale: f64 = 1, isCCW: bool = false): Array<Shape> {
    return shapePathFromRivePath(path, scale, true).toShapes(isCCW);
}

/// The reverse: a ShapePath (an SVGLoader path, ShapePath.toShapes input)
/// as a Rive path. Lines, quadratic and cubic Béziers stay as they are,
/// ellipse arcs become cubics (a quarter turn or less each) and other
/// curves points. Each sub-path is a contour, closed when its `autoClose`
/// is set (SVG's "Z", polygons). Coordinates are scaled by `scale`, and y
/// flipped when `flipY`: off by default, as SVG's y points down like
/// Rive's (pass true for a path in three.js's y-up units). Set the result's
/// `fillRule` from the SVG style (`"evenodd"`: FillRule.evenOdd, else
/// nonZero) before filling it.
export function rivePathFromShapePath(shapePath: ShapePath, scale: f64 = 1, flipY: bool = false): RivePath {
    const out = new RivePath();
    const sy = flipY ? -scale : scale;
    const subPaths = shapePath.subPaths;
    for (let i = 0; i < subPaths.length; i++) {
        const sub = subPaths[i];
        const curves = sub.curves;
        if (curves.length == 0) continue;
        const start = curves[0].getPoint(0, new Vector2());
        out.moveTo(Vector.xy(<f32>(start.x * scale), <f32>(start.y * sy)));
        for (let j = 0; j < curves.length; j++) {
            const curve = curves[j];
            if (curve instanceof LineCurve) {
                const c = curve as LineCurve;
                out.lineTo(Vector.xy(<f32>(c.v2.x * scale), <f32>(c.v2.y * sy)));
            } else if (curve instanceof QuadraticBezierCurve) {
                const c = curve as QuadraticBezierCurve;
                out.quadTo(Vector.xy(<f32>(c.v1.x * scale), <f32>(c.v1.y * sy)),
                    Vector.xy(<f32>(c.v2.x * scale), <f32>(c.v2.y * sy)));
            } else if (curve instanceof CubicBezierCurve) {
                const c = curve as CubicBezierCurve;
                out.cubicTo(Vector.xy(<f32>(c.v1.x * scale), <f32>(c.v1.y * sy)),
                    Vector.xy(<f32>(c.v2.x * scale), <f32>(c.v2.y * sy)),
                    Vector.xy(<f32>(c.v3.x * scale), <f32>(c.v3.y * sy)));
            } else if (curve instanceof EllipseCurve) {
                ellipseToCubics(out, curve as EllipseCurve, scale, sy);
            } else {
                const pts = curve.getPoints(curve.pointResolution(12));
                for (let k = 1; k < pts.length; k++) {
                    out.lineTo(Vector.xy(<f32>(pts[k].x * scale), <f32>(pts[k].y * sy)));
                }
            }
        }
        if (sub.autoClose) out.close();
    }
    return out;
}

/// An EllipseCurve as cubics, sweeping as EllipseCurve.getPoint does.
function ellipseToCubics(out: RivePath, c: EllipseCurve, sx: f64, sy: f64): void {
    const twoPi = Math.PI * 2;
    let deltaAngle = c.aEndAngle - c.aStartAngle;
    const samePoints = Math.abs(deltaAngle) < 2.220446049250313e-16;
    while (deltaAngle < 0) deltaAngle += twoPi;
    while (deltaAngle > twoPi) deltaAngle -= twoPi;
    if (deltaAngle < 2.220446049250313e-16) deltaAngle = samePoints ? 0 : twoPi;
    if (c.aClockwise && !samePoints) deltaAngle = deltaAngle == twoPi ? -twoPi : deltaAngle - twoPi;
    // Path.absellipse joined the previous point to the start with a line.
    if (deltaAngle == 0) return;
    const segments = <i32>Math.ceil(Math.abs(deltaAngle) / (Math.PI / 2) - 1e-9);
    const step = deltaAngle / <f64>segments;
    const k = 4 / 3 * Math.tan(step / 4);
    const cr = Math.cos(c.aRotation), sr = Math.sin(c.aRotation);
    let a0 = c.aStartAngle;
    for (let s = 0; s < segments; s++) {
        const a1 = a0 + step;
        const c0 = Math.cos(a0), s0 = Math.sin(a0), c1 = Math.cos(a1), s1 = Math.sin(a1);
        // Unit-circle control points, then the ellipse's radii, rotation
        // and center.
        const p1x = c0 - k * s0, p1y = s0 + k * c0;
        const p2x = c1 + k * s1, p2y = s1 - k * c1;
        out.cubicTo(ellipsePoint(c, p1x, p1y, cr, sr, sx, sy), ellipsePoint(c, p2x, p2y, cr, sr, sx, sy),
            ellipsePoint(c, c1, s1, cr, sr, sx, sy));
        a0 = a1;
    }
}

function ellipsePoint(c: EllipseCurve, ux: f64, uy: f64, cr: f64, sr: f64, sx: f64, sy: f64): Vector {
    const x = ux * c.xRadius, y = uy * c.yRadius;
    return Vector.xy(<f32>((c.aX + x * cr - y * sr) * sx), <f32>((c.aY + x * sr + y * cr) * sy));
}
