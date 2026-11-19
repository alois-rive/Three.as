// three.js examples/jsm/shaders/HalftoneShader.js: RGB halftone over
// three/shaders/post/halftone.wgsl. Shape: 1 dot, 2 ellipse, 3 line,
// 4 square; blendingMode: 1 linear, 2 multiply, 3 add, 4 lighter, 5 darker.
// `greyscale` and `disable` are numbers here (0 or 1; three.js: bools).

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

class HalftoneShaderDefinition extends ShaderDefinition {
    constructor() { super("HalftoneShader", "three/shaders/post/halftone"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("shape", new Uniform<f64>(1));
        m.set("radius", new Uniform<f64>(4));
        m.set("rotateR", new Uniform<f64>(Math.PI / 12 * 1));
        m.set("rotateG", new Uniform<f64>(Math.PI / 12 * 2));
        m.set("rotateB", new Uniform<f64>(Math.PI / 12 * 3));
        m.set("scatter", new Uniform<f64>(0));
        m.set("width", new Uniform<f64>(1));
        m.set("height", new Uniform<f64>(1));
        m.set("blending", new Uniform<f64>(1));
        m.set("blendingMode", new Uniform<f64>(1));
        m.set("greyscale", new Uniform<f64>(0));
        m.set("disable", new Uniform<f64>(0));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

export const HalftoneShader: ShaderDefinition = new HalftoneShaderDefinition();
