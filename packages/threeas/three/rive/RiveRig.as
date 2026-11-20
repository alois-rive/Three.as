// Rive animation driving three.js objects: a Rive artboard's bones and
// nodes, posed by its state machine or a timeline, retargeted onto
// three.js Bones (a Skeleton) or any Object3D, live or baked into an
// AnimationClip.
//
//     const rig = new RiveRig(armArtboard!);          // an artboard input
//     rig.mapSkeleton(mesh.skeleton!);                // Rive bones named as the three.js bones
//     rig.play("Wave");                               // or let its state machine run
//     ...
//     rig.advance(seconds);                           // poses the artboard, then the bones
//
//     const clip = rig.bake("Wave", 30);              // a three.js AnimationClip of it
//
// The Rive rig lies in the three.js objects' XY plane: Rive x right and y
// down become x right and y up, Rive's clockwise rotation a rotation about
// -Z (`axis`), Rive units times `unitsPerPixel`. By default a mapped
// object keeps its own rest pose and takes the node's change from the
// pose it had when mapped (RiveRig.RELATIVE): a 3D skeleton modelled in
// another pose follows the 2D rig's motion. RiveRig.ABSOLUTE copies the
// node's local transform as copyNodeTransform does.
//
// What Rive's scripting API allows: nodes and bones are found by name
// (`artboard.node`, names exported), and read as local x, y, rotation and
// scale (or a world Mat2D). An artboard's nodes cannot be listed, a bone's
// length and a mesh's skin weights cannot be read, and a timeline's keys
// are not exposed: `bake` samples a timeline by setting its time.

import { Artboard, NodeData, Animation } from "rive/artboard";
import { Mat2D } from "rive/mat2d";
import { Object3D } from "../core/Object3D";
import { Skeleton } from "../objects/Skeleton";
import { Vector3 } from "../math/Vector3";
import { Quaternion } from "../math/Quaternion";
import { AnimationClip } from "../animation/AnimationClip";
import { KeyframeTrack, VectorKeyframeTrack, QuaternionKeyframeTrack } from "../animation/KeyframeTrack";
import { PropertyBinding } from "../animation/PropertyBinding";

/// One Rive node driving one Object3D.
export class RiveNodeMapping {
    readonly name: string;
    readonly node: NodeData;
    readonly object: Object3D;
    /// RiveRig.RELATIVE or RiveRig.ABSOLUTE.
    mode: i32;
    /// Which channels to copy.
    position: bool = true;
    rotation: bool = true;
    scale: bool = true;
    // The Rive node's rest pose and the object's, at mapping time.
    restX: f64 = 0;
    restY: f64 = 0;
    restRotation: f64 = 0;
    restScaleX: f64 = 1;
    restScaleY: f64 = 1;
    readonly restPosition: Vector3 = new Vector3();
    readonly restQuaternion: Quaternion = new Quaternion();
    readonly restScale: Vector3 = new Vector3(1, 1, 1);

    constructor(name: string, node: NodeData, object: Object3D, mode: i32) {
        this.name = name;
        this.node = node;
        this.object = object;
        this.mode = mode;
        this.captureRest();
    }

    /// Takes the node's and the object's current poses as the rest poses.
    captureRest(): void {
        const n = this.node;
        this.restX = n.x;
        this.restY = n.y;
        this.restRotation = n.rotation;
        this.restScaleX = n.scaleX;
        this.restScaleY = n.scaleY;
        this.restPosition.copy(this.object.position);
        this.restQuaternion.copy(this.object.quaternion);
        this.restScale.copy(this.object.scale);
    }
}

export class RiveRig {
    /// Deltas from the rest poses (the default).
    static readonly RELATIVE: i32 = 0;
    /// The node's local transform as it is (copyNodeTransform).
    static readonly ABSOLUTE: i32 = 1;

    /// The artboard instance read (and drawn, if you draw it).
    readonly artboard: Artboard;
    /// World units per Rive unit.
    unitsPerPixel: f64 = 0.01;
    /// The axis Rive rotations turn about (Rive turns clockwise on screen,
    /// so -Z in a y-up XY plane).
    readonly axis: Vector3 = new Vector3(0, 0, -1);
    readonly mappings: Array<RiveNodeMapping> = [];
    /// Rive node names `map` and `mapSkeleton` could not find.
    readonly missing: Array<string> = [];
    /// The timeline `play` started, null while the state machine poses it.
    animation: Animation? = null;
    /// Seconds into `animation`.
    time: f64 = 0;
    /// Loop the played timeline (else it holds its last frame).
    loop: bool = true;
    private animationName: string = "";
    // Whether it made the instance (and releases it on dispose).
    private ownsArtboard: bool;
    /// Whether dispose() ran: advance and apply do nothing.
    disposed: bool = false;

