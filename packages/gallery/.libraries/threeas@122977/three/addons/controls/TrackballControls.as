// three.js examples/jsm/controls/TrackballControls.js: rotate the camera
// freely around a target (no fixed up), zoom and pan, with damping. One
// pointer rotates, two pinch-zoom and pan, the wheel zooms (Rive pointer
// events have no buttons).

import { PointerEvent, ScrollEvent } from "rive/events";
import { Controls } from "../../extras/Controls";
import { Camera } from "../../cameras/Camera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { GPURenderer } from "../../renderers/GPURenderer";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Quaternion } from "../../math/Quaternion";

const STATE_NONE = -1, STATE_ROTATE = 0, STATE_TOUCH_ZOOM_PAN = 4;
const EPS = 0.000001;
const _v2 = new Vector2();
const _axis = new Vector3();
const _quaternion = new Quaternion();
const _eyeDirection = new Vector3();
const _upDirection = new Vector3();
const _sideDirection = new Vector3();
const _moveDirection = new Vector3();
const _mouseChange = new Vector2();
const _objectUp = new Vector3();
const _pan = new Vector3();

export class TrackballControls extends Controls {
    readonly camera: Camera;
    domElement: GPURenderer?;
    rotateSpeed: f64 = 1.0;
    zoomSpeed: f64 = 1.2;
    panSpeed: f64 = 0.3;
    noRotate: bool = false;
    noZoom: bool = false;
    noPan: bool = false;
    staticMoving: bool = false;
    dynamicDampingFactor: f64 = 0.2;
    minDistance: f64 = 0;
    maxDistance: f64 = Infinity;
    minZoom: f64 = 0;
    maxZoom: f64 = Infinity;
    target: Vector3 = new Vector3();

    private state: i32 = STATE_NONE;
    private eye: Vector3 = new Vector3();
    private movePrev: Vector2 = new Vector2();
    private moveCurr: Vector2 = new Vector2();
    private lastAxis: Vector3 = new Vector3();
    private lastAngle: f64 = 0;
    private zoomStart: Vector2 = new Vector2();
    private zoomEnd: Vector2 = new Vector2();
    private touchZoomStart: f64 = 0;
    private touchZoomEnd: f64 = 0;
    private panStart: Vector2 = new Vector2();
    private panEnd: Vector2 = new Vector2();
    private pointerIds: Array<f64> = [];
    private pointerPositions: Array<Vector2> = [];
    private lastPosition: Vector3 = new Vector3();
    private lastZoom: f64 = 1;

    constructor(object: Camera, domElement: GPURenderer? = null) {
        super(object);
        this.camera = object;
        this.domElement = domElement;
    }

    private width(): f64 {
        const r = this.domElement;
        return r != null ? Math.max(1, r.getSize(_v2).x) : 1;
    }

    private height(): f64 {
        const r = this.domElement;
        return r != null ? Math.max(1, r.getSize(_v2).y) : 1;
    }

    private mouseOnScreen(x: f64, y: f64, out: Vector2): Vector2 {
        return out.set(x / this.width(), y / this.height());
    }

    private mouseOnCircle(x: f64, y: f64, out: Vector2): Vector2 {
        const w = this.width(), h = this.height();
        return out.set((x - w * 0.5) / (w * 0.5), (h - 2 * y) / w);
    }

    private rotateCamera(): void {
        _moveDirection.set(this.moveCurr.x - this.movePrev.x, this.moveCurr.y - this.movePrev.y, 0);
        let angle = _moveDirection.length();
        const object = this.object;
        if (angle > 0) {
            this.eye.copy(object.position).sub(this.target);
            _eyeDirection.copy(this.eye).normalize();
            _upDirection.copy(object.up).normalize();
            _sideDirection.crossVectors(_upDirection, _eyeDirection).normalize();
            _upDirection.setLength(this.moveCurr.y - this.movePrev.y);
            _sideDirection.setLength(this.moveCurr.x - this.movePrev.x);
            _moveDirection.copy(_upDirection.add(_sideDirection));
            _axis.crossVectors(_moveDirection, this.eye).normalize();
            angle *= this.rotateSpeed;
            _quaternion.setFromAxisAngle(_axis, angle);
            this.eye.applyQuaternion(_quaternion);
            object.up.applyQuaternion(_quaternion);
            this.lastAxis.copy(_axis);
            this.lastAngle = angle;
        } else if (!this.staticMoving && this.lastAngle != 0) {
            this.lastAngle *= Math.sqrt(1.0 - this.dynamicDampingFactor);
            this.eye.copy(object.position).sub(this.target);
            _quaternion.setFromAxisAngle(this.lastAxis, this.lastAngle);
            this.eye.applyQuaternion(_quaternion);
            object.up.applyQuaternion(_quaternion);
        }
        this.movePrev.copy(this.moveCurr);
    }

