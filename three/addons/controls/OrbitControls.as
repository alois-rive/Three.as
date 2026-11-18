// three.js's OrbitControls addon, driven by Rive pointer and scroll events.
//
//     controls = new OrbitControls(camera, renderer);   // renderer: its size
//     // in the script's hooks:
//     override pointerDown(e: PointerEvent): void { controls.pointerDown(e); }
//     override pointerMove(e: PointerEvent): void { controls.pointerMove(e); }
//     override pointerUp(e: PointerEvent): void { controls.pointerUp(e); }
//     override pointerScroll(e: ScrollEvent): void { controls.pointerScroll(e); }
//     override advance(s: f64): bool { controls.update(s); ... }
//
// Rive pointer events carry no mouse button, so the controls follow
// three.js's touch mapping: one pointer rotates (pans for MapControls), two
// pointers dolly and pan; the scroll wheel dollies. Positions are the
// layout's local coordinates (points).

import { Controls } from "../../extras/Controls";
import { PointerEvent, ScrollEvent } from "rive/events";
import { Camera } from "../../cameras/Camera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { GPURenderer } from "../../renderers/GPURenderer";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Quaternion } from "../../math/Quaternion";
import { Spherical } from "../../math/Spherical";
import { Matrix4 } from "../../math/Matrix4";

const STATE_NONE: i32 = -1;
const STATE_ROTATE: i32 = 0;
const STATE_PAN: i32 = 2;
const STATE_TOUCH_DOLLY_PAN: i32 = 5;

const TWO_PI: f64 = Math.PI * 2;

export class OrbitControls extends Controls {
    readonly camera: Camera;
    /// Gives the viewport size (getSize), as three.js's domElement.
    domElement: GPURenderer?;
    /// The point orbited.
    target: Vector3 = new Vector3();
    cursor: Vector3 = new Vector3();
    minDistance: f64 = 0;
    maxDistance: f64 = Infinity;
    minZoom: f64 = 0;
    maxZoom: f64 = Infinity;
    minTargetRadius: f64 = 0;
    maxTargetRadius: f64 = Infinity;
    minPolarAngle: f64 = 0;
    maxPolarAngle: f64 = Math.PI;
    minAzimuthAngle: f64 = -Infinity;
    maxAzimuthAngle: f64 = Infinity;
    enableDamping: bool = false;
    dampingFactor: f64 = 0.05;
    enableZoom: bool = true;
    zoomSpeed: f64 = 1;
    enableRotate: bool = true;
    rotateSpeed: f64 = 1;
    enablePan: bool = true;
    panSpeed: f64 = 1;
    screenSpacePanning: bool = true;
    autoRotate: bool = false;
    /// Seconds per orbit = 60 / autoRotateSpeed.
    autoRotateSpeed: f64 = 2;
    /// What one pointer does: STATE_ROTATE here, panning for MapControls.
    protected singlePointer: i32 = STATE_ROTATE;

    private state: i32 = STATE_NONE;
    private spherical: Spherical = new Spherical();
    private sphericalDelta: Spherical = new Spherical(0, 0, 0);
    private scale: f64 = 1;
    private panOffset: Vector3 = new Vector3();
    private rotateStart: Vector2 = new Vector2();
    private rotateEnd: Vector2 = new Vector2();
    private rotateDelta: Vector2 = new Vector2();
    private panStart: Vector2 = new Vector2();
    private panEnd: Vector2 = new Vector2();
    private panDelta: Vector2 = new Vector2();
    private dollyStart: f64 = 0;
    private pointerIds: Array<f64> = [];
    private pointerPositions: Array<Vector2> = [];
    private quat: Quaternion = new Quaternion();
    private quatInverse: Quaternion = new Quaternion();
    private target0: Vector3 = new Vector3();
    private position0: Vector3 = new Vector3();
    private zoom0: f64 = 1;

    // The pose last reported by "change".
    private lastPosition: Vector3 = new Vector3();
    private lastQuaternion: Quaternion = new Quaternion();
    private lastTarget: Vector3 = new Vector3();

