// three.js BufferGeometry: named vertex attributes ("position", "normal",
// "uv") and an optional index.

import { EventDispatcher, Event } from "./EventDispatcher";
import { BufferAttribute, Uint32BufferAttribute } from "./BufferAttribute";
import { Matrix3 } from "../math/Matrix3";
import { Matrix4 } from "../math/Matrix4";
import { Quaternion } from "../math/Quaternion";
import { Vector3 } from "../math/Vector3";
import { Box3 } from "../math/Box3";
import { Sphere } from "../math/Sphere";
import { MathUtils } from "../math/MathUtils";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, jsonMetadata, isEmptyTable } from "./JSON";

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

export class BufferGeometry extends EventDispatcher {
    readonly isBufferGeometry: bool = true;
    id: i32;
    name: string = "";
    type: string = "BufferGeometry";
    index: Uint32BufferAttribute? = null;
    attributes: Map<string, BufferAttribute> = new Map<string, BufferAttribute>();
    groups: Array<GeometryGroup> = [];
    drawRange: DrawRange = new DrawRange();
    /// Morph targets per attribute ("position", "normal"), one attribute per
    /// target (named by the target's name, when it has one).
    morphAttributes: Map<string, Array<BufferAttribute>> = new Map<string, Array<BufferAttribute>>();
    /// Morph targets hold offsets (true) or absolute values (false).
    morphTargetsRelative: bool = false;
    /// Set by computeBoundingBox (null until then).
    boundingBox: Box3? = null;
    /// Set by computeBoundingSphere; the renderer computes it on first
    /// use for frustum culling. Recompute after moving vertices by hand.
    boundingSphere: Sphere? = null;
    private _uuid: string = "";
    private _userData: Dynamic? = null;

    constructor() {
        super();
        this.id = _geometryId++;
    }

    /// A random uuid, made on first use.
    get uuid(): string {
        if (this._uuid.length == 0) this._uuid = MathUtils.generateUUID();
        return this._uuid;
    }
    set uuid(value: string) { this._uuid = value; }

    /// A `Dynamic` table, as three.js's userData (see Object3D.userData).
    get userData(): Dynamic {
        let d = this._userData;
        if (d == null) {
            d = Dynamic.newTable();
            this._userData = d;
        }
        return d!;
    }
    set userData(value: Dynamic) { this._userData = value; }

    /// three.js's JSON: { metadata, uuid, type, name, userData } and either
    /// the parameters of a built-in geometry (BoxGeometry ...: its
    /// constructor arguments, rebuilt by ObjectLoader) or `data` (attributes,
    /// index, morph attributes, groups, bounding sphere; `type` is then
    /// "BufferGeometry" for any class whose parameters are not written,
    /// such as TubeGeometry). `meta` collects
    /// the shapes of shape and extrude geometries (three.js does that in
    /// Object3D.toJSON).
    toJSON(meta: JSONMeta? = null): Dynamic {
        const data = Dynamic.newTable();
        data.set("metadata", jsonMetadata("BufferGeometry", "BufferGeometry.toJSON"));
        data.set("uuid", Dynamic.fromString(this.uuid));
        data.set("type", Dynamic.fromString(this.type));
        if (this.name != "") data.set("name", Dynamic.fromString(this.name));
        if (!isEmptyTable(this._userData)) data.set("userData", this._userData);
        if (this.toJSONParameters(data, meta)) return data;
        // A geometry written as data loads as a BufferGeometry (three.js
        // would look for the parameters of e.g. a TubeGeometry).
        data.set("type", Dynamic.fromString("BufferGeometry"));

        const d = Dynamic.newTable();
        const attributes = Dynamic.newTable();
        const index = this.index;
        if (index != null) d.set("index", index.toJSON());
        const names = this.attributes.keys();
        for (let i = 0; i < names.length; i++) attributes.set(names[i], this.attributes.get(names[i]).toJSON());
        d.set("attributes", attributes);
        const morphNames = this.morphAttributes.keys();
        const morphAttributes = Dynamic.newTable();
        let hasMorphAttributes = false;
        for (let i = 0; i < morphNames.length; i++) {
            const list = this.morphAttributes.get(morphNames[i]);
            if (list.length == 0) continue;
            const array = Dynamic.newTable();
            for (let j = 0; j < list.length; j++) array.push(list[j].toJSON());
            morphAttributes.set(morphNames[i], array);
            hasMorphAttributes = true;
        }
        if (hasMorphAttributes) {
            d.set("morphAttributes", morphAttributes);
            d.set("morphTargetsRelative", Dynamic.fromBool(this.morphTargetsRelative));
        }
        if (this.groups.length > 0) {
            const groups = Dynamic.newTable();
            for (let i = 0; i < this.groups.length; i++) {
                const g = this.groups[i];
                const group = Dynamic.newTable();
                group.set("start", Dynamic.fromNumber(<f64>g.start));
                group.set("count", Dynamic.fromNumber(<f64>g.count));
                group.set("materialIndex", Dynamic.fromNumber(<f64>g.materialIndex));
                groups.push(group);
            }
            d.set("groups", groups);
        }
        const sphere = this.boundingSphere;
        if (sphere != null) {
            const bs = Dynamic.newTable();
            bs.set("center", Dynamic.fromNumbers(sphere.center.toArray()));
            bs.set("radius", Dynamic.fromNumber(sphere.radius));
            d.set("boundingSphere", bs);
        }
        data.set("data", d);
        return data;
    }

