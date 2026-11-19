// three.js EdgesGeometry: line segments (pairs of positions) along the
// edges where adjacent faces meet at more than `thresholdAngle` degrees,
// plus open edges. Draw it with LineSegments.

import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { Vector3 } from "../math/Vector3";
import { Triangle } from "../math/Triangle";
import { DEG2RAD } from "../math/MathUtils";

class EdgeData {
    index0: i32;
    index1: i32;
    normal: Vector3;
    open: bool = true;

    constructor(index0: i32, index1: i32, normal: Vector3) {
        this.index0 = index0;
        this.index1 = index1;
        this.normal = normal;
    }
}

export class EdgesGeometryParameters {
    geometry: BufferGeometry? = null;
    thresholdAngle: f64 = 1;
}

export class EdgesGeometry extends BufferGeometry {
    parameters: EdgesGeometryParameters = new EdgesGeometryParameters();

    constructor(geometry: BufferGeometry? = null, thresholdAngle: f64 = 1) {
        super();
        this.type = "EdgesGeometry";
        this.parameters.geometry = geometry;
        this.parameters.thresholdAngle = thresholdAngle;
        if (geometry == null) return;
        const position = geometry.getAttribute("position");
        if (position == null) return;

        const precision: f64 = 10000;
        const thresholdDot = Math.cos(DEG2RAD * thresholdAngle);
        const index = geometry.index;
        const indexCount = index != null ? index.count : position.count;
        const indexArr: StaticArray<i32> = [0, 0, 0];
        const hashes: StaticArray<string> = ["", "", ""];
        const tri = new Triangle();
        const corners: StaticArray<Vector3> = [tri.a, tri.b, tri.c];
        const normal = new Vector3();
        const edges = new Map<string, EdgeData>();
        const order: Array<string> = [];
        const vertices: Array<f64> = [];

        for (let i = 0; i + 2 < indexCount; i += 3) {
            for (let k = 0; k < 3; k++) indexArr[k] = index != null ? index.getX(i + k) : i + k;
            tri.setFromAttributeAndIndices(position, indexArr[0], indexArr[1], indexArr[2]);
            tri.getNormal(normal);
            for (let k = 0; k < 3; k++) {
                const v = corners[k];
                hashes[k] = Math.round(v.x * precision).toString() + "," + Math.round(v.y * precision).toString()
                    + "," + Math.round(v.z * precision).toString();
            }
            if (hashes[0] == hashes[1] || hashes[1] == hashes[2] || hashes[2] == hashes[0]) continue;
            for (let j = 0; j < 3; j++) {
                const jNext = (j + 1) % 3;
                const hash = hashes[j] + "_" + hashes[jNext];
                const reverseHash = hashes[jNext] + "_" + hashes[j];
                if (edges.has(reverseHash) && edges.get(reverseHash).open) {
                    const e = edges.get(reverseHash);
                    if (normal.dot(e.normal) <= thresholdDot) {
                        const v0 = corners[j], v1 = corners[jNext];
                        vertices.push(v0.x); vertices.push(v0.y); vertices.push(v0.z);
                        vertices.push(v1.x); vertices.push(v1.y); vertices.push(v1.z);
                    }
                    e.open = false;
                } else if (!edges.has(hash)) {
                    edges.set(hash, new EdgeData(indexArr[j], indexArr[jNext], normal.clone()));
                    order.push(hash);
                }
            }
        }
        // Edges used by one face only.
        for (let i = 0; i < order.length; i++) {
            const e = edges.get(order[i]);
            if (!e.open) continue;
            vertices.push(position.getX(e.index0)); vertices.push(position.getY(e.index0)); vertices.push(position.getZ(e.index0));
            vertices.push(position.getX(e.index1)); vertices.push(position.getY(e.index1)); vertices.push(position.getZ(e.index1));
        }
        this.setAttribute("position", new Float32BufferAttribute(vertices, 3));
    }
}
