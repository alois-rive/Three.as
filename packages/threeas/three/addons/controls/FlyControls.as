// three.js examples/jsm/controls/FlyControls.js: fly freely. Keys (W/S
// forward/back, A/D strafe, R/F up/down, arrows pitch/yaw, Q/E roll, shift
// slower; the layout needs a FocusData child) and the pointer's offset from
// the centre to look. Pressing moves forward (Rive pointer events have no
// buttons); with dragToLook, pressing looks instead.

import { PointerEvent, KeyboardEvent } from "rive/events";
import {
    Controls, KEY_W, KEY_S, KEY_A, KEY_D, KEY_R, KEY_F, KEY_Q, KEY_E, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
    KEY_LEFT_SHIFT,
} from "../../extras/Controls";
import { Object3D } from "../../core/Object3D";
import { GPURenderer } from "../../renderers/GPURenderer";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Quaternion } from "../../math/Quaternion";

const EPS = 0.000001;
const _q = new Quaternion();
const _size = new Vector2();

export class FlyControls extends Controls {
    domElement: GPURenderer?;
    movementSpeed: f64 = 1.0;
    rollSpeed: f64 = 0.005;
    dragToLook: bool = false;
    autoForward: bool = false;

    private forward: f64 = 0; private back: f64 = 0; private left: f64 = 0; private right: f64 = 0;
    private up: f64 = 0; private down: f64 = 0;
    private pitchUp: f64 = 0; private pitchDown: f64 = 0; private yawLeft: f64 = 0; private yawRight: f64 = 0;
    private rollLeft: f64 = 0; private rollRight: f64 = 0;
    private moveVector: Vector3 = new Vector3();
    private rotationVector: Vector3 = new Vector3();
    private status: i32 = 0;
    private speedMultiplier: f64 = 1;
    private lastPosition: Vector3 = new Vector3();
    private lastQuaternion: Quaternion = new Quaternion();

    constructor(object: Object3D, domElement: GPURenderer? = null) {
        super(object);
        this.domElement = domElement;
    }

    override keyboardEvent(event: KeyboardEvent): bool {
        if (!this.enabled) return false;
        const down = event.phase != "up";
        const v: f64 = down ? 1 : 0;
        const k = <i32>event.key;
        if (k == KEY_LEFT_SHIFT) this.speedMultiplier = down ? 0.1 : 1;
        else if (k == KEY_W) this.forward = v;
        else if (k == KEY_S) this.back = v;
        else if (k == KEY_A) this.left = v;
        else if (k == KEY_D) this.right = v;
        else if (k == KEY_R) this.up = v;
        else if (k == KEY_F) this.down = v;
        else if (k == KEY_UP) this.pitchUp = v;
        else if (k == KEY_DOWN) this.pitchDown = v;
        else if (k == KEY_LEFT) this.yawLeft = v;
        else if (k == KEY_RIGHT) this.yawRight = v;
        else if (k == KEY_Q) this.rollLeft = v;
        else if (k == KEY_E) this.rollRight = v;
        else return false;
        this.updateMovementVector();
        this.updateRotationVector();
        return true;
    }

    override pointerDown(event: PointerEvent): void {
        if (!this.enabled) return;
        if (this.dragToLook) this.status++;
        else this.forward = 1;
        this.updateMovementVector();
        event.hit();
    }

    override pointerMove(event: PointerEvent): void {
        if (!this.enabled || (this.dragToLook && this.status == 0)) return;
        const r = this.domElement;
        if (r == null) return;
        r.getSize(_size);
        const hw = _size.x / 2, hh = _size.y / 2;
        this.yawLeft = -(<f64>event.position.x - hw) / hw;
        this.pitchDown = (<f64>event.position.y - hh) / hh;
        this.updateRotationVector();
    }

    override pointerUp(event: PointerEvent): void {
        if (!this.enabled) return;
        if (this.dragToLook) {
            this.status = max<i32>(0, this.status - 1);
            this.yawLeft = 0;
            this.pitchDown = 0;
        } else {
            this.forward = 0;
        }
        this.updateMovementVector();
        this.updateRotationVector();
    }

    override capturing(): bool { return this.status > 0; }

    override update(delta: f64 = -1): bool {
        if (!this.enabled || delta <= 0) return false;
        const moveMult = delta * this.movementSpeed * this.speedMultiplier;
        const rotMult = delta * this.rollSpeed;
        const o = this.object;
        o.translateX(this.moveVector.x * moveMult);
        o.translateY(this.moveVector.y * moveMult);
        o.translateZ(this.moveVector.z * moveMult);
        _q.set(this.rotationVector.x * rotMult, this.rotationVector.y * rotMult, this.rotationVector.z * rotMult, 1).normalize();
        o.quaternion.multiply(_q);
        if (this.lastPosition.distanceToSquared(o.position) > EPS
                || 8 * (1 - this.lastQuaternion.dot(o.quaternion)) > EPS) {
            this.changed();
            this.lastQuaternion.copy(o.quaternion);
            this.lastPosition.copy(o.position);
            return true;
        }
        return false;
    }

    private updateMovementVector(): void {
        const forward = (this.forward != 0 || (this.autoForward && this.back == 0)) ? 1 : 0;
        this.moveVector.x = -this.left + this.right;
        this.moveVector.y = -this.down + this.up;
        this.moveVector.z = -<f64>forward + this.back;
    }

    private updateRotationVector(): void {
        this.rotationVector.x = -this.pitchDown + this.pitchUp;
        this.rotationVector.y = -this.yawRight + this.yawLeft;
        this.rotationVector.z = -this.rollRight + this.rollLeft;
    }
}
