// three.js examples/jsm/geometries/RoundedBoxGeometry.js: a box whose
// edges and corners are rounded with `radius`, `segments` per round.

import { BoxGeometry } from "../../geometries/BoxGeometry";
import { Vector3 } from "../../math/Vector3";

const _tempNormal = new Vector3();

function getUv(faceDirVector: Vector3, normal: Vector3, uvAxis: i32, projectionAxis: i32, radius: f64, sideLength: f64): f64 {
    const totArcLength = 2 * Math.PI * radius / 4;
    // The planar facet's length.
    const centerLength = Math.max(sideLength - 2 * radius, 0);
    const halfArc = Math.PI / 4;
    // The normal projected onto the plane across `projectionAxis`.
    _tempNormal.copy(normal);
    _tempNormal.setComponent(projectionAxis, 0);
    _tempNormal.normalize();
    // UV space for one arc, and how far along it the point is.
    const arcUvRatio = 0.5 * totArcLength / (totArcLength + centerLength);
    const arcAngleRatio = 1.0 - (_tempNormal.angleTo(faceDirVector) / halfArc);
    if (_tempNormal.getComponent(uvAxis) > 0) return arcAngleRatio * arcUvRatio;
    const lenUv = centerLength / (totArcLength + centerLength);
    return lenUv + arcUvRatio + arcUvRatio * (1.0 - arcAngleRatio);
}

const X = 0, Y = 1, Z = 2;

export class RoundedBoxGeometry extends BoxGeometry {
    constructor(width: f64 = 1, height: f64 = 1, depth: f64 = 1, segments: i32 = 2, radius: f64 = 0.1) {
        // Odd segments, so a plane joins the rounded corners.
        const segs = segments * 2 + 1;
        const r = Math.min(width / 2, Math.min(height / 2, Math.min(depth / 2, radius)));
        super(1, 1, 1, segs, segs, segs);
        this.type = "RoundedBoxGeometry";
        if (segs == 1) return;
        const flat = this.toNonIndexed();
        this.index = null;
        this.setAttribute("position", flat.getAttribute("position")!);
        this.setAttribute("normal", flat.getAttribute("normal")!);
        this.setAttribute("uv", flat.getAttribute("uv")!);
        const position = new Vector3();
        const normal = new Vector3();
        const box = new Vector3(width, height, depth).divideScalar(2).subScalar(r);
        const positions = this.getAttribute("position")!.array;
        const normals = this.getAttribute("normal")!.array;
        const uvs = this.getAttribute("uv")!.array;
        const faceTris = positions.length / 6;
        const faceDir = new Vector3();
        const halfSegmentSize = 0.5 / <f64>segs;
        for (let i = 0, j = 0; i < positions.length; i += 3, j += 2) {
            position.set(<f64>positions[i], <f64>positions[i + 1], <f64>positions[i + 2]);
            normal.copy(position);
            normal.x -= sign(normal.x) * halfSegmentSize;
            normal.y -= sign(normal.y) * halfSegmentSize;
            normal.z -= sign(normal.z) * halfSegmentSize;
            normal.normalize();
            positions[i] = <f32>(box.x * sign(position.x) + normal.x * r);
            positions[i + 1] = <f32>(box.y * sign(position.y) + normal.y * r);
            positions[i + 2] = <f32>(box.z * sign(position.z) + normal.z * r);
            normals[i] = <f32>normal.x; normals[i + 1] = <f32>normal.y; normals[i + 2] = <f32>normal.z;
            const side = i / faceTris;
            let u: f64 = 0, v: f64 = 0;
            if (side == 0) {            // right
                faceDir.set(1, 0, 0);
                u = getUv(faceDir, normal, Z, Y, r, depth); v = 1.0 - getUv(faceDir, normal, Y, Z, r, height);
            } else if (side == 1) {     // left
                faceDir.set(-1, 0, 0);
                u = 1.0 - getUv(faceDir, normal, Z, Y, r, depth); v = 1.0 - getUv(faceDir, normal, Y, Z, r, height);
            } else if (side == 2) {     // top
                faceDir.set(0, 1, 0);
                u = 1.0 - getUv(faceDir, normal, X, Z, r, width); v = getUv(faceDir, normal, Z, X, r, depth);
            } else if (side == 3) {     // bottom
                faceDir.set(0, -1, 0);
                u = 1.0 - getUv(faceDir, normal, X, Z, r, width); v = 1.0 - getUv(faceDir, normal, Z, X, r, depth);
            } else if (side == 4) {     // front
                faceDir.set(0, 0, 1);
                u = 1.0 - getUv(faceDir, normal, X, Y, r, width); v = 1.0 - getUv(faceDir, normal, Y, X, r, height);
            } else {                    // back
                faceDir.set(0, 0, -1);
                u = getUv(faceDir, normal, X, Y, r, width); v = 1.0 - getUv(faceDir, normal, Y, X, r, height);
            }
            uvs[j] = <f32>u; uvs[j + 1] = <f32>v;
        }
    }
}

function sign(x: f64): f64 { return x > 0 ? 1 : x < 0 ? -1 : 0; }
