// three.js Bone and Skeleton.

import { Object3D } from "../core/Object3D";
import { Event, EventDispatcher } from "../core/EventDispatcher";
import { Matrix4 } from "../math/Matrix4";
import { MathUtils } from "../math/MathUtils";
import { Dynamic } from "rive/dynamic";
import { jsonMetadata, jhas, jstr, jarr, asStr, asNumbers } from "../core/JSON";

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
export class Skeleton extends EventDispatcher {
    bones: Array<Bone>;
    boneInverses: Array<Matrix4>;
    boneMatrices: Float32Array;
    /// The renderer's frame of the last update (one a frame).
    frame: i32 = -1;
    private _uuid: string = "";

    constructor(bones: Array<Bone> = [], boneInverses: Array<Matrix4> = []) {
        super();
        this.bones = bones;
        this.boneInverses = boneInverses;
        this.boneMatrices = new Float32Array(bones.length * 16);
        if (boneInverses.length == 0) this.calculateInverses();
        else if (boneInverses.length != bones.length) {
            this.boneInverses = [];
            for (let i = 0; i < bones.length; i++) this.boneInverses.push(new Matrix4());
        }
    }

    /// A random uuid, made on first use.
    get uuid(): string {
        if (this._uuid.length == 0) this._uuid = MathUtils.generateUUID();
        return this._uuid;
    }
    set uuid(value: string) { this._uuid = value; }

    /// three.js's JSON: { metadata, uuid, bones (uuids), boneInverses }.
    toJSON(): Dynamic {
        const data = Dynamic.newTable();
        data.set("metadata", jsonMetadata("Skeleton", "Skeleton.toJSON"));
        const bones = Dynamic.newTable();
        const inverses = Dynamic.newTable();
        for (let i = 0; i < this.bones.length; i++) {
            bones.push(Dynamic.fromString(this.bones[i].uuid));
            inverses.push(Dynamic.fromNumbers(this.boneInverses[i].toArray()));
        }
        data.set("bones", bones);
        data.set("boneInverses", inverses);
        data.set("uuid", Dynamic.fromString(this.uuid));
        return data;
    }

    /// Reads toJSON's output; `bones` are the scene's bones by uuid (a
    /// missing one becomes a new Bone, as three.js).
    fromJSON(json: Dynamic?, bones: Map<string, Bone>): Skeleton {
        if (jhas(json, "uuid")) this.uuid = jstr(json, "uuid", "");
        this.bones = [];
        this.boneInverses = [];
        const uuids = jarr(json, "bones");
        const inverses = jarr(json, "boneInverses");
        for (let i = 0; i < uuids.length; i++) {
            const uuid = asStr(uuids[i]);
            this.bones.push(bones.has(uuid) ? bones.get(uuid) : new Bone());
            const inverse = new Matrix4();
            const values = i < inverses.length ? asNumbers(inverses[i]) : null;
            if (values != null && values.length >= 16) inverse.fromArray(values!);
            this.boneInverses.push(inverse);
        }
        this.boneMatrices = new Float32Array(this.bones.length * 16);
        return this;
    }

    /// Takes the bones' current world transforms as the bind pose.
    calculateInverses(): void {
        this.boneInverses = [];
        // A bone whose parent was updated earlier in this loop updates
        // alone (long chains stay linear).
        const done = new Set<i32>();
        for (let i = 0; i < this.bones.length; i++) {
            const inverse = new Matrix4();
            const bone = this.bones[i];
            const parent = bone.parent;
            bone.updateWorldMatrix(parent == null || !done.has(parent.id), false);
            done.add(bone.id);
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

    /// Frees the renderers' bone storage of the meshes it skins (three.js
    /// frees its bone texture) at their next render: dispatches "dispose".
    /// The meshes still draw; their bones are uploaded again.
    dispose(): void {
        if (this.hasListeners("dispose")) this.dispatchEvent(new Event("dispose"));
    }
}

const _offset: Matrix4 = new Matrix4();