    constructor(object: Camera, domElement: GPURenderer? = null) {
        super(object);
        this.camera = object;
        this.domElement = domElement;
        this.quat.setFromUnitVectors(object.up, new Vector3(0, 1, 0));
        this.quatInverse.copy(this.quat).invert();
        this.saveState();
        this.update();
    }

    getPolarAngle(): f64 { return this.spherical.phi; }
    getAzimuthalAngle(): f64 { return this.spherical.theta; }
    getDistance(): f64 { return this.object.position.distanceTo(this.target); }

    saveState(): void {
        this.target0.copy(this.target);
        this.position0.copy(this.object.position);
        this.zoom0 = zoomOf(this.camera);
    }

    reset(): void {
        this.target.copy(this.target0);
        this.object.position.copy(this.position0);
        setZoom(this.camera, this.zoom0);
        this.camera.updateProjectionMatrix();
        this.update();
        this.state = STATE_NONE;
    }

    /// Applies the motion (and damping, and autoRotate over `deltaTime`
    /// seconds). Call it every advance.
    update(deltaTime: f64 = -1): bool {
        const position = this.object.position;
        _v.copy(position).sub(this.target).applyQuaternion(this.quat);
        this.spherical.setFromVector3(_v);
        if (this.autoRotate && this.state == STATE_NONE) this.rotateLeft(this.autoRotationAngle(deltaTime));
        if (this.enableDamping) {
            this.spherical.theta += this.sphericalDelta.theta * this.dampingFactor;
            this.spherical.phi += this.sphericalDelta.phi * this.dampingFactor;
        } else {
            this.spherical.theta += this.sphericalDelta.theta;
            this.spherical.phi += this.sphericalDelta.phi;
        }
        let min = this.minAzimuthAngle, max = this.maxAzimuthAngle;
        if (isFinite(min) && isFinite(max)) {
            if (min < -Math.PI) min += TWO_PI; else if (min > Math.PI) min -= TWO_PI;
            if (max < -Math.PI) max += TWO_PI; else if (max > Math.PI) max -= TWO_PI;
            const theta = this.spherical.theta;
            if (min <= max) this.spherical.theta = Math.max(min, Math.min(max, theta));
            else this.spherical.theta = theta > (min + max) / 2 ? Math.max(min, theta) : Math.min(max, theta);
        }
        this.spherical.phi = Math.max(this.minPolarAngle, Math.min(this.maxPolarAngle, this.spherical.phi));
        this.spherical.makeSafe();
        if (this.enableDamping) this.target.addScaledVector(this.panOffset, this.dampingFactor);
        else this.target.add(this.panOffset);
        this.target.sub(this.cursor).clampLength(this.minTargetRadius, this.maxTargetRadius).add(this.cursor);

        const ortho = this.object instanceof OrthographicCamera;
        if (!ortho) {
            this.spherical.radius = Math.max(this.minDistance, Math.min(this.maxDistance, this.spherical.radius * this.scale));
        }
        _v.setFromSpherical(this.spherical).applyQuaternion(this.quatInverse);
        position.copy(this.target).add(_v);
        this.object.lookAt(this.target);
        if (this.enableDamping) {
            this.sphericalDelta.theta *= 1 - this.dampingFactor;
            this.sphericalDelta.phi *= 1 - this.dampingFactor;
            this.panOffset.multiplyScalar(1 - this.dampingFactor);
        } else {
            this.sphericalDelta.set(0, 0, 0);
            this.panOffset.set(0, 0, 0);
        }
        if (ortho) {
            const o = this.object as OrthographicCamera;
            o.zoom = Math.max(this.minZoom, Math.min(this.maxZoom, o.zoom / this.scale));
            o.updateProjectionMatrix();
        }
        this.scale = 1;
        // "change" when the camera moved (three.js's EPS test).
        const EPS = 0.000001;
        if (this.lastPosition.distanceToSquared(position) > EPS
                || 8 * (1 - this.lastQuaternion.dot(this.object.quaternion)) > EPS
                || this.lastTarget.distanceToSquared(this.target) > EPS) {
            this.changed();
            this.lastPosition.copy(position);
            this.lastQuaternion.copy(this.object.quaternion);
            this.lastTarget.copy(this.target);
            return true;
        }
        return false;
    }

