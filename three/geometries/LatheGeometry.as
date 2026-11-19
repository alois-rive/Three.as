// three.js LatheGeometry: `points` (x radius, y height) revolved around Y.

import { BufferGeometry } from "../core/BufferGeometry";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber, jnum, jint, jget, jhas, jat, jitems, asNum } from "../core/JSON";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";

export class LatheGeometryParameters {
    points: Array<Vector2> = [];
    segments: i32 = 12;
    phiStart: f64 = 0;
    phiLength: f64 = Math.PI * 2;
}

export class LatheGeometry extends BufferGeometry {
    parameters: LatheGeometryParameters = new LatheGeometryParameters();

    /// `points` as three.js writes Vector2s: { x, y } objects.
    override toJSONParameters(data: Dynamic, meta: JSONMeta?): bool {
        const p = this.parameters;
        const points = Dynamic.newTable();
        for (let i = 0; i < p.points.length; i++) {
            const point = Dynamic.newTable();
            setNumber(point, "x", p.points[i].x);
            setNumber(point, "y", p.points[i].y);
            points.push(point);
        }
        data.set("points", points);
        setNumber(data, "segments", <f64>p.segments);
        setNumber(data, "phiStart", p.phiStart);
        setNumber(data, "phiLength", p.phiLength);
        return true;
    }

    /// Points may be { x, y } objects or [x, y] pairs.
    static fromJSON(data: Dynamic?): LatheGeometry {
        const points: Array<Vector2> = [];
        const items = jitems(jget(data, "points"));
        for (let i = 0; i < items.length; i++) {
            const item = items[i];
            if (jhas(item, "x")) points.push(new Vector2(jnum(item, "x", 0), jnum(item, "y", 0)));
            else points.push(new Vector2(asNum(jat(item, 0), 0), asNum(jat(item, 1), 0)));
        }
        return new LatheGeometry(points, jint(data, "segments", 12), jnum(data, "phiStart", 0),
            jnum(data, "phiLength", Math.PI * 2));
    }

    constructor(points: Array<Vector2> = [new Vector2(0, -0.5), new Vector2(0.5, 0), new Vector2(0, 0.5)],
                segments: i32 = 12, phiStart: f64 = 0, phiLength: f64 = Math.PI * 2) {
        super();
        this.type = "LatheGeometry";
        const p = this.parameters;
        p.points = points; p.segments = segments; p.phiStart = phiStart; p.phiLength = phiLength;
        segments = max<i32>(1, segments);
        phiLength = Math.max(0, Math.min(Math.PI * 2, phiLength));
        const n = points.length;
        if (n < 2) return;

        // Profile normals, averaged at inner points.
        const initNormals: Array<f64> = [];
        const normal = new Vector3(), curNormal = new Vector3(), prevNormal = new Vector3();
        for (let j = 0; j <= n - 1; j++) {
            if (j == 0) {
                const dx = points[j + 1].x - points[j].x, dy = points[j + 1].y - points[j].y;
                normal.set(dy, -dx, 0);
                prevNormal.copy(normal);
                normal.normalize();
                initNormals.push(normal.x); initNormals.push(normal.y); initNormals.push(normal.z);
            } else if (j == n - 1) {
                initNormals.push(prevNormal.x); initNormals.push(prevNormal.y); initNormals.push(prevNormal.z);
            } else {
                const dx = points[j + 1].x - points[j].x, dy = points[j + 1].y - points[j].y;
                normal.set(dy, -dx, 0);
                curNormal.copy(normal);
                normal.add(prevNormal).normalize();
                initNormals.push(normal.x); initNormals.push(normal.y); initNormals.push(normal.z);
                prevNormal.copy(curNormal);
            }
        }

        const indices: Array<i32> = [];
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];
        const inverseSegments = 1.0 / <f64>segments;
        for (let i = 0; i <= segments; i++) {
            const phi = phiStart + <f64>i * inverseSegments * phiLength;
            const sin = Math.sin(phi), cos = Math.cos(phi);
            for (let j = 0; j <= n - 1; j++) {
                vertices.push(points[j].x * sin); vertices.push(points[j].y); vertices.push(points[j].x * cos);
                uvs.push(<f64>i / <f64>segments);
                uvs.push(<f64>j / <f64>(n - 1));
                normals.push(initNormals[3 * j] * sin);
                normals.push(initNormals[3 * j + 1]);
                normals.push(initNormals[3 * j] * cos);
            }
        }
        for (let i = 0; i < segments; i++) {
            for (let j = 0; j < n - 1; j++) {
                const base = j + i * n;
                const a = base, b = base + n, c = base + n + 1, d = base + 1;
                indices.push(a); indices.push(b); indices.push(d);
                indices.push(c); indices.push(d); indices.push(b);
            }
        }
        this.setIndex(indices);
        this.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        this.setAttribute("normal", new Float32BufferAttribute(normals, 3));
        this.setAttribute("uv", new Float32BufferAttribute(uvs, 2));
    }
}
