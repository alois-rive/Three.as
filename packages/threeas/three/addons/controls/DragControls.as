// three.js examples/jsm/controls/DragControls.js: drag objects across the
// plane facing the camera. Events "dragstart", "drag", "dragend" (the
// object in `event.object`), "hoveron" and "hoveroff". Add it to
// ThreeLayout's `tools` so a drag does not also orbit.

import { PointerEvent } from "rive/events";
import { Controls } from "../../extras/Controls";
import { Event } from "../../core/EventDispatcher";
import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { GPURenderer } from "../../renderers/GPURenderer";
import { Raycaster, Intersection } from "../../core/Raycaster";
import { Plane } from "../../math/Plane";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Matrix4 } from "../../math/Matrix4";

const _pointer = new Vector2();
const _intersection = new Vector3();
const _worldPosition = new Vector3();
const _size = new Vector2();

export class DragControls extends Controls {
    objects: Array<Object3D>;
    camera: Camera;
    domElement: GPURenderer?;
    recursive: bool = true;
    transformGroup: bool = false;
    raycaster: Raycaster = new Raycaster();

    private selected: Object3D? = null;
    private hovered: Object3D? = null;
    private intersections: Array<Intersection> = [];
    private plane: Plane = new Plane();
    private offset: Vector3 = new Vector3();
    private inverseMatrix: Matrix4 = new Matrix4();

    constructor(objects: Array<Object3D>, camera: Camera, domElement: GPURenderer? = null) {
        super(camera);
        this.objects = objects;
        this.camera = camera;
        this.domElement = domElement;
    }

    override capturing(): bool { return this.selected != null; }

    private aim(event: PointerEvent): void {
        const r = this.domElement;
        const w = r != null ? Math.max(1, r.getSize(_size).x) : 1, h = r != null ? Math.max(1, _size.y) : 1;
        _pointer.set(<f64>event.position.x / w * 2 - 1, -(<f64>event.position.y / h) * 2 + 1);
        this.camera.updateMatrixWorld();
        this.raycaster.setFromCamera(_pointer, this.camera);
    }

    private emit(type: string, object: Object3D): void {
        if (!this.hasListeners(type)) return;
        const e = new Event(type);
        e.object = object;
        this.dispatchEvent(e);
    }

    override pointerDown(event: PointerEvent): void {
        if (!this.enabled) return;
        this.aim(event);
        this.intersections.length = 0;
        this.raycaster.intersectObjects(this.objects, this.recursive, this.intersections);
        if (this.intersections.length == 0) return;
        const hit = this.transformGroup ? this.objects[0] : this.intersections[0].object;
        this.selected = hit;
        this.camera.getWorldDirection(this.plane.normal);
        this.plane.setFromNormalAndCoplanarPoint(this.plane.normal, _worldPosition.setFromMatrixPosition(hit.matrixWorld));
        if (this.raycaster.ray.intersectPlane(this.plane, _intersection) != null) {
            const p = hit.parent;
            if (p != null) this.inverseMatrix.copy(p.matrixWorld).invert(); else this.inverseMatrix.identity();
            this.offset.copy(_intersection).sub(_worldPosition.setFromMatrixPosition(hit.matrixWorld));
        }
        this.emit("dragstart", hit);
        event.hit();
    }

    override pointerMove(event: PointerEvent): void {
        if (!this.enabled) return;
        this.aim(event);
        const selected = this.selected;
        if (selected != null) {
            if (this.raycaster.ray.intersectPlane(this.plane, _intersection) != null) {
                selected.position.copy(_intersection.sub(this.offset).applyMatrix4(this.inverseMatrix));
            }
            this.emit("drag", selected);
            event.hit();
            return;
        }
        this.intersections.length = 0;
        this.raycaster.intersectObjects(this.objects, this.recursive, this.intersections);
        const hit: Object3D? = this.intersections.length > 0
            ? (this.transformGroup ? this.objects[0] : this.intersections[0].object) : null;
        if (hit !== this.hovered) {
            const old = this.hovered;
            if (old != null) this.emit("hoveroff", old);
            if (hit != null) this.emit("hoveron", hit);
            this.hovered = hit;
        }
    }

    override pointerUp(event: PointerEvent): void {
        const selected = this.selected;
        if (selected == null) return;
        this.emit("dragend", selected);
        this.selected = null;
        event.hit();
    }
}
