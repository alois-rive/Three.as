// three.js examples/jsm/geometries/ParametricGeometry.js: a surface from
// func(u, v, target) over [0, 1]^2, `slices` x `stacks`. AnimaScript
// functions cannot close over variables: pass a top-level function (see
// ParametricFunctions).

import { BufferGeometry } from "../../core/BufferGeometry";
import { Float32BufferAttribute } from "../../core/BufferAttribute";
import { Vector3 } from "../../math/Vector3";

export type ParametricFunction = (u: f64, v: f64, target: Vector3) => void;

function defaultFunction(u: f64, v: f64, target: Vector3): void {
    target.set(u, v, Math.cos(u) * Math.sin(v));
}

export class ParametricGeometry extends BufferGeometry {
    func: ParametricFunction;
    slices: i32;
    stacks: i32;

    constructor(func: ParametricFunction = defaultFunction, slices: i32 = 8, stacks: i32 = 8) {
        super();
        this.type = "ParametricGeometry";
        this.func = func;
        this.slices = slices;
        this.stacks = stacks;
        const indices: Array<i32> = [];
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];
        const EPS = 0.00001;
        const normal = new Vector3(), p0 = new Vector3(), p1 = new Vector3(), pu = new Vector3(), pv = new Vector3();
        const sliceCount = slices + 1;
        for (let i = 0; i <= stacks; i++) {
            const v = <f64>i / <f64>stacks;
            for (let j = 0; j <= slices; j++) {
                const u = <f64>j / <f64>slices;
                func(u, v, p0);
                vertices.push(p0.x); vertices.push(p0.y); vertices.push(p0.z);
                // Tangents by finite differences.
                if (u - EPS >= 0) { func(u - EPS, v, p1); pu.subVectors(p0, p1); }
                else { func(u + EPS, v, p1); pu.subVectors(p1, p0); }
                if (v - EPS >= 0) { func(u, v - EPS, p1); pv.subVectors(p0, p1); }
                else { func(u, v + EPS, p1); pv.subVectors(p1, p0); }
                normal.crossVectors(pu, pv).normalize();
                normals.push(normal.x); normals.push(normal.y); normals.push(normal.z);
                uvs.push(u); uvs.push(v);
            }
        }
        for (let i = 0; i < stacks; i++) {
            for (let j = 0; j < slices; j++) {
                const a = i * sliceCount + j, b = i * sliceCount + j + 1;
                const c = (i + 1) * sliceCount + j + 1, d = (i + 1) * sliceCount + j;
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
