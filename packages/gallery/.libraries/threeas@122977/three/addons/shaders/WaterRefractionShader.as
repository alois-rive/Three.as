// three.js examples/jsm/shaders/WaterRefractionShader.js (r170), over
// three/shaders/objects/water_refraction.wgsl: a Refractor shader that
// ripples the refraction with a dudv map (`tDudv`, RepeatWrapping) moved by
// `time`.
//
//     const glass = new Refractor(geometry, { color: 0xcbcbcb, shader: WaterRefractionShader });
//     (glass.material as ShaderMaterial).uniform<Texture>("tDudv").value = dudvMap;
//     // each frame:
//     (glass.material as ShaderMaterial).uniform<f64>("time").value += seconds;
//
// Its textures start with tDudv: the shader's one sampler is the first
// texture's, and the dudv map needs to repeat.

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Color } from "../../math/Color";
import { Matrix4 } from "../../math/Matrix4";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

class WaterRefractionShaderDefinition extends ShaderDefinition {
    constructor() { super("WaterRefractionShader", "three/shaders/objects/water_refraction"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("color", new Uniform<Color>(new Color(0x7F7F7F)));
        m.set("time", new Uniform<f64>(0));
        m.set("tDudv", new Uniform<Texture>(emptyTexture()));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("textureMatrix", new Uniform<Matrix4>(new Matrix4()));
        return m;
    }
}

export const WaterRefractionShader: ShaderDefinition = new WaterRefractionShaderDefinition();
