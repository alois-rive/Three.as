// three.js BatchedMesh: many geometries and their instances in one object,
// one material. Geometries are copied into one shared vertex and index
// buffer; the renderer draws each geometry's visible instances with one
// instanced draw (three.js uses multi-draw), culling instances one by one
// (perObjectFrustumCulled). Geometries must share their attribute set
// (position, normal, uv as the first one has) and be indexed or not alike.
//
//     const batch = new BatchedMesh(1000, 50000, 100000, material);
//     const box = batch.addGeometry(new BoxGeometry());
//     const id = batch.addInstance(box);
//     batch.setMatrixAt(id, matrix);

import { Mesh } from "./Mesh";
import { BufferGeometry } from "../core/BufferGeometry";
import { BufferAttribute } from "../core/BufferAttribute";
import { Material } from "../materials/Material";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { Matrix4 } from "../math/Matrix4";
import { Color } from "../math/Color";
import { Box3 } from "../math/Box3";
import { Sphere } from "../math/Sphere";
import { Ray } from "../math/Ray";
import { Vector3 } from "../math/Vector3";
import { Object3D } from "../core/Object3D";
import { Event } from "../core/EventDispatcher";
import { Raycaster, Intersection } from "../core/Raycaster";
import { raycastMesh, raycastAnyHit } from "./raycasting";

export class BatchedGeometryInfo {
    vertexStart: i32 = 0;
    vertexCount: i32 = 0;
    reservedVertexCount: i32 = 0;
    indexStart: i32 = 0;
    indexCount: i32 = 0;
    reservedIndexCount: i32 = 0;
    active: bool = true;
    boundingBox: Box3 = new Box3();
    boundingSphere: Sphere = new Sphere();
}

export class BatchedInstanceInfo {
    geometryIndex: i32 = 0;
    visible: bool = true;
    active: bool = true;
}

/// geometry range in the shared buffers (getGeometryRangeAt).
export class BatchedGeometryRange {
    vertexStart: i32 = 0;
    vertexCount: i32 = 0;
    indexStart: i32 = 0;
    indexCount: i32 = 0;
}

const _box = new Box3();
const _sphere = new Sphere();
const _ray = new Ray();
const _hitAt = new Vector3();
const _v = new Vector3();
const _m = new Matrix4();
const _world = new Matrix4();

export class BatchedMesh extends Mesh {
    readonly isBatchedMesh: bool = true;
    maxInstanceCount: i32;
    maxVertexCount: i32;
    maxIndexCount: i32;
    perObjectFrustumCulled: bool = true;
    sortObjects: bool = true;
    customSort: i32 = 0;
    boundingBox: Box3? = null;
    boundingSphere: Sphere? = null;
    geometryInfo: Array<BatchedGeometryInfo> = [];
    instanceInfo: Array<BatchedInstanceInfo> = [];
    /// Per instance: a column-major matrix, an rgb colour (internal).
    matricesArray: Float32Array;
    colorsArray: Float32Array;
    /// Bumped when instances change (internal: the renderer re-packs).
    instancesVersion: i32 = 0;

    private nextVertex: i32 = 0;
    private nextIndex: i32 = 0;
    private indexed: i32 = -1;   // -1 unknown, 0 no, 1 yes
    private attributeNames: Array<string> = [];

    constructor(maxInstanceCount: i32, maxVertexCount: i32, maxIndexCount: i32 = -1,
                material: Material = new MeshBasicMaterial()) {
        super(new BufferGeometry(), material);
        this.type = "BatchedMesh";
        this.maxInstanceCount = maxInstanceCount;
        this.maxVertexCount = maxVertexCount;
        this.maxIndexCount = maxIndexCount < 0 ? maxVertexCount * 2 : maxIndexCount;
        this.matricesArray = new Float32Array(maxInstanceCount * 16);
        this.colorsArray = new Float32Array(maxInstanceCount * 3);
        this.colorsArray.fill(1);
    }

