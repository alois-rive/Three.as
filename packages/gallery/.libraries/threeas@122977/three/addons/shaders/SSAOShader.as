// three.js examples/jsm/shaders/SSAOShader.js: SSAOShader, SSAODepthShader
// and SSAOBlurShader, as ShaderDefinitions over three/shaders/post/ssao*.wgsl.
// three.js's defines are uniforms: KERNEL_SIZE is `kernelSize` (at most
// 32), PERSPECTIVE_CAMERA `perspective` (1 or 0). `kernel` is a Float32Array
// of vec4s (xyz per sample).

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Vector2 } from "../../math/Vector2";
import { Matrix4 } from "../../math/Matrix4";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

/// The largest SSAO kernel (three.js's KERNEL_SIZE define, here a uniform).
export const SSAO_MAX_KERNEL_SIZE: i32 = 32;

class SSAOShaderDefinition extends ShaderDefinition {
    constructor() { super("SSAOShader", "three/shaders/post/ssao"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("cameraProjectionMatrix", new Uniform<Matrix4>(new Matrix4()));
        m.set("cameraInverseProjectionMatrix", new Uniform<Matrix4>(new Matrix4()));
        m.set("kernel", new Uniform<Float32Array>(new Float32Array(SSAO_MAX_KERNEL_SIZE * 4)));
        m.set("resolution", new Uniform<Vector2>(new Vector2()));
        m.set("cameraNear", new Uniform<f64>(0.1));
        m.set("cameraFar", new Uniform<f64>(2000));
        m.set("kernelRadius", new Uniform<f64>(8));
        m.set("minDistance", new Uniform<f64>(0.005));
        m.set("maxDistance", new Uniform<f64>(0.05));
        m.set("kernelSize", new Uniform<f64>(32));
        m.set("perspective", new Uniform<f64>(1));
        m.set("tNormal", new Uniform<Texture>(emptyTexture()));
        m.set("tDepth", new Uniform<Texture>(emptyTexture()));
        m.set("tNoise", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

class SSAODepthShaderDefinition extends ShaderDefinition {
    constructor() { super("SSAODepthShader", "three/shaders/post/ssao_depth"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("cameraNear", new Uniform<f64>(0.1));
        m.set("cameraFar", new Uniform<f64>(2000));
        m.set("perspective", new Uniform<f64>(1));
        // Pairs with the group's sampler (a depth texture is read with
        // textureLoad); not in three.js.
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("tDepth", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

class SSAOBlurShaderDefinition extends ShaderDefinition {
    constructor() { super("SSAOBlurShader", "three/shaders/post/ssao_blur"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("resolution", new Uniform<Vector2>(new Vector2()));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

export const SSAOShader: ShaderDefinition = new SSAOShaderDefinition();
export const SSAODepthShader: ShaderDefinition = new SSAODepthShaderDefinition();
export const SSAOBlurShader: ShaderDefinition = new SSAOBlurShaderDefinition();
