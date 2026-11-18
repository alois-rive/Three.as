// Rive paths as three.js shapes: a Rive `Path` (drawn by a script, or read
// from a node with `NodeData.asPath()`) to a ShapePath, so Rive vector
// art extrudes or fills in 3D. Rive's y points down, three.js's up, so
// y is flipped (and scaled by `scale`).

import { Path as RivePath } from "rive/path";
import { ShapePath } from "../extras/core/ShapePath";
import { Shape } from "../extras/core/Shape";

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
