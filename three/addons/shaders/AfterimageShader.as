// three.js examples/jsm/shaders/AfterimageShader.js, over
// three/shaders/post/afterimage.wgsl.

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

class AfterimageShaderDefinition extends ShaderDefinition {
    constructor() { super("AfterimageShader", "three/shaders/post/afterimage"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("damp", new Uniform<f64>(0.96));
        m.set("tOld", new Uniform<Texture>(emptyTexture()));
        m.set("tNew", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

export const AfterimageShader: ShaderDefinition = new AfterimageShaderDefinition();