    // ------------------------------------------------------------ events

    override pointerDown(event: PointerEvent): void {
        if (!this.enabled) return;
        if (this.pointerIds.length == 0) this.started();
        this.addPointer(event);
        if (this.pointerIds.length == 1) this.startSingle(event);
        else if (this.pointerIds.length == 2) this.startDollyPan();
        event.hit();
    }

    override pointerMove(event: PointerEvent): void {
        if (!this.enabled) return;
        const i = this.pointerIds.indexOf(event.id);
        if (i < 0) return;
        this.pointerPositions[i].set(<f64>event.position.x, <f64>event.position.y);
        if (this.state == STATE_ROTATE) {
            if (!this.enableRotate) return;
            this.rotateEnd.set(<f64>event.position.x, <f64>event.position.y);
            this.rotateDelta.subVectors(this.rotateEnd, this.rotateStart).multiplyScalar(this.rotateSpeed);
            const h = this.clientHeight();
            this.rotateLeft(TWO_PI * this.rotateDelta.x / h);
            this.rotateUp(TWO_PI * this.rotateDelta.y / h);
            this.rotateStart.copy(this.rotateEnd);
        } else if (this.state == STATE_PAN) {
            if (!this.enablePan) return;
            this.panEnd.set(<f64>event.position.x, <f64>event.position.y);
            this.panDelta.subVectors(this.panEnd, this.panStart).multiplyScalar(this.panSpeed);
            this.pan(this.panDelta.x, this.panDelta.y);
            this.panStart.copy(this.panEnd);
        } else if (this.state == STATE_TOUCH_DOLLY_PAN && this.pointerIds.length >= 2) {
            const a = this.pointerPositions[0], b = this.pointerPositions[1];
            if (this.enableZoom) {
                const distance = a.distanceTo(b);
                if (this.dollyStart > 0 && distance > 0) this.dollyOut(Math.pow(distance / this.dollyStart, this.zoomSpeed));
                this.dollyStart = distance;
            }
            if (this.enablePan) {
                this.panEnd.set((a.x + b.x) * 0.5, (a.y + b.y) * 0.5);
                this.panDelta.subVectors(this.panEnd, this.panStart).multiplyScalar(this.panSpeed);
                this.pan(this.panDelta.x, this.panDelta.y);
                this.panStart.copy(this.panEnd);
            }
        }
        event.hit();
    }

    override pointerUp(event: PointerEvent): void {
        const i = this.pointerIds.indexOf(event.id);
        if (i < 0) return;
        this.pointerIds.splice(i, 1);
        this.pointerPositions.splice(i, 1);
        if (this.pointerIds.length == 0) {
            this.state = STATE_NONE;
            this.ended();
        } else if (this.pointerIds.length == 1) {
            const p = this.pointerPositions[0];
            this.startSingleAt(p.x, p.y);
        }
        event.hit();
    }

    override pointerExit(event: PointerEvent): void {
        this.pointerUp(event);
    }

    /// The wheel dollies (zoom in when scrolling up, as three.js).
    override pointerScroll(event: ScrollEvent): void {
        if (!this.enabled || !this.enableZoom || this.state != STATE_NONE) return;
        this.started();
        // Rive's delta follows the content; three.js's deltaY is the wheel's.
        const deltaY = -<f64>event.delta.y;
        if (deltaY < 0) this.dollyIn(this.zoomScale(deltaY));
        else if (deltaY > 0) this.dollyOut(this.zoomScale(deltaY));
        this.ended();
        event.hit();
    }

    // ------------------------------------------------------------ motion

    rotateLeft(angle: f64): void { this.sphericalDelta.theta -= angle; }
    rotateUp(angle: f64): void { this.sphericalDelta.phi -= angle; }

