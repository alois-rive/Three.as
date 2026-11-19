// three.js examples/jsm/shaders/DotScreenShader.js (after glfx.js), over
// three/shaders/post/dot_screen.wgsl.

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Vector2 } from "../../math/Vector2";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

class DotScreenShaderDefinition extends ShaderDefinition {
    constructor() { super("DotScreenShader", "three/shaders/post/dot_screen"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("tSize", new Uniform<Vector2>(new Vector2(256, 256)));
        m.set("center", new Uniform<Vector2>(new Vector2(0.5, 0.5)));
        m.set("angle", new Uniform<f64>(1.57));
        m.set("scale", new Uniform<f64>(1.0));
        return m;
    }
}

export const DotScreenShader: ShaderDefinition = new DotScreenShaderDefinition();
