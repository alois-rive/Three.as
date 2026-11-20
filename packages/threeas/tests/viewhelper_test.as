// The ViewHelper addon: rive . --test

import { Tests } from "rive/test";
import { PointerEvent } from "rive/events";
import { Vector } from "rive/vector";
import * as THREE from "../three/Three";
import { ViewHelper } from "../three/addons/helpers/ViewHelper";

function ev(x: f64, y: f64): PointerEvent { return new PointerEvent(0, Vector.xy(<f32>x, <f32>y)); }

class Count extends THREE.EventListener {
    n: i32 = 0;
    override handleEvent(event: THREE.Event): void { this.n++; }
}

/// A camera 10 from `center` along +z, looking at it (identity rotation),
/// and a helper without a renderer: its 128 x 128 gizmo is the whole
/// element, so the +X sprite (at 1 of the camera's +-2) is at (96, 64).
function setup(): ViewHelper {
    const camera = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
    camera.position.set(1, 2, 13);
    const helper = new ViewHelper(camera);
    helper.center.set(1, 2, 3);
    return helper;
}

export class ViewHelperTests extends Tests {
    override run(): void {
        group("ViewHelper", () => {
            test("three axes and six sprites", (expect) => {
                const helper = setup();
                let meshes = 0, sprites = 0;
                for (let i = 0; i < helper.children.length; i++) {
                    const c = helper.children[i];
                    if (c instanceof THREE.Mesh) meshes++;
                    if (c instanceof THREE.Sprite) sprites++;
                }
                expect.that(meshes).is(3);
                expect.that(sprites).is(6);
                expect.that(helper.isViewHelper).is(true);
                expect.that(helper.animating).is(false);
            });
            test("a click on a sprite starts the turn; elsewhere it does not", (expect) => {
                const helper = setup();
                expect.that(helper.handleClick(ev(10, 10))).is(false);
                expect.that(helper.animating).is(false);
                expect.that(helper.handleClick(ev(96, 64))).is(true);
                expect.that(helper.animating).is(true);
                // No second turn while one runs.
                expect.that(helper.handleClick(ev(96, 64))).is(false);
            });
            test("update ends with the camera on the axis, at the same distance", (expect) => {
                const helper = setup();
                const camera = helper.camera;
                helper.handleClick(ev(96, 64));
                let frames = 0;
                while (helper.animating && frames < 1000) {
                    helper.update(1.0 / 60);
                    frames++;
                }
                expect.that(helper.animating).is(false);
                // A quarter turn at 2 pi a second: 15 frames.
                expect.that(frames > 5 && frames < 30).is(true);
                const offset = new THREE.Vector3().copy(camera.position).sub(helper.center);
                expect.that(Math.abs(offset.length() - 10) < 1e-6).is(true);
                expect.that(Math.abs(offset.x - 10) < 1e-6).is(true);
                camera.updateMatrixWorld();
                const dir = camera.getWorldDirection(new THREE.Vector3());
                expect.that(Math.abs(dir.x + 1) < 1e-6).is(true);
            });
            test("the -Y sprite turns the camera below the center", (expect) => {
                const helper = setup();
                const camera = helper.camera;
                // -Y at (0, -1): pixel (64, 96).
                expect.that(helper.handleClick(ev(64, 96))).is(true);
                for (let i = 0; i < 1000 && helper.animating; i++) helper.update(0.05);
                expect.that(Math.abs(camera.position.y - (2 - 10)) < 1e-6).is(true);
                expect.that(Math.abs(camera.position.x - 1) < 1e-6).is(true);
            });
            test("dispose dispatches dispose on every geometry, material and texture", (expect) => {
                const helper = setup();
                const seen: Array<THREE.EventDispatcher> = [];
                const counts: Array<Count> = [];
                const watch = (d: THREE.EventDispatcher, seen: Array<THREE.EventDispatcher>, counts: Array<Count>): void => {
                    if (seen.indexOf(d) >= 0) return;
                    const c = new Count();
                    d.addEventListener("dispose", c);
                    seen.push(d);
                    counts.push(c);
                };
                let textures = 0;
                for (let i = 0; i < helper.children.length; i++) {
                    const o = helper.children[i];
                    if (o instanceof THREE.Mesh) {
                        const m = o as THREE.Mesh;
                        watch(m.geometry, seen, counts);
                        watch(m.material, seen, counts);
                    } else if (o instanceof THREE.Sprite) {
                        const s = o as THREE.Sprite;
                        watch(s.material, seen, counts);
                        const map = s.material.map;
                        if (map != null) { watch(map, seen, counts); textures++; }
                    }
                }
                expect.that(textures).is(6);
                // One shared geometry, 3 + 6 materials, 6 textures.
                expect.that(seen.length).is(16);
                helper.dispose();
                let once = 0;
                for (let i = 0; i < counts.length; i++) if (counts[i].n == 1) once++;
                expect.that(once).is(16);
            });
        });
    }
}
