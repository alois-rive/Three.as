// three.js ExtrudeGeometry: shapes extruded along +Z by `depth` (or along
// `extrudePath`), optionally bevelled. Non-indexed; group 0 the caps, 1 the
// sides. UVs are three.js's WorldUVGenerator.

import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { Shape } from "../extras/core/Shape";
import { Curve, computeFrenetFrames, FrenetFrames } from "../extras/core/Curve";
import { ShapeUtils } from "../extras/ShapeUtils";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";

const EPSILON: f64 = 2.220446049250313e-16;

export class ExtrudeGeometryOptions {
    curveSegments: i32 = 12;
    steps: i32 = 1;
    depth: f64 = 1;
    bevelEnabled: bool = true;
    bevelThickness: f64 = 0.2;
    /// Default: bevelThickness - 0.1 (NaN means "not given").
    bevelSize: f64 = NaN;
    bevelOffset: f64 = 0;
    bevelSegments: i32 = 3;
    extrudePath: Curve<Vector3>? = null;
}

export class ExtrudeGeometry extends BufferGeometry {
    shapes: Array<Shape>;
    options: ExtrudeGeometryOptions;

    private verticesArray: Array<f64> = [];
    private uvArray: Array<f64> = [];

    constructor(shapes: Array<Shape> = [new Shape([new Vector2(0.5, 0.5), new Vector2(-0.5, 0.5),
                    new Vector2(-0.5, -0.5), new Vector2(0.5, -0.5)])],
                options: ExtrudeGeometryOptions? = null) {
        super();
        this.type = "ExtrudeGeometry";
        this.shapes = shapes;
        this.options = options != null ? options : new ExtrudeGeometryOptions();
        for (let i = 0; i < shapes.length; i++) this.addShape(shapes[i]);
        this.setAttribute("position", new Float32BufferAttribute(this.verticesArray, 3));
        this.setAttribute("uv", new Float32BufferAttribute(this.uvArray, 2));
        this.computeVertexNormals();
        this.verticesArray = [];
        this.uvArray = [];
    }

