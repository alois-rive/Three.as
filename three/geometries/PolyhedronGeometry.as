// three.js PolyhedronGeometry: faces of a polyhedron projected onto a
// sphere of `radius`, each subdivided `detail` times. Non-indexed; flat
// normals at detail 0, smooth otherwise. Icosahedron, Octahedron,
// Tetrahedron and Dodecahedron are presets.

import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";

export class PolyhedronGeometryParameters {
    vertices: Array<f64> = [];
    indices: Array<i32> = [];
    radius: f64 = 1;
    detail: i32 = 0;
}

export class PolyhedronGeometry extends BufferGeometry {
    parameters: PolyhedronGeometryParameters = new PolyhedronGeometryParameters();

    private vertexBuffer: Array<f64> = [];
    private uvBuffer: Array<f64> = [];

    constructor(vertices: Array<f64> = [], indices: Array<i32> = [], radius: f64 = 1, detail: i32 = 0) {
        super();
        this.type = "PolyhedronGeometry";
        const p = this.parameters;
        p.vertices = vertices; p.indices = indices; p.radius = radius; p.detail = detail;

        this.subdivide(vertices, indices, max<i32>(0, detail));
        this.applyRadius(radius);
        this.generateUVs();

        this.setAttribute("position", new Float32BufferAttribute(this.vertexBuffer, 3));
        this.setAttribute("normal", new Float32BufferAttribute(this.vertexBuffer, 3));
        this.setAttribute("uv", new Float32BufferAttribute(this.uvBuffer, 2));
        if (detail == 0) this.computeVertexNormals();
        else this.normalizeNormals();
        this.vertexBuffer = [];
        this.uvBuffer = [];
    }

    private subdivide(vertices: Array<f64>, indices: Array<i32>, detail: i32): void {
        const a = new Vector3(), b = new Vector3(), c = new Vector3();
        for (let i = 0; i + 2 < indices.length; i += 3) {
            a.fromArray(vertices, indices[i] * 3);
            b.fromArray(vertices, indices[i + 1] * 3);
            c.fromArray(vertices, indices[i + 2] * 3);
            this.subdivideFace(a, b, c, detail);
        }
    }

    private subdivideFace(a: Vector3, b: Vector3, c: Vector3, detail: i32): void {
        const cols = detail + 1;
        const v: Array<Array<Vector3>> = [];
        for (let i = 0; i <= cols; i++) {
            const row: Array<Vector3> = [];
            const aj = a.clone().lerp(c, <f64>i / <f64>cols);
            const bj = b.clone().lerp(c, <f64>i / <f64>cols);
            const rows = cols - i;
            for (let j = 0; j <= rows; j++) {
                if (j == 0 && i == cols) row.push(aj);
                else row.push(aj.clone().lerp(bj, <f64>j / <f64>rows));
            }
            v.push(row);
        }
        for (let i = 0; i < cols; i++) {
            for (let j = 0; j < 2 * (cols - i) - 1; j++) {
                const k = j / 2;
                if (j % 2 == 0) {
                    this.pushVertex(v[i][k + 1]);
                    this.pushVertex(v[i + 1][k]);
                    this.pushVertex(v[i][k]);
                } else {
                    this.pushVertex(v[i][k + 1]);
                    this.pushVertex(v[i + 1][k + 1]);
                    this.pushVertex(v[i + 1][k]);
                }
            }
        }
    }

    private pushVertex(v: Vector3): void {
        this.vertexBuffer.push(v.x); this.vertexBuffer.push(v.y); this.vertexBuffer.push(v.z);
    }

    private applyRadius(radius: f64): void {
        const vb = this.vertexBuffer;
        const v = new Vector3();
        for (let i = 0; i < vb.length; i += 3) {
            v.set(vb[i], vb[i + 1], vb[i + 2]).normalize().multiplyScalar(radius);
            vb[i] = v.x; vb[i + 1] = v.y; vb[i + 2] = v.z;
        }
    }

    private generateUVs(): void {
        const vb = this.vertexBuffer;
        const v = new Vector3();
        for (let i = 0; i < vb.length; i += 3) {
            v.set(vb[i], vb[i + 1], vb[i + 2]);
            const u = azimuth(v) / 2 / Math.PI + 0.5;
            const w = inclination(v) / Math.PI + 0.5;
            this.uvBuffer.push(u);
            this.uvBuffer.push(1 - w);
        }
        this.correctUVs();
        this.correctSeam();
    }

    private correctSeam(): void {
        const uv = this.uvBuffer;
        for (let i = 0; i + 4 < uv.length; i += 6) {
            const x0 = uv[i], x1 = uv[i + 2], x2 = uv[i + 4];
            const mx = Math.max(x0, Math.max(x1, x2));
            const mn = Math.min(x0, Math.min(x1, x2));
            if (mx > 0.9 && mn < 0.1) {
                if (x0 < 0.2) uv[i] += 1;
                if (x1 < 0.2) uv[i + 2] += 1;
                if (x2 < 0.2) uv[i + 4] += 1;
            }
        }
    }

