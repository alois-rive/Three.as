// ShaderMaterial uniforms: rive . --test

import { Tests } from "rive/test";
import { Uniform, ShaderMaterial } from "../three/materials/ShaderMaterial";
import { Vector2 } from "../three/math/Vector2";
import { Vector3 } from "../three/math/Vector3";
import { Matrix4 } from "../three/math/Matrix4";
import { Color } from "../three/math/Color";
import { Texture } from "../three/textures/Texture";

export class ShaderMaterialTests extends Tests {
    override run(): void {
        group("Uniform", () => {
            test("WGSL sizes and alignments", (expect) => {
                expect.that(<f64>new Uniform<f64>(1).size()).is(4);
                expect.that(<f64>new Uniform<Vector2>(new Vector2()).align()).is(8);
                expect.that(<f64>new Uniform<Vector3>(new Vector3()).size()).is(12);
                expect.that(<f64>new Uniform<Vector3>(new Vector3()).align()).is(16);
                expect.that(<f64>new Uniform<Color>(new Color()).size()).is(12);
                expect.that(<f64>new Uniform<Matrix4>(new Matrix4()).size()).is(64);
                expect.that(<f64>new Uniform<Texture>(new Texture()).size()).is(0);
                expect.that(new Uniform<Texture>(new Texture()).texture() != null).is(true);
            });
            test("writes values and keeps them typed", (expect) => {
                const m = new ShaderMaterial({ shader: "x" });
                m.uniforms.set("time", new Uniform<f64>(0));
                m.uniforms.set("dir", new Uniform<Vector3>(new Vector3(1, 2, 3)));
                m.uniform<f64>("time").value += 0.5;
                const f = new Float32Array(8);
                m.uniforms.get("time").write(f, 0);
                m.uniforms.get("dir").write(f, 16);
                expect.that(<f64>f[0]).is(0.5);
                expect.that(<f64>f[5]).is(2);
            });
        });
    }
}
