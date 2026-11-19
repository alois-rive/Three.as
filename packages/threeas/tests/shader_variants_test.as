// Baked shader variant names (three/renderers/gpu/ShaderVariants): rive . --test
// The vectors are also `tools/threeas_bake.sh --self-test`'s: keep both lists
// the same, so the bake tool names a variant as the renderer looks it up.

import { Tests } from "rive/test";
import { fnv1a64, bakedShaderName, BAKED_SHADER_PREFIX } from "../three/renderers/gpu/ShaderVariants";
import { THREE_WGSL_HASH } from "../three/renderers/gpu/ShaderSourceHash";

const KEY: string = "kind=3;present=1;roles=0;flags=0;cutout=0;flat=0;env=0;scene=0;fog=0;hemi=1;linear=0;lights=d;vs=vs_main;fs=fs_main";

export class ShaderVariantsTests extends Tests {
    override run(): void {
        group("ShaderVariants", () => {
            test("FNV-1a 64 vectors", (expect) => {
                expect.that(fnv1a64("")).is("cbf29ce484222325");
                expect.that(fnv1a64("a")).is("af63dc4c8601ec8c");
                expect.that(fnv1a64("foobar")).is("85944171f73967e8");
                expect.that(fnv1a64("0123456789abcdef|" + KEY)).is("12602aff92ec183d");
            });
            test("a variant's asset name", (expect) => {
                expect.that(bakedShaderName(KEY, "0123456789abcdef")).is("threeas_baked/v_12602aff92ec183d");
                const name = bakedShaderName(KEY);
                expect.that(name.startsWith(BAKED_SHADER_PREFIX)).is(true);
                expect.that(<f64>name.length).is(<f64>(BAKED_SHADER_PREFIX.length + 16));
                expect.that(name).is(BAKED_SHADER_PREFIX + fnv1a64(THREE_WGSL_HASH + "|" + KEY));
                // Another three.wgsl, another name: a stale bake is never found.
                expect.that(name != bakedShaderName(KEY, "0000000000000000")).is(true);
            });
        });
    }
}
