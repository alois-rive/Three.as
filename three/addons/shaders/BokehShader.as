// three.js examples/jsm/shaders/BokehShader.js, over
// three/shaders/post/bokeh.wgsl. The defines become data: tDepth is a
// DepthTexture (no RGBA depth packing), and `perspective` (1 or 0) stands
// for PERSPECTIVE_CAMERA.

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

class BokehShaderDefinition extends ShaderDefinition {
    constructor() { super("BokehShader", "three/shaders/post/bokeh"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("tColor", new Uniform<Texture>(emptyTexture()));
        m.set("tDepth", new Uniform<Texture>(emptyTexture()));
        m.set("focus", new Uniform<f64>(1.0));
        m.set("aspect", new Uniform<f64>(1.0));
        m.set("aperture", new Uniform<f64>(0.025));
        m.set("maxblur", new Uniform<f64>(0.01));
        m.set("nearClip", new Uniform<f64>(1.0));
        m.set("farClip", new Uniform<f64>(1000.0));
        m.set("perspective", new Uniform<f64>(1));
        return m;
    }
}

export const BokehShader: ShaderDefinition = new BokehShaderDefinition();
