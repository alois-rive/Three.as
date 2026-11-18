// three.js examples/jsm/lines/LineSegmentsGeometry.js: segments for wide
// lines. A small quad (with cap rows) is drawn once per segment; the
// segments are the instanceStart / instanceEnd attributes
// (instanceColorStart / End with setColors).

import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute, Float32BufferAttribute } from "../../core/BufferAttribute";
import { Box3 } from "../../math/Box3";
import { Sphere } from "../../math/Sphere";
import { Vector3 } from "../../math/Vector3";
import { Mesh } from "../../objects/Mesh";
import { LineSegments } from "../../objects/Line";
import { WireframeGeometry } from "../../geometries/WireframeGeometry";
import { EdgesGeometry } from "../../geometries/EdgesGeometry";

const _box = new Box3();
const _vector = new Vector3();

export class LineSegmentsGeometry extends BufferGeometry {
    readonly isLineSegmentsGeometry: bool = true;

    constructor() {
        super();
        this.type = "LineSegmentsGeometry";
        this.setIndex([0, 2, 1, 2, 3, 1, 2, 4, 3, 4, 5, 3, 4, 6, 5, 6, 7, 5]);
        this.setAttribute("position", new Float32BufferAttribute([-1, 2, 0, 1, 2, 0, -1, 1, 0, 1, 1, 0, -1, 0, 0, 1, 0, 0, -1, -1, 0, 1, -1, 0], 3));
        this.setAttribute("uv", new Float32BufferAttribute([-1, 2, 1, 2, -1, 1, 1, 1, -1, -1, 1, -1, -1, -2, 1, -2], 2));
    }

    /// Segment end points, six numbers a segment (x1 y1 z1 x2 y2 z2).
    setPositions(array: Array<f64>): LineSegmentsGeometry {
        const n = array.length / 6;
        const s = new Float32Array(n * 3), e = new Float32Array(n * 3);
        for (let i = 0; i < n; i++) {
            for (let k = 0; k < 3; k++) {
                s[i * 3 + k] = <f32>array[i * 6 + k];
                e[i * 3 + k] = <f32>array[i * 6 + 3 + k];
            }
        }
        this.setAttribute("instanceStart", new BufferAttribute(s, 3));
        this.setAttribute("instanceEnd", new BufferAttribute(e, 3));
        this.deleteAttribute("instanceDistanceStart");
        this.deleteAttribute("instanceDistanceEnd");
        this.computeBoundingBox();
        this.computeBoundingSphere();
        return this;
    }

    /// Segment end colours, six numbers a segment (rgb rgb, linear).
    setColors(array: Array<f64>): LineSegmentsGeometry {
        const n = array.length / 6;
        const s = new Float32Array(n * 3), e = new Float32Array(n * 3);
        for (let i = 0; i < n; i++) {
            for (let k = 0; k < 3; k++) {
                s[i * 3 + k] = <f32>array[i * 6 + k];
                e[i * 3 + k] = <f32>array[i * 6 + 3 + k];
            }
        }
        this.setAttribute("instanceColorStart", new BufferAttribute(s, 3));
        this.setAttribute("instanceColorEnd", new BufferAttribute(e, 3));
        return this;
    }

    fromWireframeGeometry(geometry: WireframeGeometry): LineSegmentsGeometry {
        return this.setPositions(arrayOf(geometry.getAttribute("position")));
    }

    fromEdgesGeometry(geometry: EdgesGeometry): LineSegmentsGeometry {
        return this.setPositions(arrayOf(geometry.getAttribute("position")));
    }

    fromMesh(mesh: Mesh): LineSegmentsGeometry {
        return this.fromWireframeGeometry(new WireframeGeometry(mesh.geometry));
    }

    fromLineSegments(lineSegments: LineSegments): LineSegmentsGeometry {
        const g = lineSegments.geometry;
        return this.setPositions(arrayOf(g.getAttribute("position")));
    }

    override computeBoundingBox(): void {
        const s = this.getAttribute("instanceStart");
        const e = this.getAttribute("instanceEnd");
        const box = this.boundingBox != null ? this.boundingBox! : new Box3();
        box.makeEmpty();
        if (s != null && e != null) {
            for (let i = 0; i < s.count; i++) {
                box.expandByPoint(_vector.fromBufferAttribute(s, i));
                box.expandByPoint(_vector.fromBufferAttribute(e, i));
            }
        }
        this.boundingBox = box;
    }

    override computeBoundingSphere(): void {
        this.computeBoundingBox();
        const sphere = this.boundingSphere != null ? this.boundingSphere! : new Sphere();
        const box = this.boundingBox!;
        if (box.isEmpty()) {
            sphere.center.set(0, 0, 0);
            sphere.radius = -1;
        } else {
            box.getCenter(sphere.center);
            let r2: f64 = 0;
            const s = this.getAttribute("instanceStart")!;
            const e = this.getAttribute("instanceEnd")!;
            for (let i = 0; i < s.count; i++) {
                r2 = Math.max(r2, sphere.center.distanceToSquared(_vector.fromBufferAttribute(s, i)));
                r2 = Math.max(r2, sphere.center.distanceToSquared(_vector.fromBufferAttribute(e, i)));
            }
            sphere.radius = Math.sqrt(r2);
        }
        this.boundingSphere = sphere;
    }
}

function arrayOf(a: BufferAttribute?): Array<f64> {
    const out: Array<f64> = [];
    if (a == null) return out;
    for (let i = 0; i < a.array.length; i++) out.push(<f64>a.array[i]);
    return out;
}
