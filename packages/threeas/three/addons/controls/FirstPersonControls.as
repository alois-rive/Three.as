// three.js examples/jsm/controls/FirstPersonControls.js: walk with keys
// (W/S or up/down, A/D or left/right, R/F; the layout needs a FocusData
// child) and look where the pointer points, relative to the centre.
// Pressing walks forward (Rive pointer events have no buttons).

import { PointerEvent, KeyboardEvent } from "rive/events";
import {
    Controls, KEY_W, KEY_S, KEY_A, KEY_D, KEY_R, KEY_F, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
} from "../../extras/Controls";
import { Object3D } from "../../core/Object3D";
import { GPURenderer } from "../../renderers/GPURenderer";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Spherical } from "../../math/Spherical";

const _size = new Vector2();
const _target = new Vector3();
const _dir = new Vector3();
const _spherical = new Spherical();

export class FirstPersonControls extends Controls {
    domElement: GPURenderer?;
    movementSpeed: f64 = 1.0;
    lookSpeed: f64 = 0.005;
    lookVertical: bool = true;
    autoForward: bool = false;
    activeLook: bool = true;
    heightSpeed: bool = false;
    heightCoef: f64 = 1.0;
    heightMin: f64 = 0.0;
    heightMax: f64 = 1.0;
    constrainVertical: bool = false;
    verticalMin: f64 = 0;
    verticalMax: f64 = Math.PI;
    mouseDragOn: bool = false;

    private pointerX: f64 = 0;
    private pointerY: f64 = 0;
    private moveForward: bool = false;
    private moveBackward: bool = false;
    private moveLeft: bool = false;
    private moveRight: bool = false;
    private moveUp: bool = false;
    private moveDown: bool = false;
    private lat: f64 = 0;
    private lon: f64 = 0;

    constructor(object: Object3D, domElement: GPURenderer? = null) {
        super(object);
        this.domElement = domElement;
        this.setOrientation();
    }

    /// Reads lat/lon from the object's current direction.
    private setOrientation(): void {
        _dir.set(0, 0, -1).applyQuaternion(this.object.quaternion);
        _spherical.setFromVector3(_dir);
        this.lat = 90 - _spherical.phi * 180 / Math.PI;
        this.lon = _spherical.theta * 180 / Math.PI;
    }

    lookAt<T>(x: T, y: f64 = 0, z: f64 = 0): FirstPersonControls {
        this.object.lookAt<T>(x, y, z);
        this.setOrientation();
        return this;
    }

    override keyboardEvent(event: KeyboardEvent): bool {
        if (!this.enabled) return false;
        const down = event.phase != "up";
        const k = <i32>event.key;
        if (k == KEY_W || k == KEY_UP) this.moveForward = down;
        else if (k == KEY_S || k == KEY_DOWN) this.moveBackward = down;
        else if (k == KEY_A || k == KEY_LEFT) this.moveLeft = down;
        else if (k == KEY_D || k == KEY_RIGHT) this.moveRight = down;
        else if (k == KEY_R) this.moveUp = down;
        else if (k == KEY_F) this.moveDown = down;
        else return false;
        return true;
    }

    override capturing(): bool { return this.mouseDragOn; }

    override pointerDown(event: PointerEvent): void {
        if (!this.enabled) return;
        if (this.activeLook) this.moveForward = true;
        this.mouseDragOn = true;
        event.hit();
    }

    override pointerMove(event: PointerEvent): void {
        const r = this.domElement;
        if (r == null) return;
        r.getSize(_size);
        this.pointerX = <f64>event.position.x - _size.x / 2;
        this.pointerY = <f64>event.position.y - _size.y / 2;
    }

    override pointerUp(event: PointerEvent): void {
        if (this.activeLook) this.moveForward = false;
        this.mouseDragOn = false;
    }

    override update(delta: f64 = -1): bool {
        if (!this.enabled || delta <= 0) return false;
        const o = this.object;
        let autoSpeed: f64 = 0;
        if (this.heightSpeed) {
            const y = Math.max(this.heightMin, Math.min(this.heightMax, o.position.y));
            autoSpeed = delta * (y - this.heightMin) * this.heightCoef;
        }
        const speed = delta * this.movementSpeed;
        if (this.moveForward || (this.autoForward && !this.moveBackward)) o.translateZ(-(speed + autoSpeed));
        if (this.moveBackward) o.translateZ(speed);
        if (this.moveLeft) o.translateX(-speed);
        if (this.moveRight) o.translateX(speed);
        if (this.moveUp) o.translateY(speed);
        if (this.moveDown) o.translateY(-speed);
        const look = this.activeLook ? delta * this.lookSpeed : 0;
        const ratio = this.constrainVertical ? Math.PI / (this.verticalMax - this.verticalMin) : 1;
        this.lon -= this.pointerX * look;
        if (this.lookVertical) this.lat -= this.pointerY * look * ratio;
        this.lat = Math.max(-85, Math.min(85, this.lat));
        let phi = (90 - this.lat) * Math.PI / 180;
        const theta = this.lon * Math.PI / 180;
        if (this.constrainVertical) phi = this.verticalMin + phi / Math.PI * (this.verticalMax - this.verticalMin);
        _target.setFromSphericalCoords(1, phi, theta).add(o.position);
        o.lookAt<Vector3>(_target);
        this.changed();
        return true;
    }
}
