// Post-processing pieces that run without a GPU: rive . --test

import { Tests } from "rive/test";
import { Uniform } from "../three/materials/ShaderMaterial";
import { Vector2 } from "../three/math/Vector2";
import { Texture } from "../three/textures/Texture";
import { RenderTarget } from "../three/renderers/RenderTarget";
import { HalfFloatType, NoBlending, UnsignedByteType } from "../three/constants";
import { CopyShader, LuminosityHighPassShader } from "../three/addons/shaders/PostShaders";

export class PostProcessingTests extends Tests {
    override run(): void {
        group("Uniform.clone", () => {
            test("copies vectors, shares textures", (expect) => {
                const v = new Uniform<Vector2>(new Vector2(1, 2));
                const c = v.clone() as Uniform<Vector2>;
                c.value.x = 5;
                expect.that(v.value.x).is(1);
                const t = new Texture();
                const u = new Uniform<Texture>(t);
                expect.that((u.clone() as Uniform<Texture>).value === t).is(true);
            });
        });
        group("ShaderDefinition", () => {
            test("each material gets its own uniforms", (expect) => {
                const a = CopyShader.createMaterial();
                const b = CopyShader.createMaterial();
                a.uniform<f64>("opacity").value = 0.25;
                expect.that(b.uniform<f64>("opacity").value).is(1);
                expect.that(<f64>a.blending).is(<f64>NoBlending);
                expect.that(a.depthTest).is(false);
                expect.that(a.shader).is("three/shaders/post/copy");
            });
            test("bloom stages share one layout", (expect) => {
                const m = LuminosityHighPassShader.createMaterial();
                expect.that(m.fragmentEntryPoint).is("fs_high_pass");
                expect.that(<f64>m.uniforms.size).is(12);
                expect.that(m.uniforms.keys()[6]).is("tDiffuse");
            });
        });
        group("RenderTarget", () => {
            test("HDR targets and clone", (expect) => {
                const rt = new RenderTarget(64, 32, { type: HalfFloatType });
                expect.that(rt.isHDR).is(true);
                const c = rt.clone();
                expect.that(<f64>c.width).is(64);
                expect.that(<f64>c.type).is(<f64>HalfFloatType);
                expect.that(c.texture !== rt.texture).is(true);
                expect.that(new RenderTarget(4, 4).type == UnsignedByteType).is(true);
            });
        });
    }
}
