// three.js examples/jsm/shaders/DepthLimitedBlurShader.js:
// DepthLimitedBlurShader (a ShaderDefinition over
// three/shaders/post/depth_limited_blur.wgsl) and BlurShaderUtils.
// KERNEL_RADIUS is the `kernelRadius` uniform (at most 64);
// `sampleUvOffsets` (xy) and `sampleWeights` (x) are Float32Arrays of vec4s.
// Depth comes from a DepthTexture (DEPTH_PACKING 0 only).

import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Vector2 } from "../../math/Vector2";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

/// The largest blur radius (KERNEL_RADIUS, here a uniform).
export const DEPTH_LIMITED_BLUR_MAX_RADIUS: i32 = 64;

class DepthLimitedBlurShaderDefinition extends ShaderDefinition {
    constructor() { super("DepthLimitedBlurShader", "three/shaders/post/depth_limited_blur"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        const n = DEPTH_LIMITED_BLUR_MAX_RADIUS + 1;
        const weights = new Float32Array(n * 4);
        weights[0] = 1;
        m.set("sampleUvOffsets", new Uniform<Float32Array>(new Float32Array(n * 4)));
        m.set("sampleWeights", new Uniform<Float32Array>(weights));
        m.set("size", new Uniform<Vector2>(new Vector2(512, 512)));
        m.set("cameraNear", new Uniform<f64>(10));
        m.set("cameraFar", new Uniform<f64>(1000));
        m.set("depthCutoff", new Uniform<f64>(10));
        m.set("kernelRadius", new Uniform<f64>(4));
        m.set("perspective", new Uniform<f64>(1));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("tDepth", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

export const DepthLimitedBlurShader: ShaderDefinition = new DepthLimitedBlurShaderDefinition();

function gaussian(x: f64, stdDev: f64): f64 {
    return Math.exp(-(x * x) / (2.0 * (stdDev * stdDev))) / (Math.sqrt(2.0 * Math.PI) * stdDev);
}

/// three.js's BlurShaderUtils.
export class BlurShaderUtils {
    static createSampleWeights(kernelRadius: i32, stdDev: f64): Array<f64> {
        const weights: Array<f64> = [];
        for (let i = 0; i <= kernelRadius; i++) weights.push(gaussian(<f64>i, stdDev));
        return weights;
    }

    static createSampleOffsets(kernelRadius: i32, uvIncrement: Vector2): Array<Vector2> {
        const offsets: Array<Vector2> = [];
        for (let i = 0; i <= kernelRadius; i++) offsets.push(uvIncrement.clone().multiplyScalar(<f64>i));
        return offsets;
    }

    /// Sets the material's kernelRadius (clamped to 64), sampleUvOffsets
    /// and sampleWeights (three.js sets the KERNEL_RADIUS define).
    static configure(material: ShaderMaterial, kernelRadius: i32, stdDev: f64, uvIncrement: Vector2): void {
        const radius = min<i32>(max<i32>(0, kernelRadius), DEPTH_LIMITED_BLUR_MAX_RADIUS);
        material.uniform<f64>("kernelRadius").value = <f64>radius;
        const offsets = BlurShaderUtils.createSampleOffsets(radius, uvIncrement);
        const weights = BlurShaderUtils.createSampleWeights(radius, stdDev);
        const o = material.uniform<Float32Array>("sampleUvOffsets").value;
        const w = material.uniform<Float32Array>("sampleWeights").value;
        o.fill(0);
        w.fill(0);
        for (let i = 0; i <= radius; i++) {
            o[i * 4] = <f32>offsets[i].x;
            o[i * 4 + 1] = <f32>offsets[i].y;
            w[i * 4] = <f32>weights[i];
        }
    }
}
