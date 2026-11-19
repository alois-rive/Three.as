// three.js examples/jsm/shaders/PoissonDenoiseShader.js, as a
// ShaderDefinition over three/shaders/post/poisson_denoise.wgsl, and
// generatePdSamplePointInitializer. SAMPLES is the `samples` uniform (at
// most 32) and SAMPLE_VECTORS the `poissonDisk` uniform (a Float32Array of
// vec4s, xyz per sample): generatePdSamplePointInitializer returns those
// floats instead of GLSL code. NORMAL_VECTOR_TYPE is `normalVectorType`;
// depth always comes from a DepthTexture (DEPTH_VALUE_SOURCE 0).

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Matrix4 } from "../../math/Matrix4";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

/// The most Poisson disk samples (SAMPLES, here a uniform).
export const PD_MAX_SAMPLES: i32 = 32;

/// three.js's generateDenoiseSamples: `numSamples` points on `numRings`
/// turns of a spiral, xy the direction and z the radius (0 to 1).
export function generateDenoiseSamples(numSamples: i32, numRings: f64, radiusExponent: f64): Array<Vector3> {
    const samples: Array<Vector3> = [];
    for (let i = 0; i < numSamples; i++) {
        const angle = 2 * Math.PI * numRings * <f64>i / <f64>numSamples;
        const radius = Math.pow(<f64>i / <f64>(numSamples - 1), radiusExponent);
        samples.push(new Vector3(Math.cos(angle), Math.sin(angle), radius));
    }
    return samples;
}

/// The `poissonDisk` uniform for `samples` samples (three.js returns the
/// GLSL array initializer for the SAMPLE_VECTORS define).
export function generatePdSamplePointInitializer(samples: i32, rings: f64, radiusExponent: f64): Float32Array {
    const n = min<i32>(samples, PD_MAX_SAMPLES);
    const disk = generateDenoiseSamples(n, rings, radiusExponent);
    const out = new Float32Array(PD_MAX_SAMPLES * 4);
    for (let i = 0; i < n; i++) {
        out[i * 4] = <f32>disk[i].x;
        out[i * 4 + 1] = <f32>disk[i].y;
        out[i * 4 + 2] = <f32>disk[i].z;
    }
    return out;
}

class PoissonDenoiseShaderDefinition extends ShaderDefinition {
    constructor() { super("PoissonDenoiseShader", "three/shaders/post/poisson_denoise"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("cameraProjectionMatrixInverse", new Uniform<Matrix4>(new Matrix4()));
        m.set("poissonDisk", new Uniform<Float32Array>(generatePdSamplePointInitializer(16, 2, 1)));
        m.set("resolution", new Uniform<Vector2>(new Vector2()));
        m.set("lumaPhi", new Uniform<f64>(5));
        m.set("depthPhi", new Uniform<f64>(5));
        m.set("normalPhi", new Uniform<f64>(5));
        m.set("radius", new Uniform<f64>(4));
        m.set("index", new Uniform<f64>(0));
        m.set("samples", new Uniform<f64>(16));
        m.set("normalVectorType", new Uniform<f64>(1));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("tNormal", new Uniform<Texture>(emptyTexture()));
        m.set("tDepth", new Uniform<Texture>(emptyTexture()));
        m.set("tNoise", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

export const PoissonDenoiseShader: ShaderDefinition = new PoissonDenoiseShaderDefinition();
