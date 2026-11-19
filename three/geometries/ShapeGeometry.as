// three.js ShapeGeometry: flat triangulated shapes in the XY plane, facing
// +Z, one group per shape. Takes an array (three.js also takes one Shape:
// pass [shape]).

import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { Shape } from "../extras/core/Shape";
import { ShapeUtils } from "../extras/ShapeUtils";
import { Vector2 } from "../math/Vector2";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, jint, jarr, asStr } from "../core/JSON";

/// The uuids of `shapes`, writing each into `meta.shapes` (internal:
/// shape and extrude geometries).
export function shapeUuids(shapes: Array<Shape>, meta: JSONMeta?): Dynamic {
    const uuids = Dynamic.newTable();
    for (let i = 0; i < shapes.length; i++) {
        const shape = shapes[i];
        if (meta != null && !meta.shapes.has(shape.uuid)) meta.shapes.set(shape.uuid, shape.toJSON());
        uuids.push(Dynamic.fromString(shape.uuid));
    }
    return uuids;
}

/// The shapes `data.shapes` names (internal).
export function shapesByUuid(data: Dynamic?, shapes: Map<string, Shape>): Array<Shape> {
    const out: Array<Shape> = [];
    const uuids = jarr(data, "shapes");
    for (let i = 0; i < uuids.length; i++) {
        const uuid = asStr(uuids[i]);
        if (shapes.has(uuid)) out.push(shapes.get(uuid));
    }
    return out;
}

export class ShapeGeometry extends BufferGeometry {
    shapes: Array<Shape>;
    curveSegments: i32;

    /// { shapes: [uuids], curveSegments }; the shapes go to `meta.shapes`.
    override toJSONParameters(data: Dynamic, meta: JSONMeta?): bool {
        data.set("shapes", shapeUuids(this.shapes, meta));
        data.set("curveSegments", Dynamic.fromNumber(<f64>this.curveSegments));
        return true;
    }

    /// `shapes`: the document's shapes by uuid (ObjectLoader.parseShapes).
    static fromJSON(data: Dynamic?, shapes: Map<string, Shape>): ShapeGeometry {
        return new ShapeGeometry(shapesByUuid(data, shapes), jint(data, "curveSegments", 12));
    }

    constructor(shapes: Array<Shape> = [new Shape([new Vector2(0, 0.5), new Vector2(-0.5, -0.5), new Vector2(0.5, -0.5)])],
                curveSegments: i32 = 12) {
        super();
        this.type = "ShapeGeometry";
        this.shapes = shapes;
        this.curveSegments = curveSegments;
        const indices: Array<i32> = [];
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];
        let groupStart = 0;
        for (let s = 0; s < shapes.length; s++) {
            const indexOffset = vertices.length / 3;
            const points = shapes[s].extractPoints(curveSegments);
            let shapeVertices = points.shape;
            const shapeHoles = points.holes;
            if (!ShapeUtils.isClockWise(shapeVertices)) shapeVertices = shapeVertices.reverse();
            for (let i = 0; i < shapeHoles.length; i++) {
                if (ShapeUtils.isClockWise(shapeHoles[i])) shapeHoles[i] = shapeHoles[i].reverse();
            }
            const faces = ShapeUtils.triangulateShape(shapeVertices, shapeHoles);
            for (let i = 0; i < shapeHoles.length; i++) shapeVertices = shapeVertices.concat(shapeHoles[i]);
            for (let i = 0; i < shapeVertices.length; i++) {
                const v = shapeVertices[i];
                vertices.push(v.x); vertices.push(v.y); vertices.push(0);
                normals.push(0); normals.push(0); normals.push(1);
                uvs.push(v.x); uvs.push(v.y);
            }
            let groupCount = 0;
            for (let i = 0; i < faces.length; i++) {
                const face = faces[i];
                indices.push(face[0] + indexOffset);
                indices.push(face[1] + indexOffset);
                indices.push(face[2] + indexOffset);
                groupCount += 3;
            }
            this.addGroup(groupStart, groupCount, s);
            groupStart += groupCount;
        }
        this.setIndex(indices);
        this.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        this.setAttribute("normal", new Float32BufferAttribute(normals, 3));
        this.setAttribute("uv", new Float32BufferAttribute(uvs, 2));
    }
}