    private addShape(shape: Shape): void {
        const o = this.options;
        const placeholder: Array<f64> = [];
        const curveSegments = o.curveSegments;
        const steps = o.steps;
        const depth = o.depth;
        let bevelEnabled = o.bevelEnabled;
        let bevelThickness = o.bevelThickness;
        let bevelSize = isNaN(o.bevelSize) ? bevelThickness - 0.1 : o.bevelSize;
        let bevelOffset = o.bevelOffset;
        let bevelSegments = o.bevelSegments;
        const extrudePath = o.extrudePath;

        let extrudePts: Array<Vector3> = [];
        let extrudeByPath = false;
        let frames: FrenetFrames? = null;
        if (extrudePath != null) {
            extrudePts = extrudePath.getSpacedPoints(steps);
            extrudeByPath = true;
            bevelEnabled = false;
            frames = computeFrenetFrames(extrudePath, steps, false);
        }
        if (!bevelEnabled) {
            bevelSegments = 0;
            bevelThickness = 0;
            bevelSize = 0;
            bevelOffset = 0;
        }

        const shapePoints = shape.extractPoints(curveSegments);
        let vertices = shapePoints.shape;
        const holes = shapePoints.holes;
        if (!ShapeUtils.isClockWise(vertices)) {
            vertices = vertices.reverse();
            for (let h = 0; h < holes.length; h++) {
                if (ShapeUtils.isClockWise(holes[h])) holes[h] = holes[h].reverse();
            }
        }
        const faces = ShapeUtils.triangulateShape(vertices, holes);
        const contour = vertices;
        for (let h = 0; h < holes.length; h++) vertices = vertices.concat(holes[h]);
        const vlen = vertices.length, flen = faces.length;

        const contourMovements: Array<Vector2> = [];
        for (let i = 0, il = contour.length, j = il - 1, k = i + 1; i < il; i++, j++, k++) {
            if (j == il) j = 0;
            if (k == il) k = 0;
            contourMovements.push(getBevelVec(contour[i], contour[j], contour[k]));
        }
        const holesMovements: Array<Array<Vector2>> = [];
        let verticesMovements = contourMovements.concat([]);
        for (let h = 0; h < holes.length; h++) {
            const ahole = holes[h];
            const oneHoleMovements: Array<Vector2> = [];
            for (let i = 0, il = ahole.length, j = il - 1, k = i + 1; i < il; i++, j++, k++) {
                if (j == il) j = 0;
                if (k == il) k = 0;
                oneHoleMovements.push(getBevelVec(ahole[i], ahole[j], ahole[k]));
            }
            holesMovements.push(oneHoleMovements);
            verticesMovements = verticesMovements.concat(oneHoleMovements);
        }

        // Back bevel rings.
        for (let b = 0; b < bevelSegments; b++) {
            const t = <f64>b / <f64>bevelSegments;
            const z = bevelThickness * Math.cos(t * Math.PI / 2);
            const bs = bevelSize * Math.sin(t * Math.PI / 2) + bevelOffset;
            for (let i = 0; i < contour.length; i++) {
                const vert = scalePt2(contour[i], contourMovements[i], bs);
                v(placeholder, vert.x, vert.y, -z);
            }
            for (let h = 0; h < holes.length; h++) {
                for (let i = 0; i < holes[h].length; i++) {
                    const vert = scalePt2(holes[h][i], holesMovements[h][i], bs);
                    v(placeholder, vert.x, vert.y, -z);
                }
            }
        }
        const bs = bevelSize + bevelOffset;
        const normal = new Vector3(), binormal = new Vector3(), position2 = new Vector3();
        // Steps 0..steps.
        for (let s = 0; s <= steps; s++) {
            for (let i = 0; i < vlen; i++) {
                const vert = bevelEnabled ? scalePt2(vertices[i], verticesMovements[i], bs) : vertices[i];
                if (!extrudeByPath) {
                    v(placeholder, vert.x, vert.y, depth / <f64>steps * <f64>s);
                } else {
                    const f = frames!;
                    normal.copy(f.normals[s]).multiplyScalar(vert.x);
                    binormal.copy(f.binormals[s]).multiplyScalar(vert.y);
                    position2.copy(extrudePts[s]).add(normal).add(binormal);
                    v(placeholder, position2.x, position2.y, position2.z);
                }
            }
        }
        // Front bevel rings.
        for (let b = bevelSegments - 1; b >= 0; b--) {
            const t = <f64>b / <f64>bevelSegments;
            const z = bevelThickness * Math.cos(t * Math.PI / 2);
            const bs2 = bevelSize * Math.sin(t * Math.PI / 2) + bevelOffset;
            for (let i = 0; i < contour.length; i++) {
                const vert = scalePt2(contour[i], contourMovements[i], bs2);
                v(placeholder, vert.x, vert.y, depth + z);
            }
            for (let h = 0; h < holes.length; h++) {
                for (let i = 0; i < holes[h].length; i++) {
                    const vert = scalePt2(holes[h][i], holesMovements[h][i], bs2);
                    v(placeholder, vert.x, vert.y, depth + z);
                }
            }
        }

        // Lid faces.
        let start = this.verticesArray.length / 3;
        if (bevelEnabled) {
            let offset = 0;
            for (let i = 0; i < flen; i++) {
                const face = faces[i];
                this.f3(placeholder, face[2] + offset, face[1] + offset, face[0] + offset);
            }
            offset = vlen * (steps + bevelSegments * 2);
            for (let i = 0; i < flen; i++) {
                const face = faces[i];
                this.f3(placeholder, face[0] + offset, face[1] + offset, face[2] + offset);
            }
        } else {
            for (let i = 0; i < flen; i++) {
                const face = faces[i];
                this.f3(placeholder, face[2], face[1], face[0]);
            }
            for (let i = 0; i < flen; i++) {
                const face = faces[i];
                this.f3(placeholder, face[0] + vlen * steps, face[1] + vlen * steps, face[2] + vlen * steps);
            }
        }
        this.addGroup(start, this.verticesArray.length / 3 - start, 0);

        // Side faces.
        start = this.verticesArray.length / 3;
        let layeroffset = 0;
        this.sidewalls(placeholder, contour, layeroffset, vlen, steps + bevelSegments * 2);
        layeroffset += contour.length;
        for (let h = 0; h < holes.length; h++) {
            this.sidewalls(placeholder, holes[h], layeroffset, vlen, steps + bevelSegments * 2);
            layeroffset += holes[h].length;
        }
        this.addGroup(start, this.verticesArray.length / 3 - start, 1);
    }

    private sidewalls(placeholder: Array<f64>, contour: Array<Vector2>, layeroffset: i32, vlen: i32, layers: i32): void {
        let i = contour.length;
        while (--i >= 0) {
            const j = i;
            let k = i - 1;
            if (k < 0) k = contour.length - 1;
            for (let s = 0; s < layers; s++) {
                const slen1 = vlen * s, slen2 = vlen * (s + 1);
                const a = layeroffset + j + slen1, b = layeroffset + k + slen1;
                const c = layeroffset + k + slen2, d = layeroffset + j + slen2;
                this.f4(placeholder, a, b, c, d);
            }
        }
    }

