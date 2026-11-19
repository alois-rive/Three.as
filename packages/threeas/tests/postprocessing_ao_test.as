// Ambient occlusion passes (SSAOPass, SAOPass, GTAOPass) without a GPU:
// rive . --test

import { Tests } from "rive/test";
import { Scene } from "../three/scenes/Scene";
import { PerspectiveCamera } from "../three/cameras/PerspectiveCamera";
import { OrthographicCamera } from "../three/cameras/OrthographicCamera";
import { Vector2 } from "../three/math/Vector2";
import { Vector3 } from "../three/math/Vector3";
import { Box3 } from "../three/math/Box3";
import { Texture } from "../three/textures/Texture";
import { DepthTexture } from "../three/textures/DepthTexture";
import { Points } from "../three/objects/Points";
import { Mesh } from "../three/objects/Mesh";
import { Object3D } from "../three/core/Object3D";
import { HalfFloatType, FloatType, RedFormat, RepeatWrapping, NearestFilter } from "../three/constants";
import { SSAOPass } from "../three/addons/postprocessing/SSAOPass";
import { SAOPass } from "../three/addons/postprocessing/SAOPass";
import {
    GTAOPass, GTAOPassParameters, GTAOParameters, PoissonDenoiseParameters,
} from "../three/addons/postprocessing/GTAOPass";
import { hidePointsAndLines, restoreHidden, cameraNear, cameraFar, isPerspective } from "../three/addons/postprocessing/AOPassUtils";
import { SSAOShader } from "../three/addons/shaders/SSAOShader";
import { DepthLimitedBlurShader, BlurShaderUtils } from "../three/addons/shaders/DepthLimitedBlurShader";
import { generateMagicSquare, generateMagicSquareNoise } from "../three/addons/shaders/GTAOShader";
import { generatePdSamplePointInitializer } from "../three/addons/shaders/PoissonDenoiseShader";

function near(a: f64, b: f64): bool { return Math.abs(a - b) < 1e-5; }

/// Bytes a material's uniform block takes (as the renderer packs it).
function blockBytes(names: Array<string>, sizes: Array<i32>, aligns: Array<i32>): i32 {
    let size = 0;
    for (let i = 0; i < names.length; i++) {
        if (sizes[i] == 0) continue;
        size = (size + aligns[i] - 1) / aligns[i] * aligns[i] + sizes[i];
    }
    return size;
}

