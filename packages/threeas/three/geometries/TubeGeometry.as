// three.js TubeGeometry: a tube of `radius` along a 3D curve.

import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { Curve, computeFrenetFrames, FrenetFrames } from "../extras/core/Curve";
import { QuadraticBezierCurve3 } from "../extras/curves/Curves";
import { Vector3 } from "../math/Vector3";

export class TubeGeometry extends BufferGeometry {
    path: Curve<Vector3>;
    tubularSegments: i32;
    radius: f64;
    radialSegments: i32;
    closed: bool;
    tangents: Array<Vector3>;
    normals: Array<Vector3>;
    binormals: Array<Vector3>;

    constructor(path: Curve<Vector3> = new QuadraticBezierCurve3(new Vector3(-1, -1, 0), new Vector3(-1, 1, 0), new Vector3(1, 1, 0)),
                tubularSegments: i32 = 64, radius: f64 = 1, radialSegments: i32 = 8, closed: bool = false) {
        super();
        this.type = "TubeGeometry";
        this.path = path;
        this.tubularSegments = tubularSegments;
        this.radius = radius;
        this.radialSegments = radialSegments;
        this.closed = closed;
        const frames: FrenetFrames = computeFrenetFrames(path, tubularSegments, closed);
        this.tangents = frames.tangents;
        this.normals = frames.normals;
        this.binormals = frames.binormals;

        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];
        const indices: Array<i32> = [];
        const P = new Vector3(), normal = new Vector3(), vertex = new Vector3();
        for (let i = 0; i <= tubularSegments; i++) {
            const at = closed && i == tubularSegments ? 0 : i;
            path.getPointAt(<f64>at / <f64>tubularSegments, P);
            const N = frames.normals[at], B = frames.binormals[at];
            for (let j = 0; j <= radialSegments; j++) {
                const a = <f64>j / <f64>radialSegments * Math.PI * 2;
                const sin = Math.sin(a), cos = -Math.cos(a);
                normal.set(cos * N.x + sin * B.x, cos * N.y + sin * B.y, cos * N.z + sin * B.z).normalize();
                normals.push(normal.x); normals.push(normal.y); normals.push(normal.z);
                vertex.copy(P).addScaledVector(normal, radius);
                vertices.push(vertex.x); vertices.push(vertex.y); vertices.push(vertex.z);
            }
        }
        for (let j = 1; j <= tubularSegments; j++) {
            for (let i = 1; i <= radialSegments; i++) {
                const a = (radialSegments + 1) * (j - 1) + (i - 1);
                const b = (radialSegments + 1) * j + (i - 1);
                const c = (radialSegments + 1) * j + i;
                const d = (radialSegments + 1) * (j - 1) + i;
                indices.push(a); indices.push(b); indices.push(d);
                indices.push(b); indices.push(c); indices.push(d);
            }
        }
        for (let i = 0; i <= tubularSegments; i++) {
            for (let j = 0; j <= radialSegments; j++) {
                uvs.push(<f64>i / <f64>tubularSegments);
                uvs.push(<f64>j / <f64>radialSegments);
            }
        }
        this.setIndex(indices);
        this.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        this.setAttribute("normal", new Float32BufferAttribute(normals, 3));
        this.setAttribute("uv", new Float32BufferAttribute(uvs, 2));
    }
}
