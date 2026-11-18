// three.js Object3D: a transform with children. Y up, right handed;
// cameras and lights look down their -Z.

import { EventDispatcher, Event } from "./EventDispatcher";
import { Material } from "../materials/Material";
import { Vector3 } from "../math/Vector3";
import { Quaternion } from "../math/Quaternion";
import { Euler } from "../math/Euler";
import { Matrix4 } from "../math/Matrix4";
import { Matrix3 } from "../math/Matrix3";
import { Layers } from "./Layers";
import { Raycaster, Intersection } from "./Raycaster";

let _object3DId: i32 = 0;

export class Object3D extends EventDispatcher {
    static DEFAULT_UP: Vector3 = new Vector3(0, 1, 0);
    static DEFAULT_MATRIX_AUTO_UPDATE: bool = true;
    static DEFAULT_MATRIX_WORLD_AUTO_UPDATE: bool = true;

    readonly isObject3D: bool = true;
    /// Unique per object.
    id: i32;
    name: string = "";
    type: string = "Object3D";
    parent: Object3D? = null;
    children: Array<Object3D> = [];
    up: Vector3 = Object3D.DEFAULT_UP.clone();

    readonly position: Vector3 = new Vector3();
    readonly rotation: Euler;
    readonly quaternion: Quaternion;
    readonly scale: Vector3 = new Vector3(1, 1, 1);

    readonly modelViewMatrix: Matrix4 = new Matrix4();
    readonly normalMatrix: Matrix3 = new Matrix3();
    /// The local transform (position, quaternion, scale while
    /// matrixAutoUpdate).
    matrix: Matrix4 = new Matrix4();
    /// The transform to world space (parent.matrixWorld * matrix).
    matrixWorld: Matrix4 = new Matrix4();
    matrixAutoUpdate: bool = Object3D.DEFAULT_MATRIX_AUTO_UPDATE;
    matrixWorldAutoUpdate: bool = Object3D.DEFAULT_MATRIX_WORLD_AUTO_UPDATE;
    matrixWorldNeedsUpdate: bool = false;

    /// Rendered only when it shares a layer with the camera.
    layers: Layers = new Layers();
    visible: bool = true;
    castShadow: bool = false;
    receiveShadow: bool = false;
    /// The material shadow passes use instead of the object's (its map,
    /// alphaTest, displacement and clipping): customDepthMaterial, or
    /// customDistanceMaterial when only that is set (one material serves
    /// every light here).
    customDepthMaterial: Material? = null;
    customDistanceMaterial: Material? = null;
    frustumCulled: bool = true;
    /// Draws sort by renderOrder first (lower first), then by depth.
    renderOrder: i32 = 0;

    constructor() {
        super();
        this.id = _object3DId++;
        const r = new Euler();
        const q = new Quaternion();
        r.linked = q;
        q.linked = r;
        this.rotation = r;
        this.quaternion = q;
    }

    /// Cameras and lights face their -Z (lookAt, getWorldDirection).
    facesNegativeZ(): bool { return false; }

    /// Adds this object's hits by `raycaster` to `intersects` (three.js's
    /// raycast; empty for objects with nothing to hit). Return false to stop
    /// the raycaster descending into the children.
    raycast(raycaster: Raycaster, intersects: Array<Intersection>): bool { return true; }

    // ------------------------------------------------------------- hierarchy

    /// Adds `object` as a child, removing it from its former parent.
    add(object: Object3D): Object3D {
        if (object === this) return this;
        object.removeFromParent();
        object.parent = this;
        this.children.push(object);
        object.notify("added", null);
        this.notify("childadded", object);
        return this;
    }

    remove(object: Object3D): Object3D {
        const i = this.children.indexOf(object);
        if (i >= 0) {
            this.children.splice(i, 1);
            object.parent = null;
            object.notify("removed", null);
            this.notify("childremoved", object);
        }
        return this;
    }

    /// Dispatches `type` when something listens (internal).
    protected notify(type: string, child: Object3D?): void {
        if (!this.hasListeners(type)) return;
        const e = new Event(type);
        e.child = child;
        this.dispatchEvent(e);
    }

    removeFromParent(): Object3D {
        const p = this.parent;
        if (p != null) p.remove(this);
        return this;
    }

    clear(): Object3D {
        const children = this.children;
        this.children = [];
        for (let i = 0; i < children.length; i++) {
            children[i].parent = null;
            children[i].notify("removed", null);
            this.notify("childremoved", children[i]);
        }
        return this;
    }

    /// Adds `object` as a child, keeping its world transform.
    attach(object: Object3D): Object3D {
        this.updateWorldMatrix(true, false);
        _m1.copy(this.matrixWorld).invert();
        const p = object.parent;
        if (p != null) {
            p.updateWorldMatrix(true, false);
            _m1.multiply(p.matrixWorld);
        }
        object.applyMatrix4(_m1);
        object.removeFromParent();
        object.parent = this;
        this.children.push(object);
        object.updateWorldMatrix(false, true);
        object.notify("added", null);
        this.notify("childadded", object);
        return this;
    }