    private zoomCamera(): void {
        let factor: f64;
        if (this.state == STATE_TOUCH_ZOOM_PAN) {
            factor = this.touchZoomEnd > 0 ? this.touchZoomStart / this.touchZoomEnd : 1;
            this.touchZoomStart = this.touchZoomEnd;
        } else {
            factor = 1.0 + (this.zoomEnd.y - this.zoomStart.y) * this.zoomSpeed;
            if (this.staticMoving) this.zoomStart.copy(this.zoomEnd);
            else this.zoomStart.y += (this.zoomEnd.y - this.zoomStart.y) * this.dynamicDampingFactor;
        }
        if (factor == 1.0 || factor <= 0) return;
        if (this.camera instanceof OrthographicCamera) {
            const o = this.camera as OrthographicCamera;
            o.zoom = Math.max(this.minZoom, Math.min(this.maxZoom, o.zoom / factor));
            o.updateProjectionMatrix();
        } else {
            this.eye.multiplyScalar(factor);
        }
    }

    private panCamera(): void {
        _mouseChange.copy(this.panEnd).sub(this.panStart);
        if (_mouseChange.lengthSq() == 0) return;
        _mouseChange.multiplyScalar(this.eye.length() * this.panSpeed);
        const object = this.object;
        _pan.copy(this.eye).cross(object.up).setLength(_mouseChange.x);
        _pan.add(_objectUp.copy(object.up).setLength(_mouseChange.y));
        object.position.add(_pan);
        this.target.add(_pan);
        if (this.staticMoving) this.panStart.copy(this.panEnd);
        else this.panStart.add(_mouseChange.subVectors(this.panEnd, this.panStart).multiplyScalar(this.dynamicDampingFactor));
    }

    private checkDistances(): void {
        if (this.noZoom && this.noPan) return;
        const object = this.object;
        if (this.eye.lengthSq() > this.maxDistance * this.maxDistance) {
            object.position.addVectors(this.target, this.eye.setLength(this.maxDistance));
            this.zoomStart.copy(this.zoomEnd);
        }
        if (this.eye.lengthSq() < this.minDistance * this.minDistance) {
            object.position.addVectors(this.target, this.eye.setLength(this.minDistance));
            this.zoomStart.copy(this.zoomEnd);
        }
    }

    override update(delta: f64 = -1): bool {
        const object = this.object;
        this.eye.subVectors(object.position, this.target);
        if (!this.noRotate) this.rotateCamera();
        if (!this.noZoom) this.zoomCamera();
        if (!this.noPan) this.panCamera();
        object.position.addVectors(this.target, this.eye);
        if (this.camera instanceof PerspectiveCamera) this.checkDistances();
        object.lookAt<Vector3>(this.target);
        const zoom = this.camera instanceof OrthographicCamera ? (this.camera as OrthographicCamera).zoom : 1;
        if (this.lastPosition.distanceToSquared(object.position) > EPS || this.lastZoom != zoom) {
            this.changed();
            this.lastPosition.copy(object.position);
            this.lastZoom = zoom;
            return true;
        }
        return false;
    }

    reset(): void {
        this.state = STATE_NONE;
        this.eye.subVectors(this.object.position, this.target);
        this.object.lookAt<Vector3>(this.target);
        this.changed();
    }

    override capturing(): bool { return this.state != STATE_NONE; }

    override pointerDown(event: PointerEvent): void {
        if (!this.enabled) return;
        if (this.pointerIds.length == 0) this.started();
        this.pointerIds.push(event.id);
        this.pointerPositions.push(new Vector2(<f64>event.position.x, <f64>event.position.y));
        if (this.pointerIds.length == 1) {
            this.state = STATE_ROTATE;
            this.mouseOnCircle(<f64>event.position.x, <f64>event.position.y, this.moveCurr);
            this.movePrev.copy(this.moveCurr);
        } else {
            this.state = STATE_TOUCH_ZOOM_PAN;
            const a = this.pointerPositions[0], b = this.pointerPositions[1];
            this.touchZoomStart = this.touchZoomEnd = a.distanceTo(b);
            this.mouseOnScreen((a.x + b.x) / 2, (a.y + b.y) / 2, this.panStart);
            this.panEnd.copy(this.panStart);
        }
        event.hit();
    }

    override pointerMove(event: PointerEvent): void {
        if (!this.enabled) return;
        const i = this.pointerIds.indexOf(event.id);
        if (i < 0) return;
        this.pointerPositions[i].set(<f64>event.position.x, <f64>event.position.y);
        if (this.state == STATE_ROTATE) {
            this.movePrev.copy(this.moveCurr);
            this.mouseOnCircle(<f64>event.position.x, <f64>event.position.y, this.moveCurr);
        } else if (this.state == STATE_TOUCH_ZOOM_PAN && this.pointerPositions.length >= 2) {
            const a = this.pointerPositions[0], b = this.pointerPositions[1];
            this.touchZoomEnd = a.distanceTo(b);
            this.mouseOnScreen((a.x + b.x) / 2, (a.y + b.y) / 2, this.panEnd);
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
            this.state = STATE_ROTATE;
            this.mouseOnCircle(this.pointerPositions[0].x, this.pointerPositions[0].y, this.moveCurr);
            this.movePrev.copy(this.moveCurr);
        }
        event.hit();
    }

    override pointerScroll(event: ScrollEvent): void {
        if (!this.enabled || this.noZoom) return;
        // Rive's delta follows the content: three.js's deltaY is the wheel's.
        this.zoomStart.y += <f64>event.delta.y * 0.01;
        this.started();
        this.ended();
        event.hit();
    }
}
