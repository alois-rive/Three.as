// three.js SkinnedMesh: a mesh its skeleton's bones deform (on the GPU).
// The geometry needs "skinIndex" and "skinWeight" attributes (4 per vertex).
// bindMode "attached" (default): the mesh's own transform moves with it;
// "detached": only the bones place it.

import { Object3D } from "../core/Object3D";
import { Mesh } from "./Mesh";
import { Skeleton } from "./Skeleton";
import { BufferGeometry } from "../core/BufferGeometry";
import { BufferAttribute } from "../core/BufferAttribute";
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

    /// Poses every vertex (morph targets + skeleton) into `out` (3 floats per
    /// vertex), updating `skeleton.boneMatrices` once instead of multiplying
    /// bone matrices per vertex.
    poseVertices(out: Float32Array): void {
        const geometry = this.geometry;
        const p = geometry.getAttribute("position");
        if (p == null) return;
        const count = p.count;
        const skeleton = this.skeleton;
        const si = geometry.getAttribute("skinIndex");
        const sw = geometry.getAttribute("skinWeight");
        const hasSkin = skeleton != null && si != null && sw != null;
        if (hasSkin) skeleton!.update();
        const bm = hasSkin ? skeleton!.boneMatrices : null;
        const boneCount = hasSkin ? skeleton!.bones.length : 0;
        const influences = this.morphTargetInfluences;
        const hasMorph = influences.length > 0 && geometry.morphAttributes.has("position");
        const morph = hasMorph ? geometry.morphAttributes.get("position") : null;
        const morphRel = geometry.morphTargetsRelative;
        const pArr = p.array;
        const pStride = p.itemSize;
        for (let i = 0; i < count; i++) {
            const po = i * pStride;
            _point.set(<f64>pArr[po], <f64>pArr[po + 1], <f64>pArr[po + 2]);
            if (hasMorph) this.applyMorph(i, _point, morph!, influences, morphRel);
            if (hasSkin) this.applyBoneMatrices(i, _point, si!, sw!, bm!, boneCount);
            out[i * 3] = <f32>_point.x;
            out[i * 3 + 1] = <f32>_point.y;
            out[i * 3 + 2] = <f32>_point.z;
        }
    }

    private applyMorph(index: i32, target: Vector3, morph: Array<BufferAttribute>, influences: Array<f64>, relative: bool): void {
        let mx: f64 = 0, my: f64 = 0, mz: f64 = 0;
        for (let i = 0; i < influences.length && i < morph.length; i++) {
            const w = influences[i];
            if (w == 0) continue;
            const m = morph[i];
            let dx = m.getX(index), dy = m.getY(index), dz = m.getZ(index);
            if (!relative) { dx -= target.x; dy -= target.y; dz -= target.z; }
            mx += dx * w; my += dy * w; mz += dz * w;
        }
        target.x += mx; target.y += my; target.z += mz;
    }

    private applyBoneMatrices(index: i32, vector: Vector3, si: BufferAttribute, sw: BufferAttribute,
                              bm: Float32Array, boneCount: i32): Vector3 {
        const w0 = sw.getX(index), w1 = sw.getY(index), w2 = sw.getZ(index), w3 = sw.getW(index);
        _base.copy(vector).applyMatrix4(this.bindMatrix);
        const bx = _base.x, by = _base.y, bz = _base.z;
        let vx: f64 = 0, vy: f64 = 0, vz: f64 = 0;
        if (w0 != 0) {
            const b = <i32>si.getX(index);
            if (b >= 0 && b < boneCount) {
                const o = b * 16;
                const iw = 1 / (<f64>bm[o + 3] * bx + <f64>bm[o + 7] * by + <f64>bm[o + 11] * bz + <f64>bm[o + 15]);
                vx += (<f64>bm[o] * bx + <f64>bm[o + 4] * by + <f64>bm[o + 8] * bz + <f64>bm[o + 12]) * iw * w0;
                vy += (<f64>bm[o + 1] * bx + <f64>bm[o + 5] * by + <f64>bm[o + 9] * bz + <f64>bm[o + 13]) * iw * w0;
                vz += (<f64>bm[o + 2] * bx + <f64>bm[o + 6] * by + <f64>bm[o + 10] * bz + <f64>bm[o + 14]) * iw * w0;
            }
        }
        if (w1 != 0) {
            const b = <i32>si.getY(index);
            if (b >= 0 && b < boneCount) {
                const o = b * 16;
                const iw = 1 / (<f64>bm[o + 3] * bx + <f64>bm[o + 7] * by + <f64>bm[o + 11] * bz + <f64>bm[o + 15]);
                vx += (<f64>bm[o] * bx + <f64>bm[o + 4] * by + <f64>bm[o + 8] * bz + <f64>bm[o + 12]) * iw * w1;
                vy += (<f64>bm[o + 1] * bx + <f64>bm[o + 5] * by + <f64>bm[o + 9] * bz + <f64>bm[o + 13]) * iw * w1;
                vz += (<f64>bm[o + 2] * bx + <f64>bm[o + 6] * by + <f64>bm[o + 10] * bz + <f64>bm[o + 14]) * iw * w1;
            }
        }
        if (w2 != 0) {
            const b = <i32>si.getZ(index);
            if (b >= 0 && b < boneCount) {
                const o = b * 16;
                const iw = 1 / (<f64>bm[o + 3] * bx + <f64>bm[o + 7] * by + <f64>bm[o + 11] * bz + <f64>bm[o + 15]);
                vx += (<f64>bm[o] * bx + <f64>bm[o + 4] * by + <f64>bm[o + 8] * bz + <f64>bm[o + 12]) * iw * w2;
                vy += (<f64>bm[o + 1] * bx + <f64>bm[o + 5] * by + <f64>bm[o + 9] * bz + <f64>bm[o + 13]) * iw * w2;
                vz += (<f64>bm[o + 2] * bx + <f64>bm[o + 6] * by + <f64>bm[o + 10] * bz + <f64>bm[o + 14]) * iw * w2;
            }
        }
        if (w3 != 0) {
            const b = <i32>si.getW(index);
            if (b >= 0 && b < boneCount) {
                const o = b * 16;
                const iw = 1 / (<f64>bm[o + 3] * bx + <f64>bm[o + 7] * by + <f64>bm[o + 11] * bz + <f64>bm[o + 15]);
                vx += (<f64>bm[o] * bx + <f64>bm[o + 4] * by + <f64>bm[o + 8] * bz + <f64>bm[o + 12]) * iw * w3;
                vy += (<f64>bm[o + 1] * bx + <f64>bm[o + 5] * by + <f64>bm[o + 9] * bz + <f64>bm[o + 13]) * iw * w3;
                vz += (<f64>bm[o + 2] * bx + <f64>bm[o + 6] * by + <f64>bm[o + 10] * bz + <f64>bm[o + 14]) * iw * w3;
            }
        }
        vector.set(vx, vy, vz);
        return vector.applyMatrix4(this.bindMatrixInverse);
    }

    computeBoundingBox(): void {
        let box = this.boundingBox;
        if (box == null) {
            box = new Box3();
            this.boundingBox = box;
        }
        box.makeEmpty();
        const geometry = this.geometry;
        const p = geometry.getAttribute("position");
        if (p == null) return;
        const skeleton = this.skeleton;
        const si = geometry.getAttribute("skinIndex");
        const sw = geometry.getAttribute("skinWeight");
        const hasSkin = skeleton != null && si != null && sw != null;
        if (hasSkin) skeleton!.update();
        const bm = hasSkin ? skeleton!.boneMatrices : null;
        const boneCount = hasSkin ? skeleton!.bones.length : 0;
        const influences = this.morphTargetInfluences;
        const hasMorph = influences.length > 0 && geometry.morphAttributes.has("position");
        const morph = hasMorph ? geometry.morphAttributes.get("position") : null;
        const morphRel = geometry.morphTargetsRelative;
        const pArr = p.array;
        const pStride = p.itemSize;
        for (let i = 0; i < p.count; i++) {
            const po = i * pStride;
            _point.set(<f64>pArr[po], <f64>pArr[po + 1], <f64>pArr[po + 2]);
            if (hasMorph) this.applyMorph(i, _point, morph!, influences, morphRel);
            if (hasSkin) this.applyBoneMatrices(i, _point, si!, sw!, bm!, boneCount);
            box.expandByPoint(_point);
        }
    }

    computeBoundingSphere(): void {
        let sphere = this.boundingSphere;
        if (sphere == null) {
            sphere = new Sphere();
            this.boundingSphere = sphere;
        }
        sphere.makeEmpty();
        const geometry = this.geometry;
        const p = geometry.getAttribute("position");
        if (p == null) return;
        const skeleton = this.skeleton;
        const si = geometry.getAttribute("skinIndex");
        const sw = geometry.getAttribute("skinWeight");
        const hasSkin = skeleton != null && si != null && sw != null;
        if (hasSkin) skeleton!.update();
        const bm = hasSkin ? skeleton!.boneMatrices : null;
        const boneCount = hasSkin ? skeleton!.bones.length : 0;
        const influences = this.morphTargetInfluences;
        const hasMorph = influences.length > 0 && geometry.morphAttributes.has("position");
        const morph = hasMorph ? geometry.morphAttributes.get("position") : null;
        const morphRel = geometry.morphTargetsRelative;
        const pArr = p.array;
        const pStride = p.itemSize;
        for (let i = 0; i < p.count; i++) {
            const po = i * pStride;
            _point.set(<f64>pArr[po], <f64>pArr[po + 1], <f64>pArr[po + 2]);
            if (hasMorph) this.applyMorph(i, _point, morph!, influences, morphRel);
            if (hasSkin) this.applyBoneMatrices(i, _point, si!, sw!, bm!, boneCount);
            sphere.expandByPoint(_point);
        }
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