    getObjectById(id: i32): Object3D? {
        if (this.id == id) return this;
        for (let i = 0; i < this.children.length; i++) {
            const found = this.children[i].getObjectById(id);
            if (found != null) return found;
        }
        return null;
    }

    /// This object or the first descendant (depth first) called `name`.
    getObjectByName(name: string): Object3D? {
        if (this.name == name) return this;
        for (let i = 0; i < this.children.length; i++) {
            const found = this.children[i].getObjectByName(name);
            if (found != null) return found;
        }
        return null;
    }

    /// Calls `callback` on this object and every descendant, depth first.
    /// AnimaScript has no closures: pass a function that captures nothing.
    traverse(callback: (object: Object3D) => void): void {
        callback(this);
        const children = this.children;
        for (let i = 0; i < children.length; i++) children[i].traverse(callback);
    }

    /// As traverse, skipping hidden objects and what is under them.
    traverseVisible(callback: (object: Object3D) => void): void {
        if (!this.visible) return;
        callback(this);
        const children = this.children;
        for (let i = 0; i < children.length; i++) children[i].traverseVisible(callback);
    }

    traverseAncestors(callback: (object: Object3D) => void): void {
        const p = this.parent;
        if (p != null) {
            callback(p);
            p.traverseAncestors(callback);
        }
    }

    // ------------------------------------------------------------- transform

    applyMatrix4(matrix: Matrix4): void {
        if (this.matrixAutoUpdate) this.updateMatrix();
        this.matrix.premultiply(matrix);
        this.matrix.decompose(this.position, this.quaternion, this.scale);
    }

    applyQuaternion(q: Quaternion): Object3D {
        this.quaternion.premultiply(q);
        return this;
    }

    setRotationFromAxisAngle(axis: Vector3, angle: f64): void { this.quaternion.setFromAxisAngle(axis, angle); }
    setRotationFromEuler(euler: Euler): void { this.quaternion.setFromEuler(euler); }
    setRotationFromMatrix(m: Matrix4): void { this.quaternion.setFromRotationMatrix(m); }
    setRotationFromQuaternion(q: Quaternion): void { this.quaternion.copy(q); }

    /// Rotates about local unit `axis` by `angle` radians.
    rotateOnAxis(axis: Vector3, angle: f64): Object3D {
        _q1.setFromAxisAngle(axis, angle);
        this.quaternion.multiply(_q1);
        return this;
    }

    /// Rotates about world unit `axis` (assumes no rotated parent).
    rotateOnWorldAxis(axis: Vector3, angle: f64): Object3D {
        _q1.setFromAxisAngle(axis, angle);
        this.quaternion.premultiply(_q1);
        return this;
    }

    rotateX(angle: f64): Object3D { return this.rotateOnAxis(_xAxis, angle); }
    rotateY(angle: f64): Object3D { return this.rotateOnAxis(_yAxis, angle); }
    rotateZ(angle: f64): Object3D { return this.rotateOnAxis(_zAxis, angle); }

    /// Moves along local unit `axis` by `distance`.
    translateOnAxis(axis: Vector3, distance: f64): Object3D {
        _v1.copy(axis).applyQuaternion(this.quaternion);
        this.position.add(_v1.multiplyScalar(distance));
        return this;
    }

    translateX(distance: f64): Object3D { return this.translateOnAxis(_xAxis, distance); }
    translateY(distance: f64): Object3D { return this.translateOnAxis(_yAxis, distance); }
    translateZ(distance: f64): Object3D { return this.translateOnAxis(_zAxis, distance); }

    localToWorld(vector: Vector3): Vector3 {
        this.updateWorldMatrix(true, false);
        return vector.applyMatrix4(this.matrixWorld);
    }

    worldToLocal(vector: Vector3): Vector3 {
        this.updateWorldMatrix(true, false);
        return vector.applyMatrix4(_m1.copy(this.matrixWorld).invert());
    }

    /// Turns the object to face a world point: `lookAt(vector)` or
    /// `lookAt(x, y, z)`. Cameras and lights point their -Z at it, other
    /// objects their +Z.
    lookAt<T>(x: T, y: f64 = 0, z: f64 = 0): void {
        if (isReference<T>()) {
            if (x instanceof Vector3) _target.copy(x as Vector3);
        } else {
            _target.set(<f64>x, y, z);
        }
        const parent = this.parent;
        this.updateWorldMatrix(true, false);
        _position.setFromMatrixPosition(this.matrixWorld);
        if (this.facesNegativeZ()) _m1.lookAt(_position, _target, this.up);
        else _m1.lookAt(_target, _position, this.up);
        this.quaternion.setFromRotationMatrix(_m1);
        if (parent != null) {
            _m1.extractRotation(parent.matrixWorld);
            _q1.setFromRotationMatrix(_m1);
            this.quaternion.premultiply(_q1.invert());
        }
    }