    /// Instances `artboard` (pass `instance = false` to read it as it is).
    constructor(artboard: Artboard, instance: bool = true) {
        this.artboard = instance ? artboard.instance() : artboard;
        this.ownsArtboard = instance;
        this.artboard.advance(0);
    }

    /// Forgets the mappings and releases the played timeline and the
    /// artboard instance it made (not one passed with `instance = false`).
    dispose(): void {
        if (this.disposed) return;
        this.disposed = true;
        const a = this.animation;
        if (a != null) a.release();
        this.animation = null;
        this.animationName = "";
        this.mappings.length = 0;
        if (this.ownsArtboard) this.artboard.release();
    }

    /// Maps Rive node `name` onto `object`; false when the artboard has no
    /// such (exported) node.
    map(name: string, object: Object3D, mode: i32 = RiveRig.RELATIVE): RiveNodeMapping? {
        if (this.disposed) return null;
        const node = this.artboard.node(name);
        if (node == null) {
            if (this.missing.indexOf(name) < 0) this.missing.push(name);
            return null;
        }
        const m = new RiveNodeMapping(name, node, object, mode);
        this.mappings.push(m);
        return m;
    }

    /// Maps every bone of `skeleton` to the Rive node of the same name (or
    /// `prefix` + name); returns how many were found.
    mapSkeleton(skeleton: Skeleton, prefix: string = "", mode: i32 = RiveRig.RELATIVE): i32 {
        let found = 0;
        for (let i = 0; i < skeleton.bones.length; i++) {
            const bone = skeleton.bones[i];
            if (this.map(prefix + bone.name, bone, mode) != null) found++;
        }
        return found;
    }

    /// The mapping of `object`, or null.
    mappingOf(object: Object3D): RiveNodeMapping? {
        for (let i = 0; i < this.mappings.length; i++) if (this.mappings[i].object === object) return this.mappings[i];
        return null;
    }

    /// Plays the timeline `name` by hand (the artboard should have no
    /// default state machine, which would pose it over the timeline).
    /// Returns false when there is no such timeline.
    play(name: string): bool {
        if (this.disposed) return false;
        const a = this.artboard.animation(name);
        if (a == null) return false;
        const prev = this.animation;
        if (prev != null) prev.release();
        this.animation = a;
        this.animationName = name;
        this.time = 0;
        a.setTime(0);
        this.artboard.advance(0);
        return true;
    }

    /// Stops a played timeline: the state machine poses the artboard again.
    stop(): void {
        const prev = this.animation;
        if (prev != null) prev.release();
        this.animation = null;
        this.animationName = "";
    }

    /// Advances the played timeline (or the artboard's state machine) by
    /// `seconds`, then poses the mapped objects. Returns what the artboard's
    /// advance returns.
    advance(seconds: f64): bool {
        if (this.disposed) return false;
        const a = this.animation;
        let changed: bool;
        if (a != null) {
            this.time += seconds;
            const d = a.duration;
            if (d > 0) this.time = this.loop ? this.time - Math.floor(this.time / d) * d : Math.min(this.time, d);
            a.setTime(this.time);
            changed = this.artboard.advance(0);
        } else {
            changed = this.artboard.advance(seconds);
        }
        this.apply();
        return changed;
    }

    /// Poses every mapped object from its node as the artboard stands.
    apply(): void {
        if (this.disposed) return;
        for (let i = 0; i < this.mappings.length; i++) this.applyMapping(this.mappings[i]);
    }

