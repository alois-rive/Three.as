// three.js examples/jsm/geometries/DecalGeometry.js: the part of a mesh
// inside a box (`position`, `orientation`, `size`), as its own geometry
// with uvs across the box, for decals.

import { BufferGeometry } from "../../core/BufferGeometry";
import { Float32BufferAttribute } from "../../core/BufferAttribute";
import { Mesh } from "../../objects/Mesh";
import { Vector3 } from "../../math/Vector3";
import { Euler } from "../../math/Euler";
import { Matrix4 } from "../../math/Matrix4";

export class DecalVertex {
    position: Vector3;
    normal: Vector3;

    constructor(position: Vector3, normal: Vector3) {
        this.position = position;
        this.normal = normal;
    }

    clone(): DecalVertex { return new DecalVertex(this.position.clone(), this.normal.clone()); }
}

export class DecalGeometry extends BufferGeometry {
    constructor(mesh: Mesh = new Mesh(), position: Vector3 = new Vector3(), orientation: Euler = new Euler(),
                size: Vector3 = new Vector3(1, 1, 1)) {
        super();
        this.type = "DecalGeometry";
        const projector = new Matrix4().makeRotationFromEuler(orientation);
        projector.setPosition(position.x, position.y, position.z);
        const projectorInverse = projector.clone().invert();
        // 1. The mesh's triangles in projector space.
        let verts: Array<DecalVertex> = [];
        const geometry = mesh.geometry;
        const positionAttribute = geometry.getAttribute("position");
        const normalAttribute = geometry.getAttribute("normal");
        if (positionAttribute == null || normalAttribute == null) return;
        mesh.updateMatrixWorld(true);
        const index = geometry.index;
        const count = index != null ? index.count : positionAttribute.count;
        for (let i = 0; i < count; i++) {
            const v = index != null ? <i32>index.array[i] : i;
            const p = new Vector3().fromBufferAttribute(positionAttribute, v).applyMatrix4(mesh.matrixWorld)
                .applyMatrix4(projectorInverse);
            const n = new Vector3().fromBufferAttribute(normalAttribute, v).transformDirection(mesh.matrixWorld);
            verts.push(new DecalVertex(p, n));
        }
        // 2. Clipped by the box's six planes.
        const planes: StaticArray<f64> = [1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1];
        for (let k = 0; k < 6; k++) {
            verts = clipGeometry(verts, new Vector3(planes[k * 3], planes[k * 3 + 1], planes[k * 3 + 2]), size);
        }
        // 3. Vertices, normals and uvs.
        const vertices: Array<f64> = [];
        const normals: Array<f64> = [];
        const uvs: Array<f64> = [];
        for (let i = 0; i < verts.length; i++) {
            const v = verts[i];
            uvs.push(0.5 + v.position.x / size.x);
            uvs.push(0.5 + v.position.y / size.y);
            v.position.applyMatrix4(projector);
            vertices.push(v.position.x); vertices.push(v.position.y); vertices.push(v.position.z);
            normals.push(v.normal.x); normals.push(v.normal.y); normals.push(v.normal.z);
        }
        this.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        this.setAttribute("normal", new Float32BufferAttribute(normals, 3));
        this.setAttribute("uv", new Float32BufferAttribute(uvs, 2));
    }
}

function clip(v0: DecalVertex, v1: DecalVertex, p: Vector3, s: f64): DecalVertex {
    const d0 = v0.position.dot(p) - s;
    const d1 = v1.position.dot(p) - s;
    const t = d0 / (d0 - d1);
    return new DecalVertex(
        new Vector3().lerpVectors(v0.position, v1.position, t),
        new Vector3().lerpVectors(v0.normal, v1.normal, t));
}

/// Keeps what is inside `plane` at half the box's extent along it (each
/// triangle is three consecutive vertices), as three.js's clipGeometry.
function clipGeometry(input: Array<DecalVertex>, plane: Vector3, size: Vector3): Array<DecalVertex> {
    const out: Array<DecalVertex> = [];
    const s = 0.5 * Math.abs(size.dot(plane));
    for (let i = 0; i + 2 < input.length; i += 3) {
        const a = input[i], b = input[i + 1], c = input[i + 2];
        const aOut = a.position.dot(plane) - s > 0;
        const bOut = b.position.dot(plane) - s > 0;
        const cOut = c.position.dot(plane) - s > 0;
        const total = (aOut ? 1 : 0) + (bOut ? 1 : 0) + (cOut ? 1 : 0);
        if (total == 0) {
            out.push(a); out.push(b); out.push(c);
        } else if (total == 1) {
            // One vertex out: a quad of the two inside and two cut points.
            let n1: DecalVertex, n2: DecalVertex, n3: DecalVertex, n4: DecalVertex;
            if (aOut) {
                n1 = b; n2 = c; n3 = clip(a, n1, plane, s); n4 = clip(a, n2, plane, s);
            } else if (bOut) {
                n1 = a; n2 = c; n3 = clip(b, n1, plane, s); n4 = clip(b, n2, plane, s);
                out.push(n3); out.push(n2.clone()); out.push(n1.clone());
                out.push(n2.clone()); out.push(n3.clone()); out.push(n4);
                continue;
            } else {
                n1 = a; n2 = b; n3 = clip(c, n1, plane, s); n4 = clip(c, n2, plane, s);
            }
            out.push(n1.clone()); out.push(n2.clone()); out.push(n3);
            out.push(n4); out.push(n3.clone()); out.push(n2.clone());
        } else if (total == 2) {
            // Two out: the triangle shrinks to the inside vertex.
            if (!aOut) {
                const n1 = a.clone();
                out.push(n1); out.push(clip(n1, b, plane, s)); out.push(clip(n1, c, plane, s));
            }
            if (!bOut) {
                const n1 = b.clone();
                out.push(n1); out.push(clip(n1, c, plane, s)); out.push(clip(n1, a, plane, s));
            }
            if (!cOut) {
                const n1 = c.clone();
                out.push(n1); out.push(clip(n1, a, plane, s)); out.push(clip(n1, b, plane, s));
            }
        }
    }
    return out;
}
