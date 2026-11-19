// three.js examples/jsm/controls/TransformControls.js: a gizmo to move,
// rotate and scale an object. `getHelper()` is the gizmo to add to the
// scene; add the controls to ThreeLayout's `tools` (so a drag does not
// also orbit). Modes "translate", "rotate", "scale"; space "world" or
// "local"; axis handles, plane handles (XY, YZ, XZ) and uniform scale
// (XYZ); snapping; events "change", "objectChange", "mouseDown",
// "mouseUp", "dragging-changed" (`event.value`). A compact port: the
// gizmo's look is simpler than three.js's (no "E" / "XYZE" rotation
// handles, no eye-aligned picker planes).

import { PointerEvent } from "rive/events";
import { Controls } from "../../extras/Controls";
import { Event } from "../../core/EventDispatcher";
import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { GPURenderer } from "../../renderers/GPURenderer";
import { Raycaster, Intersection } from "../../core/Raycaster";
import { Mesh } from "../../objects/Mesh";
import { MeshBasicMaterial } from "../../materials/MeshBasicMaterial";
import { BufferGeometry } from "../../core/BufferGeometry";
import { CylinderGeometry } from "../../geometries/CylinderGeometry";
import { ConeGeometry } from "../../geometries/ConeGeometry";
import { TorusGeometry } from "../../geometries/TorusGeometry";
import { BoxGeometry } from "../../geometries/BoxGeometry";
import { PlaneGeometry } from "../../geometries/PlaneGeometry";
import { Plane } from "../../math/Plane";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Quaternion } from "../../math/Quaternion";
import { DoubleSide } from "../../constants";

const _pointer = new Vector2();
const _size = new Vector2();
const _plane = new Plane();
const _hit = new Vector3();
const _v = new Vector3();
const _eye = new Vector3();
const _axisWorld = new Vector3();
const _q = new Quaternion();
const _cameraPosition = new Vector3();
const UNIT: StaticArray<Vector3> = [new Vector3(1, 0, 0), new Vector3(0, 1, 0), new Vector3(0, 0, 1)];
const AXIS_COLORS: StaticArray<u32> = [0xff3653, 0x8adb00, 0x2c8fff];
const HOVER_COLOR: u32 = 0xffff00;

/// One handle: what it moves along, its visible part and its picker.
class Handle {
    name: string;
    mode: string;
    visible: Mesh;
    picker: Mesh;
    color: u32;

    constructor(name: string, mode: string, visible: Mesh, picker: Mesh, color: u32) {
        this.name = name;
        this.mode = mode;
        this.visible = visible;
        this.picker = picker;
        this.color = color;
    }
}

function gizmoMaterial(color: u32, opacity: f64 = 1): MeshBasicMaterial {
    return new MeshBasicMaterial({ color: color, depthTest: false, depthWrite: false, transparent: true,
        opacity: opacity, toneMapped: false, fog: false, side: DoubleSide });
}

/// The gizmo (TransformControls.getHelper()): follows the object, scaled to
/// a constant screen size.
export class TransformControlsGizmo extends Object3D {
    controls: TransformControls;

    constructor(controls: TransformControls) {
        super();
        this.controls = controls;
        this.type = "TransformControlsGizmo";
    }

    override updateMatrixWorld(force: bool = false): void {
        this.controls.placeGizmo();
        super.updateMatrixWorld(force);
    }
}

export class TransformControls extends Controls {
    camera: Camera;
    domElement: GPURenderer?;
    attached: Object3D? = null;
    mode: string = "translate";
    space: string = "world";
    size: f64 = 1;
    translationSnap: f64 = 0;
    rotationSnap: f64 = 0;
    scaleSnap: f64 = 0;
    showX: bool = true;
    showY: bool = true;
    showZ: bool = true;
    dragging: bool = false;
    /// The handle under the pointer ("X", "XY", "XYZ"...), or "".
    axis: string = "";
    raycaster: Raycaster = new Raycaster();

    private gizmo: TransformControlsGizmo;
    private handles: Array<Handle> = [];
    private pickers: Array<Object3D> = [];
    private hits: Array<Intersection> = [];
    private pointStart: Vector3 = new Vector3();
    private positionStart: Vector3 = new Vector3();
    private quaternionStart: Quaternion = new Quaternion();
    private scaleStart: Vector3 = new Vector3();
    private worldPosition: Vector3 = new Vector3();
    private worldQuaternion: Quaternion = new Quaternion();
    private parentQuaternionInverse: Quaternion = new Quaternion();
    private planeNormal: Vector3 = new Vector3();

