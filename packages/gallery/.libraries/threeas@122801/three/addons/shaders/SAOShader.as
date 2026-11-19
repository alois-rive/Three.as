// three.js examples/jsm/shaders/SAOShader.js, as a ShaderDefinition over
// three/shaders/post/sao.wgsl. NUM_SAMPLES (7) and NUM_RINGS (4) are WGSL
// constants; DIFFUSE_TEXTURE and PERSPECTIVE_CAMERA are uniforms
// (`diffuseTexture`, `perspective`, 1 or 0).

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Vector2 } from "../../math/Vector2";
import { Matrix4 } from "../../math/Matrix4";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

class SAOShaderDefinition extends ShaderDefinition {
    constructor() { super("SAOShader", "three/shaders/post/sao"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("cameraProjectionMatrix", new Uniform<Matrix4>(new Matrix4()));
        m.set("cameraInverseProjectionMatrix", new Uniform<Matrix4>(new Matrix4()));
        m.set("size", new Uniform<Vector2>(new Vector2(512, 512)));
        m.set("cameraNear", new Uniform<f64>(1));
        m.set("cameraFar", new Uniform<f64>(100));
        m.set("scale", new Uniform<f64>(1));
        m.set("intensity", new Uniform<f64>(0.1));
        m.set("bias", new Uniform<f64>(0.5));
        m.set("minResolution", new Uniform<f64>(0));
        m.set("kernelRadius", new Uniform<f64>(100));
        m.set("randomSeed", new Uniform<f64>(0));
        m.set("perspective", new Uniform<f64>(1));
        m.set("diffuseTexture", new Uniform<f64>(0));
        m.set("tNormal", new Uniform<Texture>(emptyTexture()));
        m.set("tDepth", new Uniform<Texture>(emptyTexture()));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

export const SAOShader: ShaderDefinition = new SAOShaderDefinition();
