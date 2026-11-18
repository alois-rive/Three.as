// three.js BufferGeometry: named vertex attributes ("position", "normal",
// "uv") and an optional index.

import { BufferAttribute, Uint32BufferAttribute } from "./BufferAttribute";
import { Matrix3 } from "../math/Matrix3";
import { Matrix4 } from "../math/Matrix4";
import { Quaternion } from "../math/Quaternion";
import { Vector3 } from "../math/Vector3";

let _geometryId: i32 = 0;

/// Geometries disposed since the renderer last looked (ids). Internal.
export const disposedGeometries: Array<i32> = [];

export class GeometryGroup {
    start: i32;
    count: i32;
    materialIndex: i32;

    constructor(start: i32, count: i32, materialIndex: i32) {
        this.start = start;
        this.count = count;
        this.materialIndex = materialIndex;
    }
}

export class DrawRange {
    start: i32 = 0;
    /// -1: to the end.
    count: i32 = -1;
}

export class BufferGeometry {
    readonly isBufferGeometry: bool = true;
    id: i32;
    name: string = "";
    type: string = "BufferGeometry";
    index: Uint32BufferAttribute? = null;
    attributes: Map<string, BufferAttribute> = new Map<string, BufferAttribute>();
    groups: Array<GeometryGroup> = [];
    drawRange: DrawRange = new DrawRange();

    constructor() {
        this.id = _geometryId++;
    }

    getIndex(): Uint32BufferAttribute? { return this.index; }

    /// Sets the index from a plain array (three.js also takes an attribute:
    /// use setIndexAttribute).
    setIndex(index: Array<i32>?): BufferGeometry {
        this.index = index != null ? new Uint32BufferAttribute(index) : null;
        return this;
    }

    setIndexAttribute(index: Uint32BufferAttribute?): BufferGeometry {
        this.index = index;
        return this;
    }

    getAttribute(name: string): BufferAttribute? {
        return this.attributes.has(name) ? this.attributes.get(name) : null;
    }

    setAttribute(name: string, attribute: BufferAttribute): BufferGeometry {
        this.attributes.set(name, attribute);
        return this;
    }

    deleteAttribute(name: string): BufferGeometry {
        this.attributes.delete(name);
        return this;
    }

    hasAttribute(name: string): bool { return this.attributes.has(name); }

    addGroup(start: i32, count: i32, materialIndex: i32 = 0): void {
        this.groups.push(new GeometryGroup(start, count, materialIndex));
    }

    clearGroups(): void { this.groups = []; }

    setDrawRange(start: i32, count: i32): void {
        this.drawRange.start = start;
        this.drawRange.count = count;
    }

    applyMatrix4(matrix: Matrix4): BufferGeometry {
        const position = this.getAttribute("position");
        if (position != null) {
            position.applyMatrix4(matrix);
            position.needsUpdate = true;
        }
        const normal = this.getAttribute("normal");
        if (normal != null) {
            normal.applyNormalMatrix(_n.getNormalMatrix(matrix));
            normal.needsUpdate = true;
        }
        return this;
    }

    applyQuaternion(q: Quaternion): BufferGeometry {
        _m.makeRotationFromQuaternion(q);
        return this.applyMatrix4(_m);
    }

    rotateX(angle: f64): BufferGeometry { return this.applyMatrix4(_m.makeRotationX(angle)); }
    rotateY(angle: f64): BufferGeometry { return this.applyMatrix4(_m.makeRotationY(angle)); }
    rotateZ(angle: f64): BufferGeometry { return this.applyMatrix4(_m.makeRotationZ(angle)); }
    translate(x: f64, y: f64, z: f64): BufferGeometry { return this.applyMatrix4(_m.makeTranslation(x, y, z)); }
    scale(x: f64, y: f64, z: f64): BufferGeometry { return this.applyMatrix4(_m.makeScale(x, y, z)); }

    /// Moves the geometry so its bounding box is centred on the origin.
    center(): BufferGeometry {
        const position = this.getAttribute("position");
        if (position == null || position.count == 0) return this;
        _min.set(Infinity, Infinity, Infinity);
        _max.set(-Infinity, -Infinity, -Infinity);
        for (let i = 0; i < position.count; i++) {
            _v.set(position.getX(i), position.getY(i), position.getZ(i));
            _min.min(_v);
            _max.max(_v);
        }
        _v.addVectors(_min, _max).multiplyScalar(-0.5);
        return this.translate(_v.x, _v.y, _v.z);
    }

    /// Area-weighted vertex normals from the faces (index or triangle soup).
    computeVertexNormals(): void {
        const position = this.getAttribute("position");
        if (position == null) return;
        let normal = this.getAttribute("normal");
        if (normal == null || normal.count != position.count) {
            normal = new BufferAttribute(new Float32Array(position.count * 3), 3);
            this.setAttribute("normal", normal);
        } else {
            normal.array.fill(0);
        }
        const index = this.index;
        const triangles = index != null ? index.count / 3 : position.count / 3;
        for (let t = 0; t < triangles; t++) {
            const a = index != null ? index.getX(t * 3) : t * 3;
            const b = index != null ? index.getX(t * 3 + 1) : t * 3 + 1;
            const c = index != null ? index.getX(t * 3 + 2) : t * 3 + 2;
            _pA.set(position.getX(a), position.getY(a), position.getZ(a));
            _pB.set(position.getX(b), position.getY(b), position.getZ(b));
            _pC.set(position.getX(c), position.getY(c), position.getZ(c));
            _cb.subVectors(_pC, _pB);
            _ab.subVectors(_pA, _pB);
            _cb.cross(_ab);
            if (index != null) {
                addTo(normal, a, _cb);
                addTo(normal, b, _cb);
                addTo(normal, c, _cb);
            } else {
                normal.setXYZ(a, _cb.x, _cb.y, _cb.z);
                normal.setXYZ(b, _cb.x, _cb.y, _cb.z);
                normal.setXYZ(c, _cb.x, _cb.y, _cb.z);
            }
        }
        this.normalizeNormals();
        normal.needsUpdate = true;
    }

    normalizeNormals(): void {
        const normal = this.getAttribute("normal");
        if (normal == null) return;
        for (let i = 0; i < normal.count; i++) {
            _v.set(normal.getX(i), normal.getY(i), normal.getZ(i)).normalize();
            normal.setXYZ(i, _v.x, _v.y, _v.z);
        }
    }

    /// Frees the GPU buffers; the geometry can be drawn again afterward (it
    /// re-uploads).
    dispose(): void {
        disposedGeometries.push(this.id);
    }
}

function addTo(attribute: BufferAttribute, i: i32, v: Vector3): void {
    attribute.setXYZ(i, attribute.getX(i) + v.x, attribute.getY(i) + v.y, attribute.getZ(i) + v.z);
}

const _m: Matrix4 = new Matrix4();
const _n: Matrix3 = new Matrix3();
const _v: Vector3 = new Vector3();
const _min: Vector3 = new Vector3();
const _max: Vector3 = new Vector3();
const _pA: Vector3 = new Vector3();
const _pB: Vector3 = new Vector3();
const _pC: Vector3 = new Vector3();
const _cb: Vector3 = new Vector3();
const _ab: Vector3 = new Vector3();
