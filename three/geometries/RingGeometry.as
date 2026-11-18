// three.js RingGeometry: an annulus in the XY plane, facing +Z.

import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";

export class RingGeometryParameters {
    innerRadius: f64 = 0.5;
    outerRadius: f64 = 1;
    thetaSegments: i32 = 32;
    phiSegments: i32 = 1;
    thetaStart: f64 = 0;
    thetaLength: f64 = Math.PI * 2;
}

export class RingGeometry extends BufferGeometry {
    parameters: RingGeometryParameters = new RingGeometryParameters();

    constructor(innerRadius: f64 = 0.5, outerRadius: f64 = 1, thetaSegments: i32 = 32, phiSegments: i32 = 1,
                thetaStart: f64 = 0, thetaLength: f64 = Math.PI * 2) {
        super();
        this.type = "RingGeometry";
        const p = this.parameters;
        p.innerRadius = innerRadius; p.outerRadius = outerRadius; p.thetaSegments = thetaSegments;
        p.phiSegments = phiSegments; p.thetaStart = thetaStart; p.thetaLength = thetaLength;
        const ts = max<i32>(3, thetaSegments);
        const ps = max<i32>(1, phiSegments);

        const indices: Array<i32> = [];
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];
        let radius = innerRadius;
        const radiusStep = (outerRadius - innerRadius) / <f64>ps;
        for (let j = 0; j <= ps; j++) {
            for (let i = 0; i <= ts; i++) {
                const segment = thetaStart + <f64>i / <f64>ts * thetaLength;
                const x = radius * Math.cos(segment), y = radius * Math.sin(segment);
                vertices.push(x); vertices.push(y); vertices.push(0);
                normals.push(0); normals.push(0); normals.push(1);
                uvs.push((x / outerRadius + 1) / 2);
                uvs.push((y / outerRadius + 1) / 2);
            }
            radius += radiusStep;
        }
        for (let j = 0; j < ps; j++) {
            const level = j * (ts + 1);
            for (let i = 0; i < ts; i++) {
                const a = i + level, b = a + ts + 1, c = a + ts + 2, d = a + 1;
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
