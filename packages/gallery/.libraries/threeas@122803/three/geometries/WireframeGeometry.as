// three.js WireframeGeometry: every distinct triangle edge of `geometry`
// as line segments. Draw it with LineSegments.

import { BufferGeometry, GeometryGroup } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { Vector3 } from "../math/Vector3";

export class WireframeGeometryParameters {
    geometry: BufferGeometry? = null;
}

export class WireframeGeometry extends BufferGeometry {
    parameters: WireframeGeometryParameters = new WireframeGeometryParameters();

    constructor(geometry: BufferGeometry? = null) {
        super();
        this.type = "WireframeGeometry";
        this.parameters.geometry = geometry;
        if (geometry == null) return;
        const position = geometry.getAttribute("position");
        if (position == null) return;

        const vertices: Array<f64> = [];
        const edges = new Set<string>();
        const start = new Vector3(), end = new Vector3();
        const index = geometry.index;
        if (index != null) {
            let groups = geometry.groups;
            if (groups.length == 0) groups = [new GeometryGroup(0, index.count, 0)];
            for (let o = 0; o < groups.length; o++) {
                const first = groups[o].start, count = groups[o].count;
                for (let i = first, l = first + count; i + 2 < l; i += 3) {
                    for (let j = 0; j < 3; j++) {
                        const i1 = index.getX(i + j), i2 = index.getX(i + (j + 1) % 3);
                        start.set(position.getX(i1), position.getY(i1), position.getZ(i1));
                        end.set(position.getX(i2), position.getY(i2), position.getZ(i2));
                        addEdge(start, end, edges, vertices);
                    }
                }
            }
        } else {
            for (let i = 0, l = position.count / 3; i < l; i++) {
                for (let j = 0; j < 3; j++) {
                    const i1 = 3 * i + j, i2 = 3 * i + (j + 1) % 3;
                    start.set(position.getX(i1), position.getY(i1), position.getZ(i1));
                    end.set(position.getX(i2), position.getY(i2), position.getZ(i2));
                    addEdge(start, end, edges, vertices);
                }
            }
        }
        this.setAttribute("position", new Float32BufferAttribute(vertices, 3));
    }
}

function key(v: Vector3): string {
    return v.x.toString() + "," + v.y.toString() + "," + v.z.toString();
}

function addEdge(start: Vector3, end: Vector3, edges: Set<string>, vertices: Array<f64>): void {
    const a = key(start), b = key(end);
    const hash1 = a + "-" + b, hash2 = b + "-" + a;
    if (edges.has(hash1) || edges.has(hash2)) return;
    edges.add(hash1);
    edges.add(hash2);
    vertices.push(start.x); vertices.push(start.y); vertices.push(start.z);
    vertices.push(end.x); vertices.push(end.y); vertices.push(end.z);
}
