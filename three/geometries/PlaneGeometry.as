// three.js PlaneGeometry: in the XY plane, facing +Z.

import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";

export class PlaneGeometryParameters {
    width: f64 = 1;
    height: f64 = 1;
    widthSegments: i32 = 1;
    heightSegments: i32 = 1;
}

export class PlaneGeometry extends BufferGeometry {
    parameters: PlaneGeometryParameters = new PlaneGeometryParameters();

    constructor(width: f64 = 1, height: f64 = 1, widthSegments: i32 = 1, heightSegments: i32 = 1) {
        super();
        this.type = "PlaneGeometry";
        const p = this.parameters;
        p.width = width; p.height = height; p.widthSegments = widthSegments; p.heightSegments = heightSegments;

        const widthHalf = width / 2, heightHalf = height / 2;
        const gridX = max<i32>(1, widthSegments), gridY = max<i32>(1, heightSegments);
        const gridX1 = gridX + 1, gridY1 = gridY + 1;
        const segmentWidth = width / gridX, segmentHeight = height / gridY;

        const indices: Array<i32> = [];
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];
        for (let iy = 0; iy < gridY1; iy++) {
            const y = <f64>iy * segmentHeight - heightHalf;
            for (let ix = 0; ix < gridX1; ix++) {
                const x = <f64>ix * segmentWidth - widthHalf;
                vertices.push(x); vertices.push(-y); vertices.push(0);
                normals.push(0); normals.push(0); normals.push(1);
                uvs.push(<f64>ix / <f64>gridX);
                uvs.push(1 - <f64>iy / <f64>gridY);
            }
        }
        for (let iy = 0; iy < gridY; iy++) {
            for (let ix = 0; ix < gridX; ix++) {
                const a = ix + gridX1 * iy;
                const b = ix + gridX1 * (iy + 1);
                const c = (ix + 1) + gridX1 * (iy + 1);
                const d = (ix + 1) + gridX1 * iy;
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
