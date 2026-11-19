// three.js examples/jsm/shaders/DigitalGlitch.js, over
// three/shaders/post/glitch.wgsl. `byp` is a number (three.js: an int).

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

class DigitalGlitchDefinition extends ShaderDefinition {
    constructor() { super("DigitalGlitch", "three/shaders/post/glitch"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("tDisp", new Uniform<Texture>(emptyTexture()));
        m.set("byp", new Uniform<f64>(0));
        m.set("amount", new Uniform<f64>(0.08));
        m.set("angle", new Uniform<f64>(0.02));
        m.set("seed", new Uniform<f64>(0.02));
        m.set("seed_x", new Uniform<f64>(0.02));
        m.set("seed_y", new Uniform<f64>(0.02));
        m.set("distortion_x", new Uniform<f64>(0.5));
        m.set("distortion_y", new Uniform<f64>(0.6));
        m.set("col_s", new Uniform<f64>(0.05));
        return m;
    }
}

export const DigitalGlitch: ShaderDefinition = new DigitalGlitchDefinition();