    /// Instances changed: bounds are recomputed when next needed.
    private touch(): void {
        this.instancesVersion++;
        this.boundingBox = null;
        this.boundingSphere = null;
    }

    get instanceCount(): i32 {
        let n = 0;
        for (let i = 0; i < this.instanceInfo.length; i++) if (this.instanceInfo[i].active) n++;
        return n;
    }

    get unusedVertexCount(): i32 { return this.maxVertexCount - this.nextVertex; }
    get unusedIndexCount(): i32 { return this.maxIndexCount - this.nextIndex; }

    private initGeometry(reference: BufferGeometry): void {
        const g = this.geometry;
        const names = reference.attributes.keys();
        for (let i = 0; i < names.length; i++) {
            const a = reference.attributes.get(names[i]);
            this.attributeNames.push(names[i]);
            g.setAttribute(names[i], new BufferAttribute(new Float32Array(this.maxVertexCount * a.itemSize), a.itemSize, a.normalized));
        }
        this.indexed = reference.index != null ? 1 : 0;
        if (this.indexed == 1) {
            const idx: Array<i32> = [];
            for (let i = 0; i < this.maxIndexCount; i++) idx.push(0);
            g.setIndex(idx);
        }
    }

    /// Adds a geometry (copied in); returns its id, or -1 when it does not
    /// fit or does not match. Reserved counts leave room to replace it.
    addGeometry(geometry: BufferGeometry, reservedVertexCount: i32 = -1, reservedIndexCount: i32 = -1): i32 {
        const position = geometry.getAttribute("position");
        if (position == null) return -1;
        if (this.indexed < 0) this.initGeometry(geometry);
        if ((geometry.index != null ? 1 : 0) != this.indexed) return -1;
        const info = new BatchedGeometryInfo();
        info.vertexStart = this.nextVertex;
        info.reservedVertexCount = max<i32>(reservedVertexCount, position.count);
        info.indexStart = this.nextIndex;
        info.reservedIndexCount = this.indexed == 1 ? max<i32>(reservedIndexCount, geometry.index!.count) : 0;
        if (info.vertexStart + info.reservedVertexCount > this.maxVertexCount
                || info.indexStart + info.reservedIndexCount > this.maxIndexCount) return -1;
        this.nextVertex += info.reservedVertexCount;
        this.nextIndex += info.reservedIndexCount;
        this.geometryInfo.push(info);
        const id = this.geometryInfo.length - 1;
        this.setGeometryAt(id, geometry);
        return id;
    }

    /// Replaces geometry `geometryId` (within its reserved space).
    setGeometryAt(geometryId: i32, geometry: BufferGeometry): i32 {
        if (geometryId < 0 || geometryId >= this.geometryInfo.length) return -1;
        const info = this.geometryInfo[geometryId];
        if (!info.active) return -1;
        const position = geometry.getAttribute("position");
        if (position == null || position.count > info.reservedVertexCount) return -1;
        if (this.indexed == 1) {
            const src = geometry.index;
            if (src == null || src.count > info.reservedIndexCount) return -1;
        } else if (geometry.index != null) {
            return -1;
        }
        const g = this.geometry;
        for (let n = 0; n < this.attributeNames.length; n++) {
            const name = this.attributeNames[n];
            const dst = g.getAttribute(name)!;
            const src = geometry.getAttribute(name);
            const size = dst.itemSize;
            for (let i = 0; i < position.count; i++) {
                for (let k = 0; k < size; k++) {
                    dst.array[(info.vertexStart + i) * size + k] = src != null && k < src.itemSize ? src.array[i * src.itemSize + k] : 0;
                }
            }
            dst.needsUpdate = true;
        }
        info.vertexCount = position.count;
        if (this.indexed == 1) {
            const src = geometry.index!;
            const dst = g.index!;
            for (let i = 0; i < src.count; i++) dst.array[info.indexStart + i] = src.array[i] + <u32>info.vertexStart;
            dst.version++;
            info.indexCount = src.count;
        } else {
            info.indexCount = 0;
        }
        // Bounds, for culling.
        info.boundingBox.makeEmpty();
        for (let i = 0; i < position.count; i++) info.boundingBox.expandByPoint(_v.fromBufferAttribute(position, i));
        info.boundingBox.getBoundingSphere(info.boundingSphere);
        g.boundingBox = null;
        g.boundingSphere = null;
        this.touch();
        return geometryId;
    }

