// three.js CylinderGeometry: along Y, centred. Groups: 0 the side, 1 the
// top cap, 2 the bottom cap.

import { BufferGeometry } from "../core/BufferGeometry";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber, setBool, jnum, jint, jbool } from "../core/JSON";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { Vector3 } from "../math/Vector3";

export class CylinderGeometryParameters {
    radiusTop: f64 = 1;
    radiusBottom: f64 = 1;
    height: f64 = 1;
    radialSegments: i32 = 32;
    heightSegments: i32 = 1;
    openEnded: bool = false;
    thetaStart: f64 = 0;
    thetaLength: f64 = Math.PI * 2;
}

export class CylinderGeometry extends BufferGeometry {
    parameters: CylinderGeometryParameters = new CylinderGeometryParameters();

    override toJSONParameters(data: Dynamic, meta: JSONMeta?): bool {
        const p = this.parameters;
        setNumber(data, "radiusTop", p.radiusTop);
        setNumber(data, "radiusBottom", p.radiusBottom);
        setNumber(data, "height", p.height);
        setNumber(data, "radialSegments", <f64>p.radialSegments);
        setNumber(data, "heightSegments", <f64>p.heightSegments);
        setBool(data, "openEnded", p.openEnded);
        setNumber(data, "thetaStart", p.thetaStart);
        setNumber(data, "thetaLength", p.thetaLength);
        return true;
    }

    static fromJSON(data: Dynamic?): CylinderGeometry {
        return new CylinderGeometry(jnum(data, "radiusTop", 1), jnum(data, "radiusBottom", 1),
            jnum(data, "height", 1), jint(data, "radialSegments", 32), jint(data, "heightSegments", 1),
            jbool(data, "openEnded", false), jnum(data, "thetaStart", 0), jnum(data, "thetaLength", Math.PI * 2));
    }

    private indices: Array<i32> = [];
    private vertices: Array<f64> = [];
    private normals: Array<f64> = [];
    private uvs: Array<f64> = [];
    private vertexIndex: i32 = 0;
    private groupStart: i32 = 0;

    constructor(radiusTop: f64 = 1, radiusBottom: f64 = 1, height: f64 = 1, radialSegments: i32 = 32,
                heightSegments: i32 = 1, openEnded: bool = false, thetaStart: f64 = 0,
                thetaLength: f64 = Math.PI * 2) {
        super();
        this.type = "CylinderGeometry";
        const p = this.parameters;
        p.radiusTop = radiusTop; p.radiusBottom = radiusBottom; p.height = height;
        p.radialSegments = max<i32>(1, radialSegments); p.heightSegments = max<i32>(1, heightSegments);
        p.openEnded = openEnded; p.thetaStart = thetaStart; p.thetaLength = thetaLength;

        this.generateTorso();
        if (!openEnded) {
            if (radiusTop > 0) this.generateCap(true);
            if (radiusBottom > 0) this.generateCap(false);
        }
        this.setIndex(this.indices);
        this.setAttribute("position", new Float32BufferAttribute(this.vertices, 3));
        this.setAttribute("normal", new Float32BufferAttribute(this.normals, 3));
        this.setAttribute("uv", new Float32BufferAttribute(this.uvs, 2));
        this.indices = []; this.vertices = []; this.normals = []; this.uvs = [];
    }

    private generateTorso(): void {
        const p = this.parameters;
        const halfHeight = p.height / 2;
        const slope = (p.radiusBottom - p.radiusTop) / p.height;
        const rows: Array<Array<i32>> = [];
        let groupCount = 0;
        for (let y = 0; y <= p.heightSegments; y++) {
            const row: Array<i32> = [];
            const v = <f64>y / <f64>p.heightSegments;
            const radius = v * (p.radiusBottom - p.radiusTop) + p.radiusTop;
            for (let x = 0; x <= p.radialSegments; x++) {
                const u = <f64>x / <f64>p.radialSegments;
                const theta = u * p.thetaLength + p.thetaStart;
                const sinTheta = Math.sin(theta), cosTheta = Math.cos(theta);
                this.vertices.push(radius * sinTheta);
                this.vertices.push(-v * p.height + halfHeight);
                this.vertices.push(radius * cosTheta);
                _n.set(sinTheta, slope, cosTheta).normalize();
                this.normals.push(_n.x); this.normals.push(_n.y); this.normals.push(_n.z);
                this.uvs.push(u); this.uvs.push(1 - v);
                row.push(this.vertexIndex++);
            }
            rows.push(row);
        }
        for (let x = 0; x < p.radialSegments; x++) {
            for (let y = 0; y < p.heightSegments; y++) {
                const a = rows[y][x], b = rows[y + 1][x], c = rows[y + 1][x + 1], d = rows[y][x + 1];
                if (p.radiusTop > 0 || y != 0) {
                    this.indices.push(a); this.indices.push(b); this.indices.push(d);
                    groupCount += 3;
                }
                if (p.radiusBottom > 0 || y != p.heightSegments - 1) {
                    this.indices.push(b); this.indices.push(c); this.indices.push(d);
                    groupCount += 3;
                }
            }
        }
        this.addGroup(this.groupStart, groupCount, 0);
        this.groupStart += groupCount;
    }

    private generateCap(top: bool): void {
        const p = this.parameters;
        const halfHeight = p.height / 2;
        const centerIndexStart = this.vertexIndex;
        const radius = top ? p.radiusTop : p.radiusBottom;
        const sign: f64 = top ? 1 : -1;
        let groupCount = 0;
        for (let x = 1; x <= p.radialSegments; x++) {
            this.vertices.push(0); this.vertices.push(halfHeight * sign); this.vertices.push(0);
            this.normals.push(0); this.normals.push(sign); this.normals.push(0);
            this.uvs.push(0.5); this.uvs.push(0.5);
            this.vertexIndex++;
        }
        const centerIndexEnd = this.vertexIndex;
        for (let x = 0; x <= p.radialSegments; x++) {
            const u = <f64>x / <f64>p.radialSegments;
            const theta = u * p.thetaLength + p.thetaStart;
            const cosTheta = Math.cos(theta), sinTheta = Math.sin(theta);
            this.vertices.push(radius * sinTheta); this.vertices.push(halfHeight * sign); this.vertices.push(radius * cosTheta);
            this.normals.push(0); this.normals.push(sign); this.normals.push(0);
            this.uvs.push(cosTheta * 0.5 + 0.5);
            this.uvs.push(sinTheta * 0.5 * sign + 0.5);
            this.vertexIndex++;
        }
        for (let x = 0; x < p.radialSegments; x++) {
            const c = centerIndexStart + x;
            const i = centerIndexEnd + x;
            if (top) { this.indices.push(i); this.indices.push(i + 1); this.indices.push(c); }
            else { this.indices.push(i + 1); this.indices.push(i); this.indices.push(c); }
            groupCount += 3;
        }
        this.addGroup(this.groupStart, groupCount, top ? 1 : 2);
        this.groupStart += groupCount;
    }
}

const _n: Vector3 = new Vector3();
