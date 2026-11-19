// three.js SphereGeometry.

import { BufferGeometry } from "../core/BufferGeometry";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber, jnum, jint } from "../core/JSON";
import { Float32BufferAttribute } from "../core/BufferAttribute";

export class SphereGeometryParameters {
    radius: f64 = 1;
    widthSegments: i32 = 32;
    heightSegments: i32 = 16;
    phiStart: f64 = 0;
    phiLength: f64 = Math.PI * 2;
    thetaStart: f64 = 0;
    thetaLength: f64 = Math.PI;
}

export class SphereGeometry extends BufferGeometry {
    parameters: SphereGeometryParameters = new SphereGeometryParameters();

    override toJSONParameters(data: Dynamic, meta: JSONMeta?): bool {
        const p = this.parameters;
        setNumber(data, "radius", p.radius);
        setNumber(data, "widthSegments", <f64>p.widthSegments);
        setNumber(data, "heightSegments", <f64>p.heightSegments);
        setNumber(data, "phiStart", p.phiStart);
        setNumber(data, "phiLength", p.phiLength);
        setNumber(data, "thetaStart", p.thetaStart);
        setNumber(data, "thetaLength", p.thetaLength);
        return true;
    }

    static fromJSON(data: Dynamic?): SphereGeometry {
        return new SphereGeometry(jnum(data, "radius", 1), jint(data, "widthSegments", 32),
            jint(data, "heightSegments", 16), jnum(data, "phiStart", 0), jnum(data, "phiLength", Math.PI * 2),
            jnum(data, "thetaStart", 0), jnum(data, "thetaLength", Math.PI));
    }

    constructor(radius: f64 = 1, widthSegments: i32 = 32, heightSegments: i32 = 16,
                phiStart: f64 = 0, phiLength: f64 = Math.PI * 2,
                thetaStart: f64 = 0, thetaLength: f64 = Math.PI) {
        super();
        this.type = "SphereGeometry";
        const p = this.parameters;
        p.radius = radius; p.widthSegments = widthSegments; p.heightSegments = heightSegments;
        p.phiStart = phiStart; p.phiLength = phiLength; p.thetaStart = thetaStart; p.thetaLength = thetaLength;

        const ws = max<i32>(3, widthSegments);
        const hs = max<i32>(2, heightSegments);
        const thetaEnd = Math.min(thetaStart + thetaLength, Math.PI);

        let index = 0;
        const grid: Array<Array<i32>> = [];
        const indices: Array<i32> = [];
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];

        for (let iy = 0; iy <= hs; iy++) {
            const row: Array<i32> = [];
            const v = <f64>iy / <f64>hs;
            let uOffset: f64 = 0;
            if (iy == 0 && thetaStart == 0) uOffset = 0.5 / ws;
            else if (iy == hs && thetaEnd == Math.PI) uOffset = -0.5 / ws;
            for (let ix = 0; ix <= ws; ix++) {
                const u = <f64>ix / <f64>ws;
                const sinTheta = Math.sin(thetaStart + v * thetaLength);
                const x = -radius * Math.cos(phiStart + u * phiLength) * sinTheta;
                const y = radius * Math.cos(thetaStart + v * thetaLength);
                const z = radius * Math.sin(phiStart + u * phiLength) * sinTheta;
                vertices.push(x); vertices.push(y); vertices.push(z);
                const l = Math.sqrt(x * x + y * y + z * z);
                const k = l > 0 ? 1 / l : 0;
                normals.push(x * k); normals.push(y * k); normals.push(z * k);
                uvs.push(u + uOffset);
                uvs.push(1 - v);
                row.push(index++);
            }
            grid.push(row);
        }

        for (let iy = 0; iy < hs; iy++) {
            for (let ix = 0; ix < ws; ix++) {
                const a = grid[iy][ix + 1];
                const b = grid[iy][ix];
                const c = grid[iy + 1][ix];
                const d = grid[iy + 1][ix + 1];
                if (iy != 0 || thetaStart > 0) { indices.push(a); indices.push(b); indices.push(d); }
                if (iy != hs - 1 || thetaEnd < Math.PI) { indices.push(b); indices.push(c); indices.push(d); }
            }
        }

        this.setIndex(indices);
        this.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        this.setAttribute("normal", new Float32BufferAttribute(normals, 3));
        this.setAttribute("uv", new Float32BufferAttribute(uvs, 2));
    }
}
