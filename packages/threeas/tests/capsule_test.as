// Capsule (three/addons/math/Capsule): rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";
import { Capsule } from "../three/addons/math/Capsule";

function near(a: f64, b: f64): bool { return Math.abs(a - b) < 1e-9; }

function box(x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64): THREE.Box3 {
    return new THREE.Box3(new THREE.Vector3(x0, y0, z0), new THREE.Vector3(x1, y1, z1));
}

export class CapsuleTests extends Tests {
    override run(): void {
        group("capsule", () => {
            test("defaults, set, copy, clone, center, translate", (expect) => {
                const c = new Capsule();
                expect.that(c.start.y).is(0);
                expect.that(c.end.y).is(1);
                expect.that(c.radius).is(1);
                const center = c.getCenter(new THREE.Vector3());
                expect.that(center.y).is(0.5);

                const s = new THREE.Vector3(1, 2, 3);
                c.set(s, new THREE.Vector3(1, 4, 3), 0.5);
                s.x = 9;   // set copies
                expect.that(c.start.x).is(1);
                expect.that(c.radius).is(0.5);

                const d = c.clone();
                d.translate(new THREE.Vector3(0, 1, 0));
                expect.that(d.start.y).is(3);
                expect.that(d.end.y).is(5);
                expect.that(c.start.y).is(2);   // the clone has its own vectors
                expect.that(d.radius).is(0.5);

                const e = new Capsule().copy(d);
                expect.that(e.end.y).is(5);
                expect.that(e.getCenter(new THREE.Vector3()).y).is(4);
            });

            test("intersectsBox", (expect) => {
                const c = new Capsule(new THREE.Vector3(0, 0, 0), new THREE.Vector3(0, 1, 0), 0.5);
                // Beside, within the radius, beyond it.
                expect.that(c.intersectsBox(box(0.4, 0, 0, 1, 1, 1))).is(true);
                expect.that(c.intersectsBox(box(0.6, 0, 0, 1, 1, 1))).is(false);
                expect.that(c.intersectsBox(box(1, 0, 0, 2, 1, 1))).is(false);
                // Above the end cap, within and beyond the radius.
                expect.that(c.intersectsBox(box(-1, 1.4, -1, 1, 3, 1))).is(true);
                expect.that(c.intersectsBox(box(-1, 2, -1, 1, 3, 1))).is(false);
                // Below the start cap, in z.
                expect.that(c.intersectsBox(box(-1, -3, -1, 1, -0.6, 1))).is(false);
                expect.that(c.intersectsBox(box(-1, -1, -0.3, 1, -0.4, 1))).is(true);
                // Around the whole capsule.
                expect.that(c.intersectsBox(box(-5, -5, -5, 5, 5, 5))).is(true);
                expect.that(near(c.radius, 0.5)).is(true);
            });
        });
    }
}