    /// Pans by a screen delta in points.
    pan(deltaX: f64, deltaY: f64): void {
        const m = this.object.matrix;
        if (this.object instanceof PerspectiveCamera) {
            const p = this.object as PerspectiveCamera;
            _v.copy(p.position).sub(this.target);
            const targetDistance = _v.length() * Math.tan(p.fov / 2 * Math.PI / 180);
            const h = this.clientHeight();
            this.panLeft(2 * deltaX * targetDistance / h, m);
            this.panUp(2 * deltaY * targetDistance / h, m);
        } else if (this.object instanceof OrthographicCamera) {
            const o = this.object as OrthographicCamera;
            this.panLeft(deltaX * (o.right - o.left) / o.zoom / this.clientWidth(), m);
            this.panUp(deltaY * (o.top - o.bottom) / o.zoom / this.clientHeight(), m);
        }
    }

    dollyIn(dollyScale: f64): void { this.scale *= dollyScale; }
    dollyOut(dollyScale: f64): void { this.scale /= dollyScale; }

    private panLeft(distance: f64, objectMatrix: Matrix4): void {
        _v.setFromMatrixColumn(objectMatrix, 0).multiplyScalar(-distance);
        this.panOffset.add(_v);
    }

    private panUp(distance: f64, objectMatrix: Matrix4): void {
        if (this.screenSpacePanning) {
            _v.setFromMatrixColumn(objectMatrix, 1);
        } else {
            _v.setFromMatrixColumn(objectMatrix, 0);
            _v.crossVectors(this.object.up, _v);
        }
        this.panOffset.add(_v.multiplyScalar(distance));
    }

    private autoRotationAngle(deltaTime: f64): f64 {
        if (deltaTime >= 0) return TWO_PI / 60 * this.autoRotateSpeed * deltaTime;
        return TWO_PI / 60 / 60 * this.autoRotateSpeed;
    }

    private zoomScale(delta: f64): f64 {
        return Math.pow(0.95, this.zoomSpeed * Math.abs(delta * 0.01));
    }

    private addPointer(event: PointerEvent): void {
        if (this.pointerIds.indexOf(event.id) >= 0) return;
        this.pointerIds.push(event.id);
        this.pointerPositions.push(new Vector2(<f64>event.position.x, <f64>event.position.y));
    }

    private startSingle(event: PointerEvent): void {
        this.startSingleAt(<f64>event.position.x, <f64>event.position.y);
    }

    private startSingleAt(x: f64, y: f64): void {
        this.state = this.singlePointer;
        this.rotateStart.set(x, y);
        this.panStart.set(x, y);
    }

    private startDollyPan(): void {
        const a = this.pointerPositions[0], b = this.pointerPositions[1];
        this.dollyStart = a.distanceTo(b);
        this.panStart.set((a.x + b.x) * 0.5, (a.y + b.y) * 0.5);
        this.state = STATE_TOUCH_DOLLY_PAN;
    }

    private clientHeight(): f64 {
        const r = this.domElement;
        if (r == null) return 1;
        r.getSize(_size);
        return _size.y > 0 ? _size.y : 1;
    }

    private clientWidth(): f64 {
        const r = this.domElement;
        if (r == null) return 1;
        r.getSize(_size);
        return _size.x > 0 ? _size.x : 1;
    }

    dispose(): void {}
}

/// three.js's MapControls: one pointer pans (parallel to the ground), two
/// pointers dolly and pan.
export class MapControls extends OrbitControls {
    constructor(object: Camera, domElement: GPURenderer? = null) {
        super(object, domElement);
        this.screenSpacePanning = false;
        this.singlePointer = STATE_PAN;
    }
}

function zoomOf(c: Camera): f64 {
    if (c instanceof PerspectiveCamera) return (c as PerspectiveCamera).zoom;
    if (c instanceof OrthographicCamera) return (c as OrthographicCamera).zoom;
    return 1;
}

function setZoom(c: Camera, zoom: f64): void {
    if (c instanceof PerspectiveCamera) (c as PerspectiveCamera).zoom = zoom;
    else if (c instanceof OrthographicCamera) (c as OrthographicCamera).zoom = zoom;
}

const _v: Vector3 = new Vector3();
const _size: Vector2 = new Vector2();
