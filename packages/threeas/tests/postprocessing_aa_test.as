// Anti-aliasing passes without a GPU (SMAAPass, SSAARenderPass,
// TAARenderPass): rive . --test

import { Tests } from "rive/test";
import { SMAAPass } from "../three/addons/postprocessing/SMAAPass";
import { SSAARenderPass, JitterVectors } from "../three/addons/postprocessing/SSAARenderPass";
import { TAARenderPass } from "../three/addons/postprocessing/TAARenderPass";
import { smaaAreaTexture, smaaSearchTexture } from "../three/addons/postprocessing/SMAATextures";
import { SMAAEdgesShader, SMAAWeightsShader, SMAABlendShader } from "../three/addons/shaders/SMAAShader";
import { Scene } from "../three/scenes/Scene";
import { PerspectiveCamera } from "../three/cameras/PerspectiveCamera";
import { Vector2 } from "../three/math/Vector2";
import { Texture } from "../three/textures/Texture";
import { AdditiveBlending, LinearFilter, NearestFilter, RGFormat, RedFormat, NoBlending } from "../three/constants";

export class PostProcessingAATests extends Tests {
    override run(): void {
        group("SMAA textures", () => {
            test("area: 160 x 560 red-green, bilinear", (expect) => {
                const t = smaaAreaTexture();
                expect.that(<f64>t.width).is(160);
                expect.that(<f64>t.height).is(560);
                expect.that(<f64>t.format).is(<f64>RGFormat);
                expect.that(<f64>t.minFilter).is(<f64>LinearFilter);
                expect.that(t.flipY).is(false);
                const d = t.data as Uint8Array;
                expect.that(<f64>d.length).is(160 * 560 * 2);
                // The first sub-texture's corner (no crossing edges, distance
                // 0) has no area; the texture is not empty.
                expect.that(<f64>d[0] + <f64>d[1]).is(0);
                let sum: f64 = 0;
                for (let i = 0; i < d.length; i++) sum += <f64>d[i];
                expect.that(sum > 1000000).is(true);
            });
            test("search: 66 x 33 red, nearest", (expect) => {
                const t = smaaSearchTexture();
                expect.that(<f64>t.width).is(66);
                expect.that(<f64>t.height).is(33);
                expect.that(<f64>t.format).is(<f64>RedFormat);
                expect.that(<f64>t.magFilter).is(<f64>NearestFilter);
                const d = t.data as Uint8Array;
                expect.that(<f64>d.length).is(66 * 33);
                let max: f64 = 0;
                for (let i = 0; i < d.length; i++) max = Math.max(max, <f64>d[i]);
                // Search lengths are 0 to 2 pixels (255 x the texel).
                expect.that(max > 0 && max <= 2).is(true);
            });
        });
        group("SMAAPass", () => {
            test("three stages wired as three.js", (expect) => {
                const pass = new SMAAPass(200, 100);
                expect.that(<f64>pass.edgesRT.width).is(200);
                expect.that(pass.edgesRT.isHDR).is(true);
                expect.that(pass.materialWeights.uniform<Texture>("tDiffuse").value === pass.edgesRT.texture).is(true);
                expect.that(pass.materialWeights.uniform<Texture>("tArea").value === pass.areaTexture).is(true);
                expect.that(pass.materialWeights.uniform<Texture>("tSearch").value === pass.searchTexture).is(true);
                expect.that(pass.materialBlend.uniform<Texture>("tDiffuse").value === pass.weightsRT.texture).is(true);
                expect.that(pass.materialEdges.uniform<Vector2>("resolution").value.x).is(1 / 200);
                pass.setSize(400, 50);
                expect.that(<f64>pass.weightsRT.height).is(50);
                expect.that(pass.materialBlend.uniform<Vector2>("resolution").value.y).is(1 / 50);
                expect.that(pass.needsSwap).is(true);
            });
            test("shader definitions", (expect) => {
                expect.that(SMAAEdgesShader.shader).is("three/shaders/post/smaa_edges");
                expect.that(SMAAWeightsShader.createMaterial().uniforms.keys()[3]).is("tSearch");
                const m = SMAABlendShader.createMaterial();
                expect.that(<f64>m.blending).is(<f64>NoBlending);
                expect.that(m.uniforms.keys()[2]).is("tColor");
            });
        });
        group("SSAARenderPass", () => {
            test("defaults and the jitter tables", (expect) => {
                const pass = new SSAARenderPass(new Scene(), new PerspectiveCamera());
                expect.that(<f64>pass.sampleLevel).is(4);
                expect.that(pass.unbiased).is(true);
                expect.that(<f64>pass.clearColor).is(0);
                expect.that(pass.clearAlpha).is(0);
                expect.that(<f64>pass.copyMaterial.blending).is(<f64>AdditiveBlending);
                expect.that(<f64>JitterVectors.length).is(6);
                for (let level = 0; level < 6; level++) {
                    expect.that(<f64>JitterVectors[level].length).is(<f64>(2 << level));
                    // Every offset is on the [-8, 8) grid.
                    for (let i = 0; i < JitterVectors[level].length; i++) {
                        const v = JitterVectors[level][i];
                        expect.that(v >= -8 && v < 8).is(true);
                    }
                }
                expect.that(<f64>JitterVectors[2][0]).is(-2);
                expect.that(<f64>JitterVectors[5][63]).is(7);
            });
        });
        group("TAARenderPass", () => {
            test("defaults", (expect) => {
                const pass = new TAARenderPass(new Scene(), new PerspectiveCamera(), 0x112233, 1);
                expect.that(<f64>pass.sampleLevel).is(0);
                expect.that(pass.accumulate).is(false);
                expect.that(<f64>pass.accumulateIndex).is(-1);
                expect.that(<f64>pass.clearColor).is(<f64>0x112233);
                pass.accumulateIndex = 5;
                pass.setSize(10, 10);
                expect.that(<f64>pass.accumulateIndex).is(-1);
            });
        });
    }
}
