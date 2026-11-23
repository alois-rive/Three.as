// GPUComputationRenderer (three/addons/misc) without a GPU: variables,
// init's errors and targets, the dependency uniforms and ping-pong (the
// 32-bit float formats it asks for: float_targets_test). Pixels are
// checked on the gallery's GpgpuBirds example. rive . --test

import { Tests } from "rive/test";
import { TextureFormat } from "rive/gpu_enums";
import {
    GPUComputationRenderer, GPU_COMPUTATION_SHADER,
} from "../three/addons/misc/GPUComputationRenderer";
import { Uniform, UniformBase } from "../three/materials/ShaderMaterial";
import { Texture } from "../three/textures/Texture";
import { gpuFormat } from "../three/textures/DataUpload";
import { Vector2 } from "../three/math/Vector2";
import { Event, EventListener } from "../three/core/EventDispatcher";
import {
    ClampToEdgeWrapping, FloatType, HalfFloatType, LinearFilter, NearestFilter, RGBAFormat, RepeatWrapping,
    UnsignedByteType,
} from "../three/constants";

class CountDisposes extends EventListener {
    count: i32 = 0;
    override handleEvent(event: Event): void { this.count++; }
}

export class GPUComputationRendererTests extends Tests {
    override run(): void {
        group("GPUComputationRenderer", () => {
            test("createTexture: sizeX x sizeY RGBA 32-bit floats", (expect) => {
                const gpu = new GPUComputationRenderer(8, 4, null);
                const t = gpu.createTexture();
                expect.that(<f64>t.width).is(8);
                expect.that(<f64>t.height).is(4);
                expect.that((t.data as Float32Array).length).is(8 * 4 * 4);
                expect.that(<f64>t.type).is(<f64>FloatType);
                expect.that(<f64>t.format).is(<f64>RGBAFormat);
                expect.that(t.internalFormat!).is("RGBA32F");
                expect.that(<f64>gpuFormat(t.format, t.type, t.internalFormat)).is(<f64>TextureFormat.rgba32float);
                expect.that(t.isHDRSource).is(false);
                expect.that(<f64>t.minFilter).is(<f64>NearestFilter);
            });
            test("addVariable: a material of the shader asset, resolution first", (expect) => {
                const gpu = new GPUComputationRenderer(16, 8, null);
                const v = gpu.addVariable("textureVelocity", "shaders/velocity", gpu.createTexture());
                expect.that(v.name).is("textureVelocity");
                expect.that(v.material.shader).is("shaders/velocity");
                expect.that(v.material.name).is("GPUComputationShader");
                expect.that(v.material.uniforms.keys()[0]).is("resolution");
                const r = v.material.uniform<Vector2>("resolution").value;
                expect.that(r.x).is(16);
                expect.that(r.y).is(8);
                expect.that(<f64>v.minFilter).is(<f64>NearestFilter);
                expect.that(<f64>v.magFilter).is(<f64>NearestFilter);
                expect.that(<f64>v.wrapS).is(0);
                expect.that(v.dependencies == null).is(true);
                expect.that(gpu.variables.length).is(1);
            });
            test("init: a dependency that was not added is an error", (expect) => {
                const gpu = new GPUComputationRenderer(4, 4, null);
                const a = gpu.addVariable("a", "shaders/a", gpu.createTexture());
                const stray = new GPUComputationRenderer(4, 4, null).addVariable("b", "shaders/b", new Texture());
                gpu.setVariableDependencies(a, [a, stray]);
                const error = gpu.init();
                expect.that(error != null).is(true);
                expect.that(error!).is("Variable dependency not found. Variable=a, dependency=b");
            });
            test("init: two targets a variable, dependency uniforms after the caller's", (expect) => {
                const gpu = new GPUComputationRenderer(32, 16, null);
                const vel = gpu.addVariable("textureVelocity", "shaders/velocity", gpu.createTexture());
                const pos = gpu.addVariable("texturePosition", "shaders/position", gpu.createTexture());
                gpu.setVariableDependencies(vel, [pos, vel]);
                gpu.setVariableDependencies(pos, [pos, vel]);
                vel.material.uniforms.set("delta", new Uniform<f64>(0));
                vel.wrapS = RepeatWrapping;
                vel.wrapT = RepeatWrapping;
                expect.that(gpu.init() == null).is(true);
                const keys = vel.material.uniforms.keys();
                expect.that(keys.length).is(4);
                expect.that(keys[0]).is("resolution");
                expect.that(keys[1]).is("delta");
                expect.that(keys[2]).is("texturePosition");
                expect.that(keys[3]).is("textureVelocity");
                expect.that(vel.renderTargets.length).is(2);
                expect.that(pos.renderTargets.length).is(2);
                const rt = vel.renderTargets[0];
                expect.that(<f64>rt.width).is(32);
                expect.that(<f64>rt.height).is(16);
                expect.that(<f64>rt.type).is(<f64>FloatType);
                expect.that(rt.depthBuffer).is(false);
                expect.that(rt.texture.internalFormat!).is("RGBA32F");
                expect.that(<f64>rt.texture.wrapS).is(<f64>RepeatWrapping);
                expect.that(<f64>rt.texture.wrapT).is(<f64>RepeatWrapping);
                expect.that(<f64>rt.texture.minFilter).is(<f64>NearestFilter);
                expect.that(<f64>rt.texture.magFilter).is(<f64>NearestFilter);
                expect.that(<f64>pos.renderTargets[1].texture.wrapS).is(<f64>ClampToEdgeWrapping);
                expect.that(vel.renderTargets[0] !== vel.renderTargets[1]).is(true);
                expect.that(gpu.currentTextureIndex).is(0);
            });
            test("compute: reads the current targets, writes and swaps to the others", (expect) => {
                const gpu = new GPUComputationRenderer(4, 4, null);
                const vel = gpu.addVariable("textureVelocity", "shaders/velocity", gpu.createTexture());
                const pos = gpu.addVariable("texturePosition", "shaders/position", gpu.createTexture());
                gpu.setVariableDependencies(vel, [pos, vel]);
                gpu.setVariableDependencies(pos, [pos, vel]);
                expect.that(gpu.init() == null).is(true);
                expect.that(gpu.getCurrentRenderTarget(pos) === pos.renderTargets[0]).is(true);
                expect.that(gpu.getAlternateRenderTarget(pos) === pos.renderTargets[1]).is(true);
                gpu.compute();
                expect.that(gpu.currentTextureIndex).is(1);
                // The pass read the previous values ...
                expect.that(vel.material.uniform<Texture>("texturePosition").value === pos.renderTargets[0].texture).is(true);
                expect.that(pos.material.uniform<Texture>("textureVelocity").value === vel.renderTargets[0].texture).is(true);
                // ... and the results are current now.
                expect.that(gpu.getCurrentRenderTarget(pos) === pos.renderTargets[1]).is(true);
                expect.that(gpu.getAlternateRenderTarget(vel) === vel.renderTargets[0]).is(true);
                gpu.compute();
                expect.that(gpu.currentTextureIndex).is(0);
                expect.that(pos.material.uniform<Texture>("texturePosition").value === pos.renderTargets[1].texture).is(true);
                expect.that(gpu.getCurrentRenderTarget(vel) === vel.renderTargets[0]).is(true);
            });
            test("createShaderMaterial shares the caller's uniforms; addResolutionDefine updates", (expect) => {
                const gpu = new GPUComputationRenderer(64, 2, null);
                const uniforms = new Map<string, UniformBase>();
                const u = new Uniform<f64>(3);
                uniforms.set("k", u);
                const m = gpu.createShaderMaterial(GPU_COMPUTATION_SHADER, uniforms);
                expect.that(m.shader).is("three/shaders/misc/gpu_computation");
                expect.that(m.uniforms.keys()[0]).is("resolution");
                expect.that(m.uniform<f64>("k") === u).is(true);
                m.uniform<Vector2>("resolution").value.set(1, 1);
                gpu.addResolutionDefine(m);
                expect.that(m.uniform<Vector2>("resolution").value.x).is(64);
                expect.that(m.uniforms.size).is(2);
            });
            test("createRenderTarget: zero arguments take the defaults", (expect) => {
                const gpu = new GPUComputationRenderer(5, 7, null);
                const rt = gpu.createRenderTarget();
                expect.that(<f64>rt.width).is(5);
                expect.that(<f64>rt.height).is(7);
                expect.that(<f64>rt.texture.wrapS).is(<f64>ClampToEdgeWrapping);
                expect.that(<f64>rt.texture.minFilter).is(<f64>NearestFilter);
                const big = gpu.createRenderTarget(10, 20, RepeatWrapping, 0, LinearFilter);
                expect.that(<f64>big.width).is(10);
                expect.that(<f64>big.texture.wrapS).is(<f64>RepeatWrapping);
                expect.that(<f64>big.texture.wrapT).is(<f64>ClampToEdgeWrapping);
                expect.that(<f64>big.texture.minFilter).is(<f64>LinearFilter);
            });
            test("setDataType(HalfFloatType): half float targets", (expect) => {
                const gpu = new GPUComputationRenderer(4, 4, null).setDataType(HalfFloatType);
                const rt = gpu.createRenderTarget();
                expect.that(<f64>rt.type).is(<f64>HalfFloatType);
                expect.that(rt.texture.internalFormat == null).is(true);
                expect.that(<f64>rt.hdrFormat(true)).is(<f64>TextureFormat.rgba16float);
            });
            test("supportError: float targets fall back to half floats", (expect) => {
                expect.that(GPUComputationRenderer.supportError(FloatType, true, true, true) == null).is(true);
                expect.that(GPUComputationRenderer.supportError(FloatType, true, false, true) == null).is(true);
                expect.that(GPUComputationRenderer.supportError(FloatType, true, false, false)!)
                    .is("No support for float render targets.");
                expect.that(GPUComputationRenderer.supportError(HalfFloatType, true, true, false)!)
                    .is("No support for half float render targets.");
                // No device yet: nothing to say.
                expect.that(GPUComputationRenderer.supportError(FloatType, false, false, false) == null).is(true);
                expect.that(GPUComputationRenderer.supportError(UnsignedByteType, true, false, false) == null).is(true);
            });
            test("dispose: the initial textures and every target", (expect) => {
                const gpu = new GPUComputationRenderer(4, 4, null);
                const t = gpu.createTexture();
                const v = gpu.addVariable("a", "shaders/a", t);
                expect.that(gpu.init() == null).is(true);
                const lt = new CountDisposes();
                t.addEventListener("dispose", lt);
                const lr = new CountDisposes();
                v.renderTargets[0].addEventListener("dispose", lr);
                v.renderTargets[1].addEventListener("dispose", lr);
                gpu.dispose();
                expect.that(lt.count).is(1);
                expect.that(lr.count).is(2);
            });
        });
    }
}
