// Texture transforms and channels: rive . --test

import { Tests } from "rive/test";
import { Texture } from "../three/textures/Texture";
import { Vector2 } from "../three/math/Vector2";
import { Vector3 } from "../three/math/Vector3";

function apply(t: Texture, u: f64, v: f64): Vector2 {
    const p = new Vector3(u, v, 1).applyMatrix3(t.matrix);
    return new Vector2(p.x, p.y);
}

export class TextureTests extends Tests {
    override run(): void {
        group("Texture.matrix", () => {
            test("identity by default", (expect) => {
                const t = new Texture();
                t.updateMatrix();
                const p = apply(t, 0.25, 0.75);
                expect.that(Math.abs(p.x - (0.25)) < 1e-9).is(true);
                expect.that(Math.abs(p.y - (0.75)) < 1e-9).is(true);
            });
            test("offset and repeat, as uv * repeat + offset", (expect) => {
                const t = new Texture();
                t.offset.set(0.5, 0.25);
                t.repeat.set(2, 4);
                t.updateMatrix();
                const p = apply(t, 1, 1);
                expect.that(Math.abs(p.x - (2.5)) < 1e-9).is(true);
                expect.that(Math.abs(p.y - (4.25)) < 1e-9).is(true);
            });
            test("rotation about the center", (expect) => {
                const t = new Texture();
                t.center.set(0.5, 0.5);
                t.rotation = Math.PI / 2;
                t.updateMatrix();
                // The center stays; (1, 0.5) turns to (0.5, 0) (three.js rotates uvs clockwise).
                const c = apply(t, 0.5, 0.5);
                expect.that(Math.abs(c.x - (0.5)) < 1e-9).is(true);
                expect.that(Math.abs(c.y - (0.5)) < 1e-9).is(true);
                const p = apply(t, 1, 0.5);
                expect.that(Math.abs(p.x - (0.5)) < 1e-9).is(true);
                expect.that(Math.abs(p.y - (0)) < 1e-9).is(true);
            });
            test("channel defaults to the first uv set", (expect) => {
                expect.that(<f64>new Texture().channel).is(0);
            });
        });
    }
}
