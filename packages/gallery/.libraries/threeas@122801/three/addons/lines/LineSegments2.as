// three.js examples/jsm/lines/LineSegments2.js and Line2.js: meshes of
// wide line geometry. computeLineDistances() fills the distances dashes
// use. Raycasting against wide lines is not ported.

import { Mesh } from "../../objects/Mesh";
import { BufferAttribute } from "../../core/BufferAttribute";
import { Vector3 } from "../../math/Vector3";
import { LineSegmentsGeometry } from "./LineSegmentsGeometry";
import { LineGeometry } from "./LineGeometry";
import { LineMaterial } from "./LineMaterial";

const _start = new Vector3();
const _end = new Vector3();

export class LineSegments2 extends Mesh {
    readonly isLineSegments2: bool = true;

    constructor(geometry: LineSegmentsGeometry = new LineSegmentsGeometry(), material: LineMaterial = new LineMaterial()) {
        super(geometry, material);
        this.type = "LineSegments2";
    }

    computeLineDistances(): LineSegments2 {
        const g = this.geometry;
        const s = g.getAttribute("instanceStart");
        const e = g.getAttribute("instanceEnd");
        if (s == null || e == null) return this;
        const n = s.count;
        const ds = new Float32Array(n), de = new Float32Array(n);
        let total: f64 = 0;
        for (let i = 0; i < n; i++) {
            _start.fromBufferAttribute(s, i);
            _end.fromBufferAttribute(e, i);
            ds[i] = <f32>total;
            total += _start.distanceTo(_end);
            de[i] = <f32>total;
        }
        g.setAttribute("instanceDistanceStart", new BufferAttribute(ds, 1));
        g.setAttribute("instanceDistanceEnd", new BufferAttribute(de, 1));
        return this;
    }
}

export class Line2 extends LineSegments2 {
    readonly isLine2: bool = true;

    constructor(geometry: LineGeometry = new LineGeometry(), material: LineMaterial = new LineMaterial()) {
        super(geometry, material);
        this.type = "Line2";
    }
}
