// three.js TorusGeometry: around the Z axis, in the XY plane.

import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";

export class TorusGeometryParameters {
    radius: f64 = 1;
    tube: f64 = 0.4;
    radialSegments: i32 = 12;
    tubularSegments: i32 = 48;
    arc: f64 = Math.PI * 2;
}

export class TorusGeometry extends BufferGeometry {
    parameters: TorusGeometryParameters = new TorusGeometryParameters();

    constructor(radius: f64 = 1, tube: f64 = 0.4, radialSegments: i32 = 12, tubularSegments: i32 = 48,
                arc: f64 = Math.PI * 2) {
        super();
        this.type = "TorusGeometry";
        const p = this.parameters;
        p.radius = radius; p.tube = tube; p.radialSegments = radialSegments;
        p.tubularSegments = tubularSegments; p.arc = arc;

        const indices: Array<i32> = [];
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];
        for (let j = 0; j <= radialSegments; j++) {
            for (let i = 0; i <= tubularSegments; i++) {
                const u = <f64>i / <f64>tubularSegments * arc;
                const v = <f64>j / <f64>radialSegments * Math.PI * 2;
                const x = (radius + tube * Math.cos(v)) * Math.cos(u);
                const y = (radius + tube * Math.cos(v)) * Math.sin(u);
                const z = tube * Math.sin(v);
                vertices.push(x); vertices.push(y); vertices.push(z);
                let nx = x - radius * Math.cos(u), ny = y - radius * Math.sin(u), nz = z;
                const l = Math.sqrt(nx * nx + ny * ny + nz * nz);
                if (l > 0) { nx /= l; ny /= l; nz /= l; }
                normals.push(nx); normals.push(ny); normals.push(nz);
                uvs.push(<f64>i / <f64>tubularSegments);
                uvs.push(<f64>j / <f64>radialSegments);
            }
        }
        for (let j = 1; j <= radialSegments; j++) {
            for (let i = 1; i <= tubularSegments; i++) {
                const a = (tubularSegments + 1) * j + i - 1;
                const b = (tubularSegments + 1) * (j - 1) + i - 1;
                const c = (tubularSegments + 1) * (j - 1) + i;
                const d = (tubularSegments + 1) * j + i;
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
