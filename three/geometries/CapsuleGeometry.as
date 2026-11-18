// three.js CapsuleGeometry (r163+): a cylinder of `height` capped by two
// hemispheres of `radius`, along Y.

import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { Vector3 } from "../math/Vector3";

export class CapsuleGeometryParameters {
    radius: f64 = 1;
    height: f64 = 1;
    capSegments: i32 = 4;
    radialSegments: i32 = 8;
    heightSegments: i32 = 1;
}

export class CapsuleGeometry extends BufferGeometry {
    parameters: CapsuleGeometryParameters = new CapsuleGeometryParameters();

    constructor(radius: f64 = 1, height: f64 = 1, capSegments: i32 = 4, radialSegments: i32 = 8,
                heightSegments: i32 = 1) {
        super();
        this.type = "CapsuleGeometry";
        height = Math.max(0, height);
        capSegments = max<i32>(1, capSegments);
        radialSegments = max<i32>(3, radialSegments);
        heightSegments = max<i32>(1, heightSegments);
        const p = this.parameters;
        p.radius = radius; p.height = height; p.capSegments = capSegments;
        p.radialSegments = radialSegments; p.heightSegments = heightSegments;

        const indices: Array<i32> = [];
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];
        const halfHeight = height / 2;
        const capArcLength = (Math.PI / 2) * radius;
        const totalArcLength = 2 * capArcLength + height;
        const numVerticalSegments = capSegments * 2 + heightSegments;
        const verticesPerRow = radialSegments + 1;
        const normal = new Vector3();

        for (let iy = 0; iy <= numVerticalSegments; iy++) {
            let arc: f64 = 0, profileY: f64 = 0, profileRadius: f64 = 0, normalY: f64 = 0;
            if (iy <= capSegments) {
                const t = <f64>iy / <f64>capSegments;
                const angle = t * Math.PI / 2;
                profileY = -halfHeight - radius * Math.cos(angle);
                profileRadius = radius * Math.sin(angle);
                normalY = -radius * Math.cos(angle);
                arc = t * capArcLength;
            } else if (iy <= capSegments + heightSegments) {
                const t = <f64>(iy - capSegments) / <f64>heightSegments;
                profileY = -halfHeight + t * height;
                profileRadius = radius;
                normalY = 0;
                arc = capArcLength + t * height;
            } else {
                const t = <f64>(iy - capSegments - heightSegments) / <f64>capSegments;
                const angle = t * Math.PI / 2;
                profileY = halfHeight + radius * Math.sin(angle);
                profileRadius = radius * Math.cos(angle);
                normalY = radius * Math.sin(angle);
                arc = capArcLength + height + t * capArcLength;
            }
            const v = Math.max(0, Math.min(1, arc / totalArcLength));
            let uOffset: f64 = 0;
            if (iy == 0) uOffset = 0.5 / radialSegments;
            else if (iy == numVerticalSegments) uOffset = -0.5 / radialSegments;
            for (let ix = 0; ix <= radialSegments; ix++) {
                const u = <f64>ix / <f64>radialSegments;
                const theta = u * Math.PI * 2;
                const sinTheta = Math.sin(theta), cosTheta = Math.cos(theta);
                vertices.push(-profileRadius * cosTheta); vertices.push(profileY); vertices.push(profileRadius * sinTheta);
                normal.set(-profileRadius * cosTheta, normalY, profileRadius * sinTheta).normalize();
                normals.push(normal.x); normals.push(normal.y); normals.push(normal.z);
                uvs.push(u + uOffset); uvs.push(v);
            }
            if (iy > 0) {
                const prevRow = (iy - 1) * verticesPerRow;
                for (let ix = 0; ix < radialSegments; ix++) {
                    const i1 = prevRow + ix, i2 = prevRow + ix + 1;
                    const i3 = iy * verticesPerRow + ix, i4 = iy * verticesPerRow + ix + 1;
                    indices.push(i1); indices.push(i2); indices.push(i3);
                    indices.push(i2); indices.push(i4); indices.push(i3);
                }
            }
        }
        this.setIndex(indices);
        this.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        this.setAttribute("normal", new Float32BufferAttribute(normals, 3));
        this.setAttribute("uv", new Float32BufferAttribute(uvs, 2));
    }
}