    deleteGeometry(geometryId: i32): BatchedMesh {
        if (geometryId < 0 || geometryId >= this.geometryInfo.length) return this;
        this.geometryInfo[geometryId].active = false;
        for (let i = 0; i < this.instanceInfo.length; i++) {
            if (this.instanceInfo[i].geometryIndex == geometryId) this.deleteInstance(i);
        }
        this.touch();
        return this;
    }

    /// Adds an instance of `geometryId` (identity matrix, white); returns
    /// its id, or -1 when full.
    addInstance(geometryId: i32): i32 {
        let id = -1;
        for (let i = 0; i < this.instanceInfo.length && id < 0; i++) if (!this.instanceInfo[i].active) id = i;
        if (id < 0) {
            if (this.instanceInfo.length >= this.maxInstanceCount) return -1;
            this.instanceInfo.push(new BatchedInstanceInfo());
            id = this.instanceInfo.length - 1;
        }
        const info = this.instanceInfo[id];
        info.geometryIndex = geometryId;
        info.visible = true;
        info.active = true;
        this.setMatrixAt(id, _m.identity());
        this.colorsArray[id * 3] = 1; this.colorsArray[id * 3 + 1] = 1; this.colorsArray[id * 3 + 2] = 1;
        this.touch();
        return id;
    }

    deleteInstance(instanceId: i32): BatchedMesh {
        if (instanceId >= 0 && instanceId < this.instanceInfo.length) this.instanceInfo[instanceId].active = false;
        this.touch();
        return this;
    }

    setMatrixAt(instanceId: i32, matrix: Matrix4): BatchedMesh {
        const e = matrix.elements;
        for (let k = 0; k < 16; k++) this.matricesArray[instanceId * 16 + k] = <f32>e[k];
        this.touch();
        return this;
    }

    getMatrixAt(instanceId: i32, matrix: Matrix4): Matrix4 {
        const e = matrix.elements;
        for (let k = 0; k < 16; k++) e[k] = this.matricesArray[instanceId * 16 + k];
        return matrix;
    }

    setColorAt(instanceId: i32, color: Color): BatchedMesh {
        this.colorsArray[instanceId * 3] = <f32>color.r;
        this.colorsArray[instanceId * 3 + 1] = <f32>color.g;
        this.colorsArray[instanceId * 3 + 2] = <f32>color.b;
        this.touch();
        return this;
    }

    getColorAt(instanceId: i32, color: Color): Color {
        return color.setRGB(this.colorsArray[instanceId * 3], this.colorsArray[instanceId * 3 + 1],
            this.colorsArray[instanceId * 3 + 2]);
    }

    setVisibleAt(instanceId: i32, visible: bool): BatchedMesh {
        this.instanceInfo[instanceId].visible = visible;
        this.touch();
        return this;
    }

    getVisibleAt(instanceId: i32): bool { return this.instanceInfo[instanceId].visible; }

    setGeometryIdAt(instanceId: i32, geometryId: i32): BatchedMesh {
        this.instanceInfo[instanceId].geometryIndex = geometryId;
        this.touch();
        return this;
    }

    getGeometryIdAt(instanceId: i32): i32 { return this.instanceInfo[instanceId].geometryIndex; }