    private correctUVs(): void {
        const vb = this.vertexBuffer;
        const a = new Vector3(), b = new Vector3(), c = new Vector3(), centroid = new Vector3();
        const uvA = new Vector2(), uvB = new Vector2(), uvC = new Vector2();
        for (let i = 0, j = 0; i < vb.length; i += 9, j += 6) {
            a.set(vb[i], vb[i + 1], vb[i + 2]);
            b.set(vb[i + 3], vb[i + 4], vb[i + 5]);
            c.set(vb[i + 6], vb[i + 7], vb[i + 8]);
            uvA.set(this.uvBuffer[j], this.uvBuffer[j + 1]);
            uvB.set(this.uvBuffer[j + 2], this.uvBuffer[j + 3]);
            uvC.set(this.uvBuffer[j + 4], this.uvBuffer[j + 5]);
            centroid.copy(a).add(b).add(c).divideScalar(3);
            const azi = azimuth(centroid);
            this.correctUV(uvA, j, a, azi);
            this.correctUV(uvB, j + 2, b, azi);
            this.correctUV(uvC, j + 4, c, azi);
        }
    }

    private correctUV(uv: Vector2, stride: i32, vector: Vector3, azi: f64): void {
        if (azi < 0 && uv.x == 1) this.uvBuffer[stride] = uv.x - 1;
        if (vector.x == 0 && vector.z == 0) this.uvBuffer[stride] = azi / 2 / Math.PI + 0.5;
    }
}

function azimuth(v: Vector3): f64 { return Math.atan2(v.z, -v.x); }

function inclination(v: Vector3): f64 { return Math.atan2(-v.y, Math.sqrt(v.x * v.x + v.z * v.z)); }

const T: f64 = (1 + Math.sqrt(5)) / 2;
const R: f64 = 1 / T;

export class IcosahedronGeometry extends PolyhedronGeometry {
    constructor(radius: f64 = 1, detail: i32 = 0) {
        super([
            -1, T, 0, 1, T, 0, -1, -T, 0, 1, -T, 0,
            0, -1, T, 0, 1, T, 0, -1, -T, 0, 1, -T,
            T, 0, -1, T, 0, 1, -T, 0, -1, -T, 0, 1,
        ], [
            0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
            1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
            3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
            4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
        ], radius, detail);
        this.type = "IcosahedronGeometry";
    }
}

export class OctahedronGeometry extends PolyhedronGeometry {
    constructor(radius: f64 = 1, detail: i32 = 0) {
        super([1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1],
            [0, 2, 4, 0, 4, 3, 0, 3, 5, 0, 5, 2, 1, 2, 5, 1, 5, 3, 1, 3, 4, 1, 4, 2], radius, detail);
        this.type = "OctahedronGeometry";
    }
}

export class TetrahedronGeometry extends PolyhedronGeometry {
    constructor(radius: f64 = 1, detail: i32 = 0) {
        super([1, 1, 1, -1, -1, 1, -1, 1, -1, 1, -1, -1], [2, 1, 0, 0, 3, 2, 1, 3, 0, 2, 3, 1], radius, detail);
        this.type = "TetrahedronGeometry";
    }
}

export class DodecahedronGeometry extends PolyhedronGeometry {
    constructor(radius: f64 = 1, detail: i32 = 0) {
        super([
            -1, -1, -1, -1, -1, 1, -1, 1, -1, -1, 1, 1,
            1, -1, -1, 1, -1, 1, 1, 1, -1, 1, 1, 1,
            0, -R, -T, 0, -R, T, 0, R, -T, 0, R, T,
            -R, -T, 0, -R, T, 0, R, -T, 0, R, T, 0,
            -T, 0, -R, T, 0, -R, -T, 0, R, T, 0, R,
        ], [
            3, 11, 7, 3, 7, 15, 3, 15, 13, 7, 19, 17, 7, 17, 6, 7, 6, 15,
            17, 4, 8, 17, 8, 10, 17, 10, 6, 8, 0, 16, 8, 16, 2, 8, 2, 10,
            0, 12, 1, 0, 1, 18, 0, 18, 16, 6, 10, 2, 6, 2, 13, 6, 13, 15,
            2, 16, 18, 2, 18, 3, 2, 3, 13, 18, 1, 9, 18, 9, 11, 18, 11, 3,
            4, 14, 12, 4, 12, 0, 4, 0, 8, 11, 9, 5, 11, 5, 19, 11, 19, 7,
            19, 5, 14, 19, 14, 4, 19, 4, 17, 1, 12, 14, 1, 14, 5, 1, 5, 9,
        ], radius, detail);
        this.type = "DodecahedronGeometry";
    }
}