export class PostProcessingAOTests extends Tests {
    override run(): void {
        group("SSAOPass", () => {
            test("defaults, kernel and noise", (expect) => {
                const camera = new PerspectiveCamera(50, 1, 0.5, 40);
                const pass = new SSAOPass(new Scene(), camera, 64, 32);
                expect.that(pass.needsSwap).is(false);
                expect.that(pass.kernelRadius).is(8);
                expect.that(pass.minDistance).is(0.005);
                expect.that(pass.maxDistance).is(0.1);
                expect.that(<f64>pass.output).is(<f64>SSAOPass.OUTPUT.Default);
                expect.that(<f64>SSAOPass.OUTPUT.Normal).is(4);
                expect.that(<f64>pass.kernel.length).is(32);
                let inside = true;
                for (let i = 0; i < pass.kernel.length; i++) {
                    const k = pass.kernel[i];
                    if (k.z < 0 || k.length() > 1.0001) inside = false;
                }
                expect.that(inside).is(true);
                // Denser near the centre: the first sample is at 0.1.
                expect.that(near(pass.kernel[0].length(), 0.1)).is(true);
                const noise = pass.noiseTexture;
                expect.that(<f64>noise.width).is(4);
                expect.that(<f64>noise.format).is(<f64>RedFormat);
                expect.that(<f64>noise.type).is(<f64>FloatType);
                expect.that(<f64>noise.wrapS).is(<f64>RepeatWrapping);
                const rt = pass.normalRenderTarget;
                expect.that(<f64>rt.type).is(<f64>HalfFloatType);
                expect.that(rt.depthTexture != null).is(true);
                expect.that(<f64>rt.texture.magFilter).is(<f64>NearestFilter);
                expect.that(<f64>pass.ssaoRenderTarget.width).is(64);
                const m = pass.ssaoMaterial;
                expect.that(m.uniform<f64>("cameraFar").value).is(40);
                expect.that(m.uniform<f64>("kernelSize").value).is(32);
                expect.that(m.uniform<Texture>("tDepth").value === rt.depthTexture).is(true);
                const a = m.uniform<Float32Array>("kernel").value;
                expect.that(near(<f64>a[4], pass.kernel[1].x)).is(true);
                pass.setSize(128, 64);
                expect.that(<f64>pass.normalRenderTarget.height).is(64);
                expect.that(m.uniform<Vector2>("resolution").value.x).is(128);
            });
            test("kernels of at most 32", (expect) => {
                const pass = new SSAOPass(new Scene(), new PerspectiveCamera(), 8, 8, 64);
                expect.that(<f64>pass.kernel.length).is(32);
                expect.that(<f64>new SSAOPass(new Scene(), new PerspectiveCamera(), 8, 8, 8).kernel.length).is(8);
            });
            test("its uniform block fits", (expect) => {
                const m = SSAOShader.createMaterial();
                const keys = m.uniforms.keys();
                const sizes: Array<i32> = [];
                const aligns: Array<i32> = [];
                for (let i = 0; i < keys.length; i++) {
                    sizes.push(m.uniforms.get(keys[i]).size());
                    aligns.push(m.uniforms.get(keys[i]).align());
                }
                // 2 mat4, 32 vec4, a vec2 and 7 floats (ssao.wgsl's Uniforms).
                expect.that(<f64>blockBytes(keys, sizes, aligns)).is(676);
            });
        });
        group("SAOPass", () => {
            test("params and blur", (expect) => {
                const pass = new SAOPass(new Scene(), new PerspectiveCamera(), new Vector2(32, 16));
                expect.that(pass.params.saoIntensity).is(0.18);
                expect.that(pass.params.saoKernelRadius).is(100);
                expect.that(pass.params.saoBlur).is(true);
                expect.that(<f64>SAOPass.OUTPUT.Normal).is(2);
                expect.that(pass.needsSwap).is(false);
                expect.that(<f64>pass.normalRenderTarget.width).is(32);
                expect.that(pass.saoMaterial.uniform<f64>("perspective").value).is(1);
                const ortho = new SAOPass(new Scene(), new OrthographicCamera());
                expect.that(ortho.saoMaterial.uniform<f64>("perspective").value).is(0);
            });
            test("BlurShaderUtils", (expect) => {
                const w = BlurShaderUtils.createSampleWeights(2, 1);
                expect.that(<f64>w.length).is(3);
                expect.that(near(w[0], 1 / Math.sqrt(2 * Math.PI))).is(true);
                const o = BlurShaderUtils.createSampleOffsets(2, new Vector2(0, 1));
                expect.that(o[2].y).is(2);
                const m = DepthLimitedBlurShader.createMaterial();
                BlurShaderUtils.configure(m, 8, 4, new Vector2(1, 0));
                expect.that(m.uniform<f64>("kernelRadius").value).is(8);
                const offsets = m.uniform<Float32Array>("sampleUvOffsets").value;
                expect.that(<f64>offsets[3 * 4]).is(3);
                const weights = m.uniform<Float32Array>("sampleWeights").value;
                expect.that(near(<f64>weights[4], Math.exp(-1 / 32) / (Math.sqrt(2 * Math.PI) * 4))).is(true);
                BlurShaderUtils.configure(m, 200, 4, new Vector2(1, 0));
                expect.that(m.uniform<f64>("kernelRadius").value).is(64);
            });
        });
        group("GTAOPass", () => {
            test("magic square noise", (expect) => {
                const s = generateMagicSquare(5);
                expect.that(<f64>s.length).is(25);
                let ok = true;
                for (let r = 0; r < 5; r++) {
                    let row = 0, col = 0;
                    for (let c = 0; c < 5; c++) {
                        row += s[r * 5 + c];
                        col += s[c * 5 + r];
                    }
                    if (row != 65 || col != 65) ok = false;
                }
                expect.that(ok).is(true);
                const t = generateMagicSquareNoise(4);
                expect.that(<f64>t.width).is(5);
                expect.that(<f64>t.wrapT).is(<f64>RepeatWrapping);
            });
            test("defaults, gbuffer and parameters", (expect) => {
                const camera = new PerspectiveCamera(50, 1, 1, 100);
                const pass = new GTAOPass(new Scene(), camera, 64, 64);
                expect.that(<f64>GTAOPass.OUTPUT.Off).is(-1);
                expect.that(<f64>GTAOPass.OUTPUT.Denoise).is(5);
                expect.that(pass.needsSwap).is(true);
                expect.that(pass.normalRenderTarget != null).is(true);
                expect.that(<f64>pass.pdNoiseTexture.width).is(64);
                expect.that(pass.gtaoMap === pass.pdRenderTarget.texture).is(true);
                expect.that(pass.gtaoMaterial.uniform<f64>("normalVectorType").value).is(1);
                expect.that(pass.gtaoMaterial.uniform<f64>("cameraFar").value).is(100);
                const a = new GTAOParameters();
                a.radius = 0.5;
                pass.updateGtaoMaterial(a);
                expect.that(pass.gtaoMaterial.uniform<f64>("radius").value).is(0.5);
                expect.that(pass.gtaoMaterial.uniform<f64>("thickness").value).is(1);
                const pd = new PoissonDenoiseParameters();
                pd.samples = 8;
                pass.updatePdMaterial(pd);
                expect.that(pass.pdMaterial.uniform<f64>("samples").value).is(8);
                pass.setSceneClipBox(new Box3(new Vector3(-2, -2, -2), new Vector3(2, 2, 2)));
                expect.that(pass.gtaoMaterial.uniform<f64>("sceneClipBox").value).is(1);
                expect.that(pass.gtaoMaterial.uniform<Vector3>("sceneBoxMax").value.x).is(2);
                // A gbuffer of one's own: depth only, normals from depth.
                const params = new GTAOPassParameters();
                params.depthTexture = new DepthTexture(64, 64);
                const own = new GTAOPass(new Scene(), camera, 64, 64, params);
                expect.that(own.normalRenderTarget == null).is(true);
                expect.that(own.gtaoMaterial.uniform<f64>("normalVectorType").value).is(0);
                expect.that(own.pdMaterial.uniform<Texture>("tDepth").value === params.depthTexture).is(true);
            });
            test("Poisson disk samples", (expect) => {
                const d = generatePdSamplePointInitializer(16, 2, 1);
                expect.that(<f64>d.length).is(128);
                expect.that(near(<f64>d[0], 1)).is(true);
                expect.that(near(<f64>d[2], 0)).is(true);
                expect.that(near(<f64>d[15 * 4 + 2], 1)).is(true);
                expect.that(<f64>generatePdSamplePointInitializer(40, 2, 1).length).is(128);
            });
        });
        group("AO helpers", () => {
            test("points and lines hide for the prepass", (expect) => {
                const scene = new Scene();
                const p = new Points();
                const m = new Mesh();
                scene.add(p);
                scene.add(m);
                const hidden: Array<Object3D> = [];
                hidePointsAndLines(scene, hidden);
                expect.that(p.visible).is(false);
                expect.that(m.visible).is(true);
                restoreHidden(hidden);
                expect.that(p.visible).is(true);
                const o = new OrthographicCamera(-1, 1, 1, -1, 2, 30);
                expect.that(cameraNear(o)).is(2);
                expect.that(cameraFar(o)).is(30);
                expect.that(isPerspective(o)).is(0);
            });
        });
    }
}