    getGeometryRangeAt(geometryId: i32, target: BatchedGeometryRange = new BatchedGeometryRange()): BatchedGeometryRange {
        const info = this.geometryInfo[geometryId];
        target.vertexStart = info.vertexStart;
        target.vertexCount = info.vertexCount;
        target.indexStart = info.indexStart;
        target.indexCount = info.indexCount;
        return target;
    }

    getBoundingBoxAt(geometryId: i32, target: Box3): Box3 { return target.copy(this.geometryInfo[geometryId].boundingBox); }
    getBoundingSphereAt(geometryId: i32, target: Sphere): Sphere { return target.copy(this.geometryInfo[geometryId].boundingSphere); }

    /// The union of every active instance's bounds (local space).
    computeBoundingBox(): void {
        const box = this.boundingBox != null ? this.boundingBox! : new Box3();
        box.makeEmpty();
        for (let i = 0; i < this.instanceInfo.length; i++) {
            const info = this.instanceInfo[i];
            if (!info.active) continue;
            this.getMatrixAt(i, _m);
            _box.copy(this.geometryInfo[info.geometryIndex].boundingBox).applyMatrix4(_m);
            box.union(_box);
        }
        this.boundingBox = box;
    }

    computeBoundingSphere(): void {
        this.computeBoundingBox();
        const s = this.boundingSphere != null ? this.boundingSphere! : new Sphere();
        this.boundingBox!.getBoundingSphere(s);
        this.boundingSphere = s;
    }

    /// Disposes its geometry (which it made) and, dispatching "dispose", the
    /// renderers' instance buffers for it, at their next render (three.js
    /// disposes its geometry and its matrix and colour textures).
    dispose(): BatchedMesh {
        this.geometry.dispose();
        if (this.hasListeners("dispose")) this.dispatchEvent(new Event("dispose"));
        return this;
    }

    /// Compacts the shared buffers after deletions (three.js's optimize).
    optimize(): BatchedMesh {
        let vertex = 0, index = 0;
        const g = this.geometry;
        for (let i = 0; i < this.geometryInfo.length; i++) {
            const info = this.geometryInfo[i];
            if (!info.active) continue;
            if (info.vertexStart != vertex) {
                for (let n = 0; n < this.attributeNames.length; n++) {
                    const a = g.getAttribute(this.attributeNames[n])!;
                    a.array.copyWithin(vertex * a.itemSize, info.vertexStart * a.itemSize,
                        (info.vertexStart + info.reservedVertexCount) * a.itemSize);
                    a.needsUpdate = true;
                }
                if (this.indexed == 1) {
                    const idx = g.index!.array;
                    const shift = <u32>(info.vertexStart - vertex);
                    for (let k = 0; k < info.indexCount; k++) idx[info.indexStart + k] -= shift;
                }
                info.vertexStart = vertex;
            }
            if (this.indexed == 1 && info.indexStart != index) {
                const idx = g.index!.array;
                idx.copyWithin(index, info.indexStart, info.indexStart + info.reservedIndexCount);
                info.indexStart = index;
            }
            if (this.indexed == 1) g.index!.version++;
            vertex += info.reservedVertexCount;
            index += info.reservedIndexCount;
        }
        this.nextVertex = vertex;
        this.nextIndex = index;
        this.touch();
        return this;
    }

