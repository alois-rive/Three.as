// three.js examples/jsm/shaders/SMAAShader.js: the three stages of SMAA 1x
// (v2.8, medium preset, colour edge detection), as ShaderDefinitions over
// three/shaders/post/smaa_edges.wgsl, smaa_weights.wgsl and smaa_blend.wgsl.
// SMAA_THRESHOLD (0.1), SMAA_MAX_SEARCH_STEPS (8) and the area texture
// constants are WGSL constants there (Rive pipelines take no defines).

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Vector2 } from "../../math/Vector2";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

class SMAAEdgesShaderDefinition extends ShaderDefinition {
    constructor() { super("SMAAEdgesShader", "three/shaders/post/smaa_edges"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("resolution", new Uniform<Vector2>(new Vector2(1 / 1024, 1 / 512)));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

class SMAAWeightsShaderDefinition extends ShaderDefinition {
    constructor() { super("SMAAWeightsShader", "three/shaders/post/smaa_weights"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("resolution", new Uniform<Vector2>(new Vector2(1 / 1024, 1 / 512)));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("tArea", new Uniform<Texture>(emptyTexture()));
        m.set("tSearch", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

class SMAABlendShaderDefinition extends ShaderDefinition {
    constructor() { super("SMAABlendShader", "three/shaders/post/smaa_blend"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("resolution", new Uniform<Vector2>(new Vector2(1 / 1024, 1 / 512)));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("tColor", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

export const SMAAEdgesShader: ShaderDefinition = new SMAAEdgesShaderDefinition();
export const SMAAWeightsShader: ShaderDefinition = new SMAAWeightsShaderDefinition();
export const SMAABlendShader: ShaderDefinition = new SMAABlendShaderDefinition();
