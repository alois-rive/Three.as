// three.js examples/jsm/utils/SkeletonUtils.js: cloning skinned hierarchies
// (each clone gets its own skeleton over its own bones) and retargeting.

import { Object3D } from "../../core/Object3D";
import { SkinnedMesh } from "../../objects/SkinnedMesh";
import { Skeleton, Bone } from "../../objects/Skeleton";
import { Matrix4 } from "../../math/Matrix4";
import { Quaternion } from "../../math/Quaternion";

function parallel(a: Object3D, b: Object3D, outA: Array<Object3D>, outB: Array<Object3D>): void {
    outA.push(a);
    outB.push(b);
    for (let i = 0; i < a.children.length && i < b.children.length; i++) parallel(a.children[i], b.children[i], outA, outB);
}

/// three.js's SkeletonUtils.clone: `source` cloned, with every SkinnedMesh
/// bound to a new Skeleton over the clone's bones (Object3D.clone shares
/// the skeleton, so clones would move together).
export function clone(source: Object3D): Object3D {
    const cloned = source.clone(true);
    const src: Array<Object3D> = [], dst: Array<Object3D> = [];
    parallel(source, cloned, src, dst);
    for (let i = 0; i < src.length; i++) {
        if (!(src[i] instanceof SkinnedMesh)) continue;
        const s = src[i] as SkinnedMesh;
        const d = dst[i] as SkinnedMesh;
        const skeleton = s.skeleton;
        if (skeleton == null) continue;
        const bones: Array<Bone> = [];
        for (let b = 0; b < skeleton.bones.length; b++) {
            const at = src.indexOf(skeleton.bones[b]);
            bones.push(at >= 0 ? dst[at] as Bone : skeleton.bones[b]);
        }
        const inverses: Array<Matrix4> = [];
        for (let b = 0; b < skeleton.boneInverses.length; b++) inverses.push(skeleton.boneInverses[b].clone());
        d.bind(new Skeleton(bones, inverses), d.bindMatrix);
    }
    return cloned;
}

export function getBoneByName(name: string, skeleton: Skeleton): Bone? {
    for (let i = 0; i < skeleton.bones.length; i++) if (skeleton.bones[i].name == name) return skeleton.bones[i];
    return null;
}

export class RetargetOptions {
    /// Target bone name -> source bone name (same name when absent).
    names: Map<string, string> = new Map<string, string>();
    /// The source's root bone name (its position drives the target's).
    hip: string = "hip";
    /// Scale of the root's motion.
    hipInfluence: f64 = 1;
    /// Also copy the root's position.
    useFirstFramePosition: bool = false;
}

const _q = new Quaternion();

/// Poses `target`'s skeleton like `source`'s: each target bone takes its
/// source bone's local rotation (by name, or `options.names`), and the hip
/// its position times hipInfluence. A simplification of three.js's
/// retarget, which also corrects for differing rest poses.
export function retarget(target: SkinnedMesh, source: SkinnedMesh, options: RetargetOptions? = null): void {
    const o = options != null ? options! : new RetargetOptions();
    const ts = target.skeleton, ss = source.skeleton;
    if (ts == null || ss == null) return;
    for (let i = 0; i < ts.bones.length; i++) {
        const tb = ts.bones[i];
        const name = o.names.has(tb.name) ? o.names.get(tb.name) : tb.name;
        const sb = getBoneByName(name, ss!);
        if (sb == null) continue;
        tb.quaternion.copy(_q.copy(sb.quaternion));
        if (name == o.hip && !o.useFirstFramePosition) {
            tb.position.copy(sb.position).multiplyScalar(o.hipInfluence);
        }
    }
    target.updateMatrixWorld(true);
}