    /// Raycasts each visible instance (its geometry's range, its matrix);
    /// hits carry `batchId`.
    override raycast(raycaster: Raycaster, intersects: Array<Intersection>): bool {
        if (this.instanceInfo.length == 0 || this.indexed < 0) return true;
        if (this.boundingSphere == null) this.computeBoundingSphere();
        if (this.boundingSphere!.isEmpty()) return true;
        const range = raycaster.far - raycaster.near;
        const rangeSq = range * range;
        _ray.copy(raycaster.ray).recast(raycaster.near);
        _sphere.copy(this.boundingSphere!).applyMatrix4(this.matrixWorld);
        if (!_sphere.containsPoint(_ray.origin)) {
            if (_ray.intersectSphere(_sphere, _hitAt) == null) return true;
            if (_ray.origin.distanceToSquared(_hitAt) > rangeSq) return true;
        }
        const g = this.geometry;
        const saveStart = g.drawRange.start, saveCount = g.drawRange.count;
        for (let i = 0; i < this.instanceInfo.length; i++) {
            const info = this.instanceInfo[i];
            if (!info.active || !info.visible) continue;
            const geo = this.geometryInfo[info.geometryIndex];
            if (!geo.active || geo.boundingSphere.isEmpty()) continue;
            _world.multiplyMatrices(this.matrixWorld, this.getMatrixAt(i, _m));
            _sphere.copy(geo.boundingSphere).applyMatrix4(_world);
            if (!_sphere.containsPoint(_ray.origin)) {
                if (_ray.intersectSphere(_sphere, _hitAt) == null) continue;
                if (_ray.origin.distanceToSquared(_hitAt) > rangeSq) continue;
            }
            if (this.indexed == 1) g.setDrawRange(geo.indexStart, geo.indexCount);
            else g.setDrawRange(geo.vertexStart, geo.vertexCount);
            const before = intersects.length;
            raycastMesh(this, raycaster, intersects, _world, -1, null, geo.boundingBox, false, true);
            for (let k = before; k < intersects.length; k++) intersects[k].batchId = i;
            if (raycastAnyHit() && intersects.length > before) break;
        }
        g.setDrawRange(saveStart, saveCount);
        return true;
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof BatchedMesh) {
            const s = source as BatchedMesh;
            this.geometry = s.geometry.clone();
            this.maxInstanceCount = s.maxInstanceCount;
            this.maxVertexCount = s.maxVertexCount;
            this.maxIndexCount = s.maxIndexCount;
            this.perObjectFrustumCulled = s.perObjectFrustumCulled;
            this.sortObjects = s.sortObjects;
            this.customSort = s.customSort;
            this.nextVertex = s.nextVertex;
            this.nextIndex = s.nextIndex;
            this.indexed = s.indexed;
            this.attributeNames = s.attributeNames.slice();
            this.geometryInfo = [];
            for (let i = 0; i < s.geometryInfo.length; i++) {
                const sg = s.geometryInfo[i];
                const dg = new BatchedGeometryInfo();
                dg.vertexStart = sg.vertexStart;
                dg.vertexCount = sg.vertexCount;
                dg.reservedVertexCount = sg.reservedVertexCount;
                dg.indexStart = sg.indexStart;
                dg.indexCount = sg.indexCount;
                dg.reservedIndexCount = sg.reservedIndexCount;
                dg.active = sg.active;
                dg.boundingBox.copy(sg.boundingBox);
                dg.boundingSphere.copy(sg.boundingSphere);
                this.geometryInfo.push(dg);
            }
            this.instanceInfo = [];
            for (let i = 0; i < s.instanceInfo.length; i++) {
                const si = s.instanceInfo[i];
                const di = new BatchedInstanceInfo();
                di.geometryIndex = si.geometryIndex;
                di.visible = si.visible;
                di.active = si.active;
                this.instanceInfo.push(di);
            }
            if (this.matricesArray.length == s.matricesArray.length) this.matricesArray.set(s.matricesArray);
            else this.matricesArray = s.matricesArray.slice();
            if (this.colorsArray.length == s.colorsArray.length) this.colorsArray.set(s.colorsArray);
            else this.colorsArray = s.colorsArray.slice();
            this.boundingBox = s.boundingBox != null ? s.boundingBox!.clone() : null;
            this.boundingSphere = s.boundingSphere != null ? s.boundingSphere!.clone() : null;
            this.instancesVersion++;
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new BatchedMesh(this.maxInstanceCount, this.maxVertexCount, this.maxIndexCount, this.material).copy(this, recursive);
    }
}