    constructor(camera: Camera, domElement: GPURenderer? = null) {
        super(camera);
        this.camera = camera;
        this.domElement = domElement;
        this.gizmo = new TransformControlsGizmo(this);
        this.buildGizmo();
        this.gizmo.visible = false;
    }

    getHelper(): Object3D { return this.gizmo; }

    attach(object: Object3D): TransformControls {
        this.attached = object;
        this.gizmo.visible = true;
        return this;
    }

    detach(): TransformControls {
        this.attached = null;
        this.gizmo.visible = false;
        this.axis = "";
        return this;
    }

    setMode(mode: string): void { this.mode = mode; this.changed(); }
    setSpace(space: string): void { this.space = space; this.changed(); }
    setSize(size: f64): void { this.size = size; this.changed(); }
    setTranslationSnap(snap: f64): void { this.translationSnap = snap; }
    setRotationSnap(snap: f64): void { this.rotationSnap = snap; }
    setScaleSnap(snap: f64): void { this.scaleSnap = snap; }
    getMode(): string { return this.mode; }

    override capturing(): bool { return this.dragging; }

    // ------------------------------------------------------------ gizmo

    private add(name: string, mode: string, geometry: BufferGeometry, pickerGeometry: BufferGeometry, color: u32,
                opacity: f64, x: f64, y: f64, z: f64, rx: f64, ry: f64, rz: f64): void {
        const visible = new Mesh(geometry, gizmoMaterial(color, opacity));
        visible.position.set(x, y, z);
        visible.rotation.set(rx, ry, rz);
        visible.renderOrder = 1000;
        const picker = new Mesh(pickerGeometry, gizmoMaterial(0xffffff, 0));
        picker.position.copy(visible.position);
        picker.rotation.copy(visible.rotation);
        picker.material.visible = false;
        picker.name = name;
        this.gizmo.add(visible);
        this.gizmo.add(picker);
        this.handles.push(new Handle(name, mode, visible, picker, color));
        this.pickers.push(picker);
    }

    private buildGizmo(): void {
        const shaft = new CylinderGeometry(0.0075, 0.0075, 0.5, 6);
        const head = new ConeGeometry(0.04, 0.1, 12);
        const pickShaft = new CylinderGeometry(0.2, 0, 0.6, 4);
        const square = new PlaneGeometry(0.15, 0.15);
        const pickSquare = new PlaneGeometry(0.2, 0.2);
        const ring = new TorusGeometry(0.5, 0.0075, 4, 64);
        const pickRing = new TorusGeometry(0.5, 0.1, 4, 24);
        const cube = new BoxGeometry(0.08, 0.08, 0.08);
        const pickCube = new BoxGeometry(0.2, 0.2, 0.2);
        const names: StaticArray<string> = ["X", "Y", "Z"];
        const halfPi = Math.PI / 2;
        for (let i = 0; i < 3; i++) {
            const c = AXIS_COLORS[i];
            // Translate: shaft and head along the axis (cylinders are along y).
            const rx: f64 = i == 2 ? halfPi : 0, rz: f64 = i == 0 ? -halfPi : 0;
            const u = UNIT[i];
            this.add(names[i], "translate", shaft, pickShaft, c, 1, u.x * 0.25, u.y * 0.25, u.z * 0.25, rx, 0, rz);
            this.add(names[i], "translate", head, pickShaft, c, 1, u.x * 0.55, u.y * 0.55, u.z * 0.55, rx, 0, rz);
            // Scale: shaft and cube.
            this.add(names[i], "scale", shaft, pickShaft, c, 1, u.x * 0.25, u.y * 0.25, u.z * 0.25, rx, 0, rz);
            this.add(names[i], "scale", cube, pickCube, c, 1, u.x * 0.55, u.y * 0.55, u.z * 0.55, 0, 0, 0);
            // Rotate: a ring around the axis (tori lie in the XY plane).
            this.add(names[i], "rotate", ring, pickRing, c, 1, 0, 0, 0, i == 1 ? halfPi : 0, i == 0 ? halfPi : 0, 0);
        }
        // Plane handles (translate): XY, YZ, XZ.
        this.add("XY", "translate", square, pickSquare, AXIS_COLORS[2], 0.5, 0.15, 0.15, 0, 0, 0, 0);
        this.add("YZ", "translate", square, pickSquare, AXIS_COLORS[0], 0.5, 0, 0.15, 0.15, 0, Math.PI / 2, 0);
        this.add("XZ", "translate", square, pickSquare, AXIS_COLORS[1], 0.5, 0.15, 0, 0.15, -Math.PI / 2, 0, 0);
        // Uniform scale.
        this.add("XYZ", "scale", cube, pickCube, 0xffffff, 0.5, 0, 0, 0, 0, 0, 0);
    }

