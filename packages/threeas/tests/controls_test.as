// Controls driven by synthetic pointer events: rive . --test

import { Tests } from "rive/test";
import { PointerEvent } from "rive/events";
import { Vector } from "rive/vector";
import * as THREE from "../three/Three";
import { TrackballControls } from "../three/addons/controls/TrackballControls";
import { FlyControls } from "../three/addons/controls/FlyControls";
import { FirstPersonControls } from "../three/addons/controls/FirstPersonControls";
import { DragControls } from "../three/addons/controls/DragControls";
import { TransformControls } from "../three/addons/controls/TransformControls";

function ev(x: f64, y: f64): PointerEvent { return new PointerEvent(0, Vector.xy(<f32>x, <f32>y)); }

class Count extends THREE.EventListener {
    n: i32 = 0;
    value: bool = false;
    override handleEvent(event: THREE.Event): void { this.n++; this.value = event.value; }
}

export class ControlsTests extends Tests {
    override run(): void {
        group("controls", () => {
            test("TrackballControls rotates around its target", (expect) => {
                const cam = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
                cam.position.set(0, 0, 5);
                const c = new TrackballControls(cam);
                c.staticMoving = true;
                const change = new Count();
                c.addEventListener("change", change);
                c.pointerDown(ev(0.5, 0.5));
                c.pointerMove(ev(0.7, 0.5));
                c.update();
                c.pointerUp(ev(0.7, 0.5));
                expect.that(Math.abs(cam.position.length() - 5) < 1e-6).is(true);
                expect.that(Math.abs(cam.position.x) > 0.01).is(true);
                expect.that(change.n > 0).is(true);
            });
            test("FlyControls and FirstPersonControls move forward on a press", (expect) => {
                const a = new THREE.Object3D();
                const fly = new FlyControls(a);
                fly.movementSpeed = 2;
                fly.pointerDown(ev(0, 0));
                fly.update(0.5);
                expect.that(Math.abs(a.position.z + 1) < 1e-6).is(true);
                const b = new THREE.PerspectiveCamera();
                const fp = new FirstPersonControls(b);
                fp.lookSpeed = 0;
                fp.pointerDown(ev(0, 0));
                fp.update(1);
                expect.that(b.position.z < -0.99).is(true);
            });
            test("DragControls drags across the camera-facing plane", (expect) => {
                const cam = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
                cam.position.set(0, 0, 5);
                cam.updateMatrixWorld();
                const box = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1));
                const scene = new THREE.Scene();
                scene.add(box);
                scene.updateMatrixWorld();
                const drag = new DragControls([box], cam);
                const started = new Count();
                drag.addEventListener("dragstart", started);
                // Without a renderer the viewport is 1 x 1: (0.5, 0.5) is the centre.
                drag.pointerDown(ev(0.5, 0.5));
                expect.that(started.n).is(1);
                expect.that(drag.capturing()).is(true);
                drag.pointerMove(ev(0.6, 0.5));
                drag.pointerUp(ev(0.6, 0.5));
                expect.that(box.position.x > 0.4 && box.position.x < 0.55).is(true);   // 5 tan(25) 0.2
                expect.that(Math.abs(box.position.z) < 1e-6).is(true);
            });
            test("TransformControls drags along an axis", (expect) => {
                const cam = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
                cam.position.set(0, 0, 5);
                cam.updateMatrixWorld();
                const box = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1));
                const scene = new THREE.Scene();
                scene.add(box);
                const tc = new TransformControls(cam);
                tc.attach(box);
                scene.add(tc.getHelper());
                scene.updateMatrixWorld();
                const dragging = new Count();
                tc.addEventListener("dragging-changed", dragging);
                // The X arrow's head, a little right of the centre.
                let x: f64 = 0.5;
                while (x < 0.75 && tc.axis != "X") {
                    tc.pointerMove(ev(x, 0.5));
                    x += 0.01;
                }
                expect.that(tc.axis).is("X");
                tc.pointerDown(ev(x, 0.5));
                expect.that(dragging.value).is(true);
                tc.pointerMove(ev(x + 0.1, 0.52));
                tc.pointerUp(ev(x + 0.1, 0.52));
                expect.that(dragging.value).is(false);
                expect.that(box.position.x > 0.2).is(true);
                expect.that(box.position.y).is(0);
            });
        });
    }
}
