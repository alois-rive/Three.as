// three.js CircleGeometry: a disc (or sector) in the XY plane, facing +Z.

import { BufferGeometry } from "../core/BufferGeometry";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber, jnum, jint } from "../core/JSON";
import { Float32BufferAttribute } from "../core/BufferAttribute";

export class CircleGeometryParameters {
    radius: f64 = 1;
    segments: i32 = 32;
    thetaStart: f64 = 0;
    thetaLength: f64 = Math.PI * 2;
}

export class CircleGeometry extends BufferGeometry {
    parameters: CircleGeometryParameters = new CircleGeometryParameters();

    override toJSONParameters(data: Dynamic, meta: JSONMeta?): bool {
        const p = this.parameters;
        setNumber(data, "radius", p.radius);
        setNumber(data, "segments", <f64>p.segments);
        setNumber(data, "thetaStart", p.thetaStart);
        setNumber(data, "thetaLength", p.thetaLength);
        return true;
    }

    static fromJSON(data: Dynamic?): CircleGeometry {
        return new CircleGeometry(jnum(data, "radius", 1), jint(data, "segments", 32), jnum(data, "thetaStart", 0),
            jnum(data, "thetaLength", Math.PI * 2));
    }

    constructor(radius: f64 = 1, segments: i32 = 32, thetaStart: f64 = 0, thetaLength: f64 = Math.PI * 2) {
        super();
        this.type = "CircleGeometry";
        const p = this.parameters;
        p.radius = radius; p.segments = segments; p.thetaStart = thetaStart; p.thetaLength = thetaLength;
        const n = max<i32>(3, segments);

        const indices: Array<i32> = [];
        const vertices: Array<f64> = [0, 0, 0];
        const normals: Array<f64> = [0, 0, 1];
        const uvs: Array<f64> = [0.5, 0.5];
        for (let s = 0; s <= n; s++) {
            const segment = thetaStart + <f64>s / <f64>n * thetaLength;
            const x = radius * Math.cos(segment), y = radius * Math.sin(segment);
            vertices.push(x); vertices.push(y); vertices.push(0);
            normals.push(0); normals.push(0); normals.push(1);
            uvs.push((x / radius + 1) / 2);
            uvs.push((y / radius + 1) / 2);
        }
        for (let i = 1; i <= n; i++) {
            indices.push(i); indices.push(i + 1); indices.push(0);
        }
        this.setIndex(indices);
        this.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        this.setAttribute("normal", new Float32BufferAttribute(normals, 3));
        this.setAttribute("uv", new Float32BufferAttribute(uvs, 2));
    }
}