    /// Places the gizmo on the object, sized for the screen, and shows the
    /// current mode's handles (called from the gizmo's updateMatrixWorld).
    placeGizmo(): void {
        const object = this.attached;
        if (object == null) return;
        object.updateWorldMatrix(true, false);
        object.matrixWorld.decompose(this.worldPosition, this.worldQuaternion, _v);
        const parent = object.parent;
        if (parent != null) {
            parent.updateWorldMatrix(true, false);
            parent.matrixWorld.decompose(_v, this.parentQuaternionInverse, _v);
            this.parentQuaternionInverse.invert();
        } else {
            this.parentQuaternionInverse.identity();
        }
        const g = this.gizmo;
        g.position.copy(this.worldPosition);
        if (this.space == "local" || this.mode == "scale") g.quaternion.copy(this.worldQuaternion);
        else g.quaternion.identity();
        this.camera.updateMatrixWorld();
        _cameraPosition.setFromMatrixPosition(this.camera.matrixWorld);
        let factor: f64;
        if (this.camera instanceof OrthographicCamera) {
            const o = this.camera as OrthographicCamera;
            factor = (o.top - o.bottom) / o.zoom;
        } else {
            const p = this.camera as PerspectiveCamera;
            factor = this.worldPosition.distanceTo(_cameraPosition)
                * Math.min(1.9 * Math.tan(Math.PI * p.fov / 360) / p.zoom, 7);
        }
        g.scale.setScalar(factor * this.size / 4);
        for (let i = 0; i < this.handles.length; i++) {
            const h = this.handles[i];
            let show = h.mode == this.mode;
            if (h.name.includes("X") && !this.showX) show = false;
            if (h.name.includes("Y") && !this.showY) show = false;
            if (h.name.includes("Z") && !this.showZ) show = false;
            h.visible.visible = show;
            h.picker.visible = show;
            const m = h.visible.material as MeshBasicMaterial;
            m.color.setHex(h.name == this.axis ? HOVER_COLOR : h.color);
        }
    }

    // ------------------------------------------------------------ input

    private aim(event: PointerEvent): void {
        const r = this.domElement;
        const w = r != null ? Math.max(1, r.getSize(_size).x) : 1, h = r != null ? Math.max(1, _size.y) : 1;
        _pointer.set(<f64>event.position.x / w * 2 - 1, -(<f64>event.position.y / h) * 2 + 1);
        this.camera.updateMatrixWorld();
        this.raycaster.setFromCamera(_pointer, this.camera);
    }

    /// The handle under the pointer, or "".
    private pick(): string {
        if (this.attached == null || !this.gizmo.visible) return "";
        this.gizmo.updateMatrixWorld(true);
        this.hits.length = 0;
        this.raycaster.intersectObjects(this.pickers, false, this.hits);
        for (let i = 0; i < this.hits.length; i++) {
            const o = this.hits[i].object;
            if (o.visible) return o.name;
        }
        return "";
    }

    /// The axis direction in world space (gizmo space rotated).
    private axisDirection(index: i32, out: Vector3): Vector3 {
        out.copy(UNIT[index]);
        if (this.space == "local" || this.mode == "scale") out.applyQuaternion(this.worldQuaternion);
        return out;
    }

    /// The plane a drag happens on, through the object, for the axis
    /// (three.js's TransformControlsPlane, as a mathematical plane).
    private dragPlane(): void {
        _eye.copy(_cameraPosition).sub(this.worldPosition).normalize();
        const axis = this.axis;
        if (this.mode == "rotate" || axis == "XYZ") {
            this.planeNormal.copy(_eye);
        } else if (axis == "XY" || axis == "YZ" || axis == "XZ") {
            const index = axis == "XY" ? 2 : axis == "YZ" ? 0 : 1;
            this.axisDirection(index, this.planeNormal);
        } else {
            // A single axis: the plane containing it that best faces the eye.
            this.axisDirection(axisIndex(axis), _axisWorld);
            this.planeNormal.copy(_eye).addScaledVector(_axisWorld, -_eye.dot(_axisWorld));
            if (this.planeNormal.lengthSq() < 1e-8) this.planeNormal.copy(_eye);
            this.planeNormal.normalize();
        }
        _plane.setFromNormalAndCoplanarPoint(this.planeNormal, this.worldPosition);
    }