    /// Writes a built-in geometry's parameters into `data` and returns true
    /// (three.js writes `this.parameters` when a geometry has them); false
    /// writes the vertex data instead. Internal to toJSON.
    toJSONParameters(data: Dynamic, meta: JSONMeta?): bool { return false; }

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
        if (this.boundingBox != null) this.computeBoundingBox();
        if (this.boundingSphere != null) this.computeBoundingSphere();
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

    computeBoundingBox(): void {
        let box = this.boundingBox;
        if (box == null) {
            box = new Box3();
            this.boundingBox = box;
        }
        const position = this.getAttribute("position");
        if (position != null) box.setFromBufferAttribute(position);
        else box.makeEmpty();
    }

    computeBoundingSphere(): void {
        let sphere = this.boundingSphere;
        if (sphere == null) {
            sphere = new Sphere();
            this.boundingSphere = sphere;
        }
        const position = this.getAttribute("position");
        if (position == null || position.count == 0) {
            sphere.makeEmpty();
            return;
        }
        const center = sphere.center;
        _box.setFromBufferAttribute(position).getCenter(center);
        let maxRadiusSq: f64 = 0;
        for (let i = 0, l = position.count; i < l; i++) {
            _v.set(position.getX(i), position.getY(i), position.getZ(i));
            maxRadiusSq = Math.max(maxRadiusSq, center.distanceToSquared(_v));
        }
        sphere.radius = Math.sqrt(maxRadiusSq);
    }

