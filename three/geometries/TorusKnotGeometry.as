// three.js TorusKnotGeometry: a (p, q) torus knot tube.

import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { Vector3 } from "../math/Vector3";

export class TorusKnotGeometryParameters {
    radius: f64 = 1;
    tube: f64 = 0.4;
    tubularSegments: i32 = 64;
    radialSegments: i32 = 8;
    p: f64 = 2;
    q: f64 = 3;
}

export class TorusKnotGeometry extends BufferGeometry {
    parameters: TorusKnotGeometryParameters = new TorusKnotGeometryParameters();

    constructor(radius: f64 = 1, tube: f64 = 0.4, tubularSegments: i32 = 64, radialSegments: i32 = 8,
                p: f64 = 2, q: f64 = 3) {
        super();
        this.type = "TorusKnotGeometry";
        const prm = this.parameters;
        prm.radius = radius; prm.tube = tube; prm.tubularSegments = tubularSegments;
        prm.radialSegments = radialSegments; prm.p = p; prm.q = q;

        const indices: Array<i32> = [];
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];
        const P1 = new Vector3(), P2 = new Vector3(), B = new Vector3(), T = new Vector3(), N = new Vector3();
        const vertex = new Vector3(), normal = new Vector3();
        for (let i = 0; i <= tubularSegments; i++) {
            const u = <f64>i / <f64>tubularSegments * p * Math.PI * 2;
            positionOnCurve(u, p, q, radius, P1);
            positionOnCurve(u + 0.01, p, q, radius, P2);
            T.subVectors(P2, P1);
            N.addVectors(P2, P1);
            B.crossVectors(T, N);
            N.crossVectors(B, T);
            B.normalize();
            N.normalize();
            for (let j = 0; j <= radialSegments; j++) {
                const v = <f64>j / <f64>radialSegments * Math.PI * 2;
                const cx = -tube * Math.cos(v);
                const cy = tube * Math.sin(v);
                vertex.x = P1.x + (cx * N.x + cy * B.x);
                vertex.y = P1.y + (cx * N.y + cy * B.y);
                vertex.z = P1.z + (cx * N.z + cy * B.z);
                vertices.push(vertex.x); vertices.push(vertex.y); vertices.push(vertex.z);
                normal.subVectors(vertex, P1).normalize();
                normals.push(normal.x); normals.push(normal.y); normals.push(normal.z);
                uvs.push(<f64>i / <f64>tubularSegments);
                uvs.push(<f64>j / <f64>radialSegments);
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
        this.setIndex(indices);
        this.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        this.setAttribute("normal", new Float32BufferAttribute(normals, 3));
        this.setAttribute("uv", new Float32BufferAttribute(uvs, 2));
    }
}

function positionOnCurve(u: f64, p: f64, q: f64, radius: f64, position: Vector3): void {
    const cu = Math.cos(u), su = Math.sin(u);
    const quOverP = q / p * u;
    const cs = Math.cos(quOverP);
    position.x = radius * (2 + cs) * 0.5 * cu;
    position.y = radius * (2 + cs) * su * 0.5;
    position.z = radius * Math.sin(quOverP) * 0.5;
}