    override pointerDown(event: PointerEvent): void {
        if (!this.enabled || this.attached == null) return;
        this.aim(event);
        const axis = this.pick();
        this.axis = axis;
        if (axis.length == 0) return;
        const object = this.attached!;
        this.dragPlane();
        if (this.raycaster.ray.intersectPlane(_plane, _hit) == null) return;
        this.pointStart.copy(_hit).sub(this.worldPosition);
        this.positionStart.copy(object.position);
        this.quaternionStart.copy(object.quaternion);
        this.scaleStart.copy(object.scale);
        this.dragging = true;
        this.emit("mouseDown");
        const e = new Event("dragging-changed");
        e.value = true;
        if (this.hasListeners("dragging-changed")) this.dispatchEvent(e);
        event.hit();
    }

    override pointerMove(event: PointerEvent): void {
        if (!this.enabled || this.attached == null) return;
        this.aim(event);
        if (!this.dragging) {
            this.axis = this.pick();
            return;
        }
        const object = this.attached!;
        if (this.raycaster.ray.intersectPlane(_plane, _hit) == null) return;
        const pointEnd = _hit.sub(this.worldPosition);
        const axis = this.axis;
        if (this.mode == "translate") {
            const offset = _v.copy(pointEnd).sub(this.pointStart);
            if (axis.length == 1) {
                this.axisDirection(axisIndex(axis), _axisWorld);
                offset.copy(_axisWorld).multiplyScalar(offset.dot(_axisWorld));
            }
            // World offset into the parent's frame.
            offset.applyQuaternion(this.parentQuaternionInverse);
            object.position.copy(this.positionStart).add(offset);
            if (this.translationSnap > 0) {
                const s = this.translationSnap;
                if (axis.includes("X")) object.position.x = Math.round(object.position.x / s) * s;
                if (axis.includes("Y")) object.position.y = Math.round(object.position.y / s) * s;
                if (axis.includes("Z")) object.position.z = Math.round(object.position.z / s) * s;
            }
        } else if (this.mode == "rotate") {
            const offset = _v.copy(pointEnd).sub(this.pointStart);
            const speed = 20 / this.worldPosition.distanceTo(_cameraPosition);
            this.axisDirection(axisIndex(axis), _axisWorld);
            const tangent = new Vector3().copy(_axisWorld).cross(_eye).normalize();
            let angle = offset.dot(tangent) * speed;
            if (this.rotationSnap > 0) angle = Math.round(angle / this.rotationSnap) * this.rotationSnap;
            if (this.space == "local") {
                object.quaternion.copy(this.quaternionStart).multiply(_q.setFromAxisAngle(UNIT[axisIndex(axis)], angle));
            } else {
                _axisWorld.applyQuaternion(this.parentQuaternionInverse);
                object.quaternion.copy(_q.setFromAxisAngle(_axisWorld, angle)).multiply(this.quaternionStart);
            }
        } else {
            if (axis == "XYZ") {
                let d = pointEnd.length() / Math.max(this.pointStart.length(), 1e-8);
                if (pointEnd.dot(this.pointStart) < 0) d = -d;
                object.scale.copy(this.scaleStart).multiplyScalar(d);
            } else {
                // Per axis: the ratio of the pointer's distances along it.
                const index = axisIndex(axis);
                this.axisDirection(index, _axisWorld);
                const s0 = this.pointStart.dot(_axisWorld), s1 = pointEnd.dot(_axisWorld);
                const ratio = Math.abs(s0) > 1e-8 ? s1 / s0 : 1;
                object.scale.copy(this.scaleStart);
                object.scale.setComponent(index, this.scaleStart.getComponent(index) * ratio);
            }
            if (this.scaleSnap > 0) {
                const s = this.scaleSnap;
                object.scale.set(snapScale(object.scale.x, s), snapScale(object.scale.y, s), snapScale(object.scale.z, s));
            }
        }
        this.emit("change");
        this.emit("objectChange");
        event.hit();
    }

    override pointerUp(event: PointerEvent): void {
        if (!this.dragging) return;
        this.dragging = false;
        this.emit("mouseUp");
        const e = new Event("dragging-changed");
        e.value = false;
        if (this.hasListeners("dragging-changed")) this.dispatchEvent(e);
        event.hit();
    }

    private emit(type: string): void {
        if (this.hasListeners(type)) this.dispatchEvent(new Event(type));
    }

    override dispose(): void {
        this.detach();
    }
}

/// three.js's `Math.round(v / s) * s || s`.
function snapScale(v: f64, s: f64): f64 {
    const r = Math.round(v / s) * s;
    return r != 0 ? r : s;
}

function axisIndex(axis: string): i32 {
    return axis == "Y" ? 1 : axis == "Z" ? 2 : 0;
}
