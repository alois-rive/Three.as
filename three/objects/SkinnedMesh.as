// three.js SkinnedMesh: a mesh its skeleton's bones deform (on the GPU).
// The geometry needs "skinIndex" and "skinWeight" attributes (4 per vertex).
// bindMode "attached" (default): the mesh's own transform moves with it;
// "detached": only the bones place it.

import { Object3D } from "../core/Object3D";
import { Mesh } from "./Mesh";
import { Skeleton } from "./Skeleton";
import { BufferGeometry } from "../core/BufferGeometry";
import { Material } from "../materials/Material";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { Matrix4 } from "../math/Matrix4";
import { Vector3 } from "../math/Vector3";
import { Vector4 } from "../math/Vector4";
import { Box3 } from "../math/Box3";
import { Sphere } from "../math/Sphere";
import { Raycaster, Intersection } from "../core/Raycaster";
import { raycastMesh } from "./raycasting";
import { Dynamic } from "rive/dynamic";
import { JSONMeta } from "../core/JSON";

export const AttachedBindMode: string = "attached";
export const DetachedBindMode: string = "detached";

export class SkinnedMesh extends Mesh {
    readonly isSkinnedMesh: bool = true;
    bindMode: string = AttachedBindMode;
    bindMatrix: Matrix4 = new Matrix4();
    bindMatrixInverse: Matrix4 = new Matrix4();
    skeleton: Skeleton? = null;
    /// Bounds of the posed mesh (computeBoundingBox/Sphere), for culling
    /// and raycasting; null until computed.
    boundingBox: Box3? = null;
    boundingSphere: Sphere? = null;

    constructor(geometry: BufferGeometry = new BufferGeometry(), material: Material = new MeshBasicMaterial()) {
        super(geometry, material);
        this.type = "SkinnedMesh";
    }

    override toJSONObject(object: Dynamic, meta: JSONMeta): void {
        super.toJSONObject(object, meta);
        object.set("bindMode", Dynamic.fromString(this.bindMode));
        object.set("bindMatrix", Dynamic.fromNumbers(this.bindMatrix.toArray()));
        const skeleton = this.skeleton;
        if (skeleton != null) {
            if (!meta.skeletons.has(skeleton.uuid)) meta.skeletons.set(skeleton.uuid, skeleton.toJSON());
            object.set("skeleton", Dynamic.fromString(skeleton.uuid));
        }
    }

    /// Binds `skeleton`, with the mesh's current world transform as the bind
    /// matrix unless one is given.
    bind(skeleton: Skeleton, bindMatrix: Matrix4? = null): void {
        this.skeleton = skeleton;
        if (bindMatrix == null) {
            this.updateMatrixWorld(true);
            skeleton.calculateInverses();
            this.bindMatrix.copy(this.matrixWorld);
        } else {
            this.bindMatrix.copy(bindMatrix);
        }
        this.bindMatrixInverse.copy(this.bindMatrix).invert();
    }

    pose(): void {
        const s = this.skeleton;
        if (s != null) s.pose();
    }

    /// Makes each vertex's four weights sum to 1.
    normalizeSkinWeights(): void {
        const w = this.geometry.getAttribute("skinWeight");
        if (w == null) return;
        for (let i = 0; i < w.count; i++) {
            const x = w.getX(i), y = w.getY(i), z = w.getZ(i), ww = w.getW(i);
            const sum = x + y + z + ww;
            const k = sum != 0 ? 1 / sum : 0;
            if (sum == 0) w.setXYZW(i, 1, 0, 0, 0);
            else w.setXYZW(i, x * k, y * k, z * k, ww * k);
        }
        w.needsUpdate = true;
    }

    override updateMatrixWorld(force: bool = false): void {
        super.updateMatrixWorld(force);
        if (this.bindMode == AttachedBindMode) this.bindMatrixInverse.copy(this.matrixWorld).invert();
        else this.bindMatrixInverse.copy(this.bindMatrix).invert();
    }

    /// The vertex's position after morph targets and bones (mesh space).
    override getVertexPosition(index: i32, target: Vector3): Vector3 {
        super.getVertexPosition(index, target);
        return this.applyBoneTransform(index, target);
    }

    applyBoneTransform(index: i32, vector: Vector3): Vector3 {
        const skeleton = this.skeleton;
        const si = this.geometry.getAttribute("skinIndex");
        const sw = this.geometry.getAttribute("skinWeight");
        if (skeleton == null || si == null || sw == null) return vector;
        _skinIndex.set(si.getX(index), si.getY(index), si.getZ(index), si.getW(index));
        _skinWeight.set(sw.getX(index), sw.getY(index), sw.getZ(index), sw.getW(index));
        _base.copy(vector).applyMatrix4(this.bindMatrix);
        vector.set(0, 0, 0);
        for (let i = 0; i < 4; i++) {
            const weight = i == 0 ? _skinWeight.x : i == 1 ? _skinWeight.y : i == 2 ? _skinWeight.z : _skinWeight.w;
            if (weight == 0) continue;
            const b = <i32>(i == 0 ? _skinIndex.x : i == 1 ? _skinIndex.y : i == 2 ? _skinIndex.z : _skinIndex.w);
            if (b >= skeleton.bones.length) continue;
            _m.multiplyMatrices(skeleton.bones[b].matrixWorld, skeleton.boneInverses[b]);
            vector.addScaledVector(_bone.copy(_base).applyMatrix4(_m), weight);
        }
        return vector.applyMatrix4(this.bindMatrixInverse);
    }

    computeBoundingBox(): void {
        let box = this.boundingBox;
        if (box == null) {
            box = new Box3();
            this.boundingBox = box;
        }
        box.makeEmpty();
        const p = this.geometry.getAttribute("position");
        if (p == null) return;
        for (let i = 0; i < p.count; i++) box.expandByPoint(this.getVertexPosition(i, _point));
    }

    computeBoundingSphere(): void {
        let sphere = this.boundingSphere;
        if (sphere == null) {
            sphere = new Sphere();
            this.boundingSphere = sphere;
        }
        sphere.makeEmpty();
        const p = this.geometry.getAttribute("position");
        if (p == null) return;
        for (let i = 0; i < p.count; i++) sphere.expandByPoint(this.getVertexPosition(i, _point));
    }

    override raycast(raycaster: Raycaster, intersects: Array<Intersection>): bool {
        raycastMesh(this, raycaster, intersects, this.matrixWorld, -1);
        return true;
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof SkinnedMesh) {
            const s = source as SkinnedMesh;
            this.bindMode = s.bindMode;
            this.bindMatrix.copy(s.bindMatrix);
            this.bindMatrixInverse.copy(s.bindMatrixInverse);
            this.skeleton = s.skeleton;
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new SkinnedMesh(this.geometry, this.material).copy(this, recursive);
    }
}

const _skinIndex: Vector4 = new Vector4();
const _skinWeight: Vector4 = new Vector4();
const _base: Vector3 = new Vector3();
// Separate scratch vectors: getVertexPosition may be handed _point.
const _bone: Vector3 = new Vector3();
const _point: Vector3 = new Vector3();
const _m: Matrix4 = new Matrix4();
