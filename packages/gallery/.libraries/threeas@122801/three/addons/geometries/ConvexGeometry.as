// three.js examples/jsm/geometries/ConvexGeometry.js: the convex hull of
// points as flat-shaded triangles.

import { BufferGeometry } from "../../core/BufferGeometry";
import { Float32BufferAttribute } from "../../core/BufferAttribute";
import { Vector3 } from "../../math/Vector3";
import { ConvexHull } from "../math/ConvexHull";

export class ConvexGeometry extends BufferGeometry {
    constructor(points: Array<Vector3> = []) {
        super();
        this.type = "ConvexGeometry";
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const hull = new ConvexHull().setFromPoints(points);
        const p = hull.points;
        for (let i = 0; i < hull.faces.length; i++) {
            const f = hull.faces[i];
            const ids: StaticArray<i32> = [f.a, f.b, f.c];
            for (let k = 0; k < 3; k++) {
                const v = p[ids[k]];
                vertices.push(v.x); vertices.push(v.y); vertices.push(v.z);
                normals.push(f.normal.x); normals.push(f.normal.y); normals.push(f.normal.z);
            }
        }
        this.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        this.setAttribute("normal", new Float32BufferAttribute(normals, 3));
    }
}