    getWorldPosition(target: Vector3): Vector3 {
        this.updateWorldMatrix(true, false);
        return target.setFromMatrixPosition(this.matrixWorld);
    }

    getWorldQuaternion(target: Quaternion): Quaternion {
        this.updateWorldMatrix(true, false);
        this.matrixWorld.decompose(_position, target, _scale);
        return target;
    }

    getWorldScale(target: Vector3): Vector3 {
        this.updateWorldMatrix(true, false);
        this.matrixWorld.decompose(_position, _q1, target);
        return target;
    }

    /// The world direction the object faces: +Z, or -Z for cameras and
    /// lights.
    getWorldDirection(target: Vector3): Vector3 {
        this.updateWorldMatrix(true, false);
        const e = this.matrixWorld.elements;
        const sign: f64 = this.facesNegativeZ() ? -1 : 1;
        return target.set(<f64>e[8] * sign, <f64>e[9] * sign, <f64>e[10] * sign).normalize();
    }

    updateMatrix(): void {
        this.matrix.compose(this.position, this.quaternion, this.scale);
        this.matrixWorldNeedsUpdate = true;
    }

    /// Updates matrix (when automatic) and matrixWorld of this object and
    /// its descendants. The renderer calls it on the scene every frame.
    updateMatrixWorld(force: bool = false): void {
        if (this.matrixAutoUpdate) this.updateMatrix();
        if (this.matrixWorldNeedsUpdate || force) {
            if (this.matrixWorldAutoUpdate) {
                const p = this.parent;
                if (p == null) this.matrixWorld.copy(this.matrix);
                else this.matrixWorld.multiplyMatrices(p.matrixWorld, this.matrix);
            }
            this.matrixWorldNeedsUpdate = false;
            force = true;
        }
        const children = this.children;
        for (let i = 0; i < children.length; i++) children[i].updateMatrixWorld(force);
    }

    /// Updates matrixWorld, optionally of the ancestors first and of the
    /// descendants after.
    updateWorldMatrix(updateParents: bool, updateChildren: bool): void {
        const p = this.parent;
        if (updateParents && p != null) p.updateWorldMatrix(true, false);
        if (this.matrixAutoUpdate) this.updateMatrix();
        if (this.matrixWorldAutoUpdate) {
            if (p == null) this.matrixWorld.copy(this.matrix);
            else this.matrixWorld.multiplyMatrices(p.matrixWorld, this.matrix);
        }
        if (updateChildren) {
            const children = this.children;
            for (let i = 0; i < children.length; i++) children[i].updateWorldMatrix(false, true);
        }
    }

    /// three.js's copy: name, transform, flags and (recursive) clones of the
    /// children. Subclasses copy their own fields after `super.copy`.
    copy(source: Object3D, recursive: bool = true): Object3D {
        this.copyTransform(source);
        this.matrixWorldAutoUpdate = source.matrixWorldAutoUpdate;
        this.matrixWorldNeedsUpdate = source.matrixWorldNeedsUpdate;
        this.customDepthMaterial = source.customDepthMaterial;
        this.customDistanceMaterial = source.customDistanceMaterial;
        if (recursive) {
            for (let i = 0; i < source.children.length; i++) this.add(source.children[i].clone(true));
        }
        return this;
    }

    /// A new object of the same class, copied (with cloned children when
    /// `recursive`). Geometries and materials are shared, as three.js.
    clone(recursive: bool = true): Object3D {
        return new Object3D().copy(this, recursive);
    }

    /// Copies the name, transform and flags of `source`, not its children
    /// (three.js `copy(source, false)` without the rest).
    copyTransform(source: Object3D): Object3D {
        this.name = source.name;
        this.up.copy(source.up);
        this.position.copy(source.position);
        this.quaternion.copy(source.quaternion);
        this.scale.copy(source.scale);
        this.matrix.copy(source.matrix);
        this.matrixWorld.copy(source.matrixWorld);
        this.matrixAutoUpdate = source.matrixAutoUpdate;
        this.visible = source.visible;
        this.castShadow = source.castShadow;
        this.receiveShadow = source.receiveShadow;
        this.frustumCulled = source.frustumCulled;
        this.renderOrder = source.renderOrder;
        this.layers.mask = source.layers.mask;
        return this;
    }
}

const _v1: Vector3 = new Vector3();
const _q1: Quaternion = new Quaternion();
const _m1: Matrix4 = new Matrix4();
const _target: Vector3 = new Vector3();
const _position: Vector3 = new Vector3();
const _scale: Vector3 = new Vector3();
const _xAxis: Vector3 = new Vector3(1, 0, 0);
const _yAxis: Vector3 = new Vector3(0, 1, 0);
const _zAxis: Vector3 = new Vector3(0, 0, 1);