    /// Area-weighted vertex normals from the faces (index or triangle soup).
    /// three.js's computeTangents: a "tangent" attribute (xyz, w the
    /// bitangent's sign) from an indexed geometry's positions, normals and
    /// uvs, which normal maps then use instead of screen derivatives.
    computeTangents(): void {
        const index = this.index;
        const position = this.getAttribute("position");
        const normal = this.getAttribute("normal");
        const uv = this.getAttribute("uv");
        if (index == null || position == null || normal == null || uv == null) return;
        const count = position.count;
        const p = position.array, n = normal.array, t = uv.array, idx = index.array;
        const tan1 = new Float64Array(count * 3), tan2 = new Float64Array(count * 3);
        let ranges = this.groups;
        if (ranges.length == 0) ranges = [new GeometryGroup(0, index.count, 0)];
        for (let g = 0; g < ranges.length; g++) {
            const end = min<i32>(ranges[g].start + ranges[g].count, index.count);
            for (let j = ranges[g].start; j + 2 < end; j += 3) {
                const a = <i32>idx[j], b = <i32>idx[j + 1], c = <i32>idx[j + 2];
                const x1 = <f64>p[b * 3] - <f64>p[a * 3], y1 = <f64>p[b * 3 + 1] - <f64>p[a * 3 + 1], z1 = <f64>p[b * 3 + 2] - <f64>p[a * 3 + 2];
                const x2 = <f64>p[c * 3] - <f64>p[a * 3], y2 = <f64>p[c * 3 + 1] - <f64>p[a * 3 + 1], z2 = <f64>p[c * 3 + 2] - <f64>p[a * 3 + 2];
                const s1 = <f64>t[b * 2] - <f64>t[a * 2], t1 = <f64>t[b * 2 + 1] - <f64>t[a * 2 + 1];
                const s2 = <f64>t[c * 2] - <f64>t[a * 2], t2 = <f64>t[c * 2 + 1] - <f64>t[a * 2 + 1];
                const r = 1.0 / (s1 * t2 - s2 * t1);
                if (!isFinite(r)) continue;
                const sx = (x1 * t2 - x2 * t1) * r, sy = (y1 * t2 - y2 * t1) * r, sz = (z1 * t2 - z2 * t1) * r;
                const tx = (x2 * s1 - x1 * s2) * r, ty = (y2 * s1 - y1 * s2) * r, tz = (z2 * s1 - z1 * s2) * r;
                const vs: StaticArray<i32> = [a, b, c];
                for (let k = 0; k < 3; k++) {
                    const v = vs[k] * 3;
                    tan1[v] += sx; tan1[v + 1] += sy; tan1[v + 2] += sz;
                    tan2[v] += tx; tan2[v + 1] += ty; tan2[v + 2] += tz;
                }
            }
        }
        const out = new Float32Array(count * 4);
        for (let v = 0; v < count; v++) {
            const nx = <f64>n[v * 3], ny = <f64>n[v * 3 + 1], nz = <f64>n[v * 3 + 2];
            const tx = tan1[v * 3], ty = tan1[v * 3 + 1], tz = tan1[v * 3 + 2];
            // Gram-Schmidt against the normal.
            const d = nx * tx + ny * ty + nz * tz;
            let ox = tx - nx * d, oy = ty - ny * d, oz = tz - nz * d;
            const len = Math.sqrt(ox * ox + oy * oy + oz * oz);
            if (len > 0) { ox /= len; oy /= len; oz /= len; }
            // Handedness: (n x t) . tan2.
            const cx = ny * tz - nz * ty, cy = nz * tx - nx * tz, cz = nx * ty - ny * tx;
            const w = cx * tan2[v * 3] + cy * tan2[v * 3 + 1] + cz * tan2[v * 3 + 2] < 0 ? -1.0 : 1.0;
            out[v * 4] = <f32>ox; out[v * 4 + 1] = <f32>oy; out[v * 4 + 2] = <f32>oz; out[v * 4 + 3] = <f32>w;
        }
        this.setAttribute("tangent", new BufferAttribute(out, 4));
    }

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
    /// three.js's copy: attributes, index, morph attributes, groups,
    /// bounds and draw range, cloned.
    copy(source: BufferGeometry): BufferGeometry {
        this.name = source.name;
        this._userData = source._userData;
        this.attributes = new Map<string, BufferAttribute>();
        const names = source.attributes.keys();
        for (let i = 0; i < names.length; i++) this.attributes.set(names[i], source.attributes.get(names[i]).clone());
        const index = source.index;
        if (index != null) {
            const copy = new Uint32BufferAttribute([]);
            copy.array = index.array.slice();
            this.index = copy;
        } else {
            this.index = null;
        }
        this.morphAttributes = new Map<string, Array<BufferAttribute>>();
        const morphs = source.morphAttributes.keys();
        for (let i = 0; i < morphs.length; i++) {
            const list = source.morphAttributes.get(morphs[i]);
            const out: Array<BufferAttribute> = [];
            for (let j = 0; j < list.length; j++) {
                const c = list[j].clone();
                c.name = list[j].name;
                out.push(c);
            }
            this.morphAttributes.set(morphs[i], out);
        }
        this.morphTargetsRelative = source.morphTargetsRelative;
        this.groups = [];
        for (let i = 0; i < source.groups.length; i++) {
            const g = source.groups[i];
            this.groups.push(new GeometryGroup(g.start, g.count, g.materialIndex));
        }
        const bb = source.boundingBox;
        this.boundingBox = bb != null ? bb.clone() : null;
        const bs = source.boundingSphere;
        this.boundingSphere = bs != null ? bs.clone() : null;
        this.drawRange.start = source.drawRange.start;
        this.drawRange.count = source.drawRange.count;
        return this;
    }

    clone(): BufferGeometry {
        return new BufferGeometry().copy(this);
    }

    /// A geometry with the same triangles and no index (each vertex used
    /// once per triangle), as three.js's toNonIndexed.
    toNonIndexed(): BufferGeometry {
        const index = this.index;
        if (index == null) return this.clone();
        const out = new BufferGeometry();
        const idx = index.array;
        const names = this.attributes.keys();
        for (let n = 0; n < names.length; n++) {
            const a = this.attributes.get(names[n]);
            const size = a.itemSize;
            const data = new Float32Array(idx.length * size);
            for (let i = 0; i < idx.length; i++) {
                const v = <i32>idx[i];
                for (let k = 0; k < size; k++) data[i * size + k] = a.array[v * size + k];
            }
            out.setAttribute(names[n], new BufferAttribute(data, size, a.normalized));
        }
        for (let i = 0; i < this.groups.length; i++) {
            const g = this.groups[i];
            out.addGroup(g.start, g.count, g.materialIndex);
        }
        out.name = this.name;
        return out;
    }

    dispose(): void {
        disposedGeometries.push(this.id);
        if (this.hasListeners("dispose")) this.dispatchEvent(new Event("dispose"));
    }
}

function addTo(attribute: BufferAttribute, i: i32, v: Vector3): void {
    attribute.setXYZ(i, attribute.getX(i) + v.x, attribute.getY(i) + v.y, attribute.getZ(i) + v.z);
}

const _m: Matrix4 = new Matrix4();
const _box: Box3 = new Box3();
const _n: Matrix3 = new Matrix3();
const _v: Vector3 = new Vector3();
const _min: Vector3 = new Vector3();
const _max: Vector3 = new Vector3();
const _pA: Vector3 = new Vector3();
const _pB: Vector3 = new Vector3();
const _pC: Vector3 = new Vector3();
const _cb: Vector3 = new Vector3();
const _ab: Vector3 = new Vector3();