    private addVertex(placeholder: Array<f64>, index: i32): void {
        this.verticesArray.push(placeholder[index * 3]);
        this.verticesArray.push(placeholder[index * 3 + 1]);
        this.verticesArray.push(placeholder[index * 3 + 2]);
    }

    private f3(placeholder: Array<f64>, a: i32, b: i32, c: i32): void {
        this.addVertex(placeholder, a);
        this.addVertex(placeholder, b);
        this.addVertex(placeholder, c);
        // WorldUVGenerator.generateTopUV: x, y.
        const va = this.verticesArray;
        const n = va.length / 3;
        for (let k = n - 3; k < n; k++) {
            this.uvArray.push(va[k * 3]);
            this.uvArray.push(va[k * 3 + 1]);
        }
    }

    private f4(placeholder: Array<f64>, a: i32, b: i32, c: i32, d: i32): void {
        this.addVertex(placeholder, a);
        this.addVertex(placeholder, b);
        this.addVertex(placeholder, d);
        this.addVertex(placeholder, b);
        this.addVertex(placeholder, c);
        this.addVertex(placeholder, d);
        // WorldUVGenerator.generateSideWallUV over a, b, c, d.
        const va = this.verticesArray;
        const n = va.length / 3;
        const iA = n - 6, iB = n - 3, iC = n - 2, iD = n - 1;
        const ax = va[iA * 3], ay = va[iA * 3 + 1], az = va[iA * 3 + 2];
        const bx = va[iB * 3], by = va[iB * 3 + 1], bz = va[iB * 3 + 2];
        const cx = va[iC * 3], cy = va[iC * 3 + 1], cz = va[iC * 3 + 2];
        const dx = va[iD * 3], dy = va[iD * 3 + 1], dz = va[iD * 3 + 2];
        const useX = Math.abs(ay - by) < Math.abs(ax - bx);
        const ua = useX ? ax : ay, ub = useX ? bx : by, uc = useX ? cx : cy, ud = useX ? dx : dy;
        const uv = this.uvArray;
        uv.push(ua); uv.push(1 - az);
        uv.push(ub); uv.push(1 - bz);
        uv.push(ud); uv.push(1 - dz);
        uv.push(ub); uv.push(1 - bz);
        uv.push(uc); uv.push(1 - cz);
        uv.push(ud); uv.push(1 - dz);
    }
}

function v(placeholder: Array<f64>, x: f64, y: f64, z: f64): void {
    placeholder.push(x);
    placeholder.push(y);
    placeholder.push(z);
}

function scalePt2(pt: Vector2, vec: Vector2, size: f64): Vector2 {
    return pt.clone().addScaledVector(vec, size);
}

function getBevelVec(inPt: Vector2, inPrev: Vector2, inNext: Vector2): Vector2 {
    let tx: f64, ty: f64, shrinkBy: f64;
    const prevX = inPt.x - inPrev.x, prevY = inPt.y - inPrev.y;
    const nextX = inNext.x - inPt.x, nextY = inNext.y - inPt.y;
    const prevLenSq = prevX * prevX + prevY * prevY;
    const collinear0 = prevX * nextY - prevY * nextX;
    if (Math.abs(collinear0) > EPSILON) {
        const prevLen = Math.sqrt(prevLenSq);
        const nextLen = Math.sqrt(nextX * nextX + nextY * nextY);
        const prevShiftX = inPrev.x - prevY / prevLen;
        const prevShiftY = inPrev.y + prevX / prevLen;
        const nextShiftX = inNext.x - nextY / nextLen;
        const nextShiftY = inNext.y + nextX / nextLen;
        const sf = ((nextShiftX - prevShiftX) * nextY - (nextShiftY - prevShiftY) * nextX) / (prevX * nextY - prevY * nextX);
        tx = prevShiftX + prevX * sf - inPt.x;
        ty = prevShiftY + prevY * sf - inPt.y;
        const transLenSq = tx * tx + ty * ty;
        if (transLenSq <= 2) return new Vector2(tx, ty);
        shrinkBy = Math.sqrt(transLenSq / 2);
    } else {
        let directionEq = false;
        if (prevX > EPSILON) {
            if (nextX > EPSILON) directionEq = true;
        } else if (prevX < -EPSILON) {
            if (nextX < -EPSILON) directionEq = true;
        } else if (Math.sign(prevY) == Math.sign(nextY)) {
            directionEq = true;
        }
        if (directionEq) {
            tx = -prevY;
            ty = prevX;
            shrinkBy = Math.sqrt(prevLenSq);
        } else {
            tx = prevX;
            ty = prevY;
            shrinkBy = Math.sqrt(prevLenSq / 2);
        }
    }
    return new Vector2(tx / shrinkBy, ty / shrinkBy);
}