    private applyMapping(m: RiveNodeMapping): void {
        const n = m.node;
        const o = m.object;
        const upp = this.unitsPerPixel;
        if (m.mode == RiveRig.ABSOLUTE) {
            if (m.position) { o.position.x = n.x * upp; o.position.y = -n.y * upp; }
            if (m.rotation) o.quaternion.setFromAxisAngle(this.axis, n.rotation);
            if (m.scale) { o.scale.x = n.scaleX; o.scale.y = n.scaleY; }
            return;
        }
        if (m.position) {
            o.position.set(m.restPosition.x + (n.x - m.restX) * upp, m.restPosition.y - (n.y - m.restY) * upp,
                m.restPosition.z);
        }
        if (m.rotation) {
            _q.setFromAxisAngle(this.axis, n.rotation - m.restRotation);
            o.quaternion.copy(m.restQuaternion).multiply(_q);
        }
        if (m.scale) {
            o.scale.set(m.restScale.x * safeRatio(n.scaleX, m.restScaleX), m.restScale.y * safeRatio(n.scaleY, m.restScaleY),
                m.restScale.z);
        }
    }

    /// Samples timeline `name` at `fps` into a three.js AnimationClip:
    /// position, quaternion and scale tracks for every mapped object (named
    /// after the object, which needs a name the mixer can find). The rig is
    /// left posed as before. Null when there is no such timeline.
    bake(name: string, fps: f64 = 30, clipName: string = ""): AnimationClip? {
        if (this.disposed || !(fps > 0)) return null;
        const a = this.artboard.animation(name);
        if (a == null) return null;
        const duration = a.duration;
        const frames = max<i32>(1, <i32>Math.ceil(duration * fps));
        const count = this.mappings.length;
        // Save the objects' poses (applyMapping writes them).
        const saved: Array<Object3D> = [];
        for (let i = 0; i < count; i++) {
            const o = this.mappings[i].object;
            const copy = new Object3D();
            copy.position.copy(o.position); copy.quaternion.copy(o.quaternion); copy.scale.copy(o.scale);
            saved.push(copy);
        }
        const times: Array<f64> = [];
        const positions: Array<Array<f64>> = [];
        const quaternions: Array<Array<f64>> = [];
        const scales: Array<Array<f64>> = [];
        for (let i = 0; i < count; i++) { positions.push([]); quaternions.push([]); scales.push([]); }
        for (let f = 0; f <= frames; f++) {
            const t = Math.min(duration, <f64>f / fps);
            a.setTime(t);
            this.artboard.advance(0);
            times.push(t);
            for (let i = 0; i < count; i++) {
                const m = this.mappings[i];
                this.applyMapping(m);
                const o = m.object;
                positions[i].push(o.position.x); positions[i].push(o.position.y); positions[i].push(o.position.z);
                quaternions[i].push(o.quaternion.x); quaternions[i].push(o.quaternion.y);
                quaternions[i].push(o.quaternion.z); quaternions[i].push(o.quaternion.w);
                scales[i].push(o.scale.x); scales[i].push(o.scale.y); scales[i].push(o.scale.z);
            }
            if (t >= duration) break;
        }
        const tracks: Array<KeyframeTrack> = [];
        for (let i = 0; i < count; i++) {
            const m = this.mappings[i];
            const node = PropertyBinding.sanitizeNodeName(m.object.name);
            if (m.position) tracks.push(new VectorKeyframeTrack(node + ".position", times, positions[i]));
            if (m.rotation) tracks.push(new QuaternionKeyframeTrack(node + ".quaternion", times, quaternions[i]));
            if (m.scale) tracks.push(new VectorKeyframeTrack(node + ".scale", times, scales[i]));
        }
        for (let i = 0; i < count; i++) {
            const o = this.mappings[i].object;
            o.position.copy(saved[i].position); o.quaternion.copy(saved[i].quaternion); o.scale.copy(saved[i].scale);
        }
        // Back to where the played timeline (if any) was.
        const playing = this.animation;
        if (playing != null) playing.setTime(this.time);
        this.artboard.advance(0);
        a.release();
        return new AnimationClip(clipName.length > 0 ? clipName : name, duration, tracks).optimize();
    }

    /// A node's world position in the XY plane
    /// (Rive units times `unitsPerPixel`, y flipped), for placing objects
    /// on a node without a mapping.
    worldPosition(name: string, target: Vector3): Vector3? {
        if (this.disposed) return null;
        const node = this.artboard.node(name);
        if (node == null) return null;
        const w: Mat2D = node.worldTransform();
        return target.set(<f64>w.tx * this.unitsPerPixel, -<f64>w.ty * this.unitsPerPixel, 0);
    }
}

function safeRatio(a: f64, b: f64): f64 {
    return Math.abs(b) > 1e-9 ? a / b : a;
}

const _q = new Quaternion();
