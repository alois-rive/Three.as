// three.js Bone and Skeleton.

import { Object3D } from "../core/Object3D";
import { Matrix4 } from "../math/Matrix4";

/// A joint: an Object3D like any other (animate or move it).
export class Bone extends Object3D {
    readonly isBone: bool = true;

    constructor() {
        super();
        this.type = "Bone";
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new Bone().copy(this, recursive);
    }
}

/// The bones deforming a SkinnedMesh, with the inverse of each bone's
/// world transform at bind time. `boneMatrices` (bone.matrixWorld x
/// boneInverse, 16 floats per bone) is refreshed by update().
export class Skeleton {
    bones: Array<Bone>;
    boneInverses: Array<Matrix4>;
    boneMatrices: Float32Array;
    /// The renderer's frame of the last update (one a frame).
    frame: i32 = -1;

    constructor(bones: Array<Bone> = [], boneInverses: Array<Matrix4> = []) {
        this.bones = bones;
        this.boneInverses = boneInverses;
        this.boneMatrices = new Float32Array(bones.length * 16);
        if (boneInverses.length == 0) this.calculateInverses();
        else if (boneInverses.length != bones.length) {
            this.boneInverses = [];
            for (let i = 0; i < bones.length; i++) this.boneInverses.push(new Matrix4());
        }
    }

    /// Takes the bones' current world transforms as the bind pose.
    calculateInverses(): void {
        this.boneInverses = [];
        for (let i = 0; i < this.bones.length; i++) {
            const inverse = new Matrix4();
            const bone = this.bones[i];
            bone.updateWorldMatrix(true, false);
            inverse.copy(bone.matrixWorld).invert();
            this.boneInverses.push(inverse);
        }
    }

    /// Puts the bones back in the bind pose.
    pose(): void {
        for (let i = 0; i < this.bones.length; i++) {
            this.bones[i].matrixWorld.copy(this.boneInverses[i]).invert();
        }
        for (let i = 0; i < this.bones.length; i++) {
            const bone = this.bones[i];
            const parent = bone.parent;
            if (parent != null && parent instanceof Bone) {
                bone.matrix.copy(parent.matrixWorld).invert();
                bone.matrix.multiply(bone.matrixWorld);
            } else {
                bone.matrix.copy(bone.matrixWorld);
            }
            bone.matrix.decompose(bone.position, bone.quaternion, bone.scale);
        }
    }

    update(): void {
        const out = this.boneMatrices;
        for (let i = 0; i < this.bones.length; i++) {
            _offset.multiplyMatrices(this.bones[i].matrixWorld, this.boneInverses[i]);
            const e = _offset.elements;
            for (let k = 0; k < 16; k++) out[i * 16 + k] = e[k];
        }
    }

    getBoneByName(name: string): Bone? {
        for (let i = 0; i < this.bones.length; i++) if (this.bones[i].name == name) return this.bones[i];
        return null;
    }

    clone(): Skeleton {
        const inverses: Array<Matrix4> = [];
        for (let i = 0; i < this.boneInverses.length; i++) inverses.push(this.boneInverses[i].clone());
        return new Skeleton(this.bones.slice(), inverses);
    }

    dispose(): void {}
}

const _offset: Matrix4 = new Matrix4();
