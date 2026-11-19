// three.js SkeletonHelper: a line from each bone to its parent bone,
// recomputed every frame (updateMatrixWorld).

import { LineSegments } from "../objects/Line";
import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { Object3D } from "../core/Object3D";
import { Bone } from "../objects/Skeleton";
import { Matrix4 } from "../math/Matrix4";
import { Vector3 } from "../math/Vector3";

const _vector = new Vector3();
const _boneMatrix = new Matrix4();
const _inverse = new Matrix4();

function collectBones(o: Object3D, out: Array<Bone>): void {
    if (o instanceof Bone) out.push(o as Bone);
    for (let i = 0; i < o.children.length; i++) collectBones(o.children[i], out);
}

export class SkeletonHelper extends LineSegments {
    root: Object3D;
    bones: Array<Bone> = [];

    constructor(object: Object3D) {
        const bones: Array<Bone> = [];
        collectBones(object, bones);
        const vertices: Array<f64> = [];
        const colors: Array<f64> = [];
        for (let i = 0; i < bones.length; i++) {
            const bone = bones[i];
            if (bone.parent != null && bone.parent instanceof Bone) {
                for (let k = 0; k < 6; k++) vertices.push(0);
                colors.push(0); colors.push(0); colors.push(1);
                colors.push(0); colors.push(1); colors.push(0);
            }
        }
        const geometry = new BufferGeometry();
        geometry.setAttribute("position", new Float32BufferAttribute(vertices, 3));
        geometry.setAttribute("color", new Float32BufferAttribute(colors, 3));
        super(geometry, new LineBasicMaterial({ vertexColors: true, depthTest: false, depthWrite: false,
            toneMapped: false, transparent: true }));
        this.type = "SkeletonHelper";
        this.root = object;
        this.bones = bones;
        this.matrix = object.matrixWorld;
        this.matrixAutoUpdate = false;
    }

    override updateMatrixWorld(force: bool = false): void {
        const a = this.geometry.getAttribute("position")!;
        _inverse.copy(this.root.matrixWorld).invert();
        let j = 0;
        for (let i = 0; i < this.bones.length; i++) {
            const bone = this.bones[i];
            const parent = bone.parent;
            if (parent != null && parent instanceof Bone) {
                _boneMatrix.multiplyMatrices(_inverse, bone.matrixWorld);
                _vector.setFromMatrixPosition(_boneMatrix);
                a.setXYZ(j, _vector.x, _vector.y, _vector.z);
                _boneMatrix.multiplyMatrices(_inverse, parent!.matrixWorld);
                _vector.setFromMatrixPosition(_boneMatrix);
                a.setXYZ(j + 1, _vector.x, _vector.y, _vector.z);
                j += 2;
            }
        }
        a.needsUpdate = true;
        super.updateMatrixWorld(force);
    }

    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}
