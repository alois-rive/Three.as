// three.js examples/jsm/shaders/FilmShader.js (r170), over
// three/shaders/post/film.wgsl. `grayscale` is a number (0 or 1): uniforms
// hold numbers, vectors, colours, matrices and textures.

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

class FilmShaderDefinition extends ShaderDefinition {
    constructor() { super("FilmShader", "three/shaders/post/film"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("time", new Uniform<f64>(0));
        m.set("intensity", new Uniform<f64>(0.5));
        m.set("grayscale", new Uniform<f64>(0));
        return m;
    }
}

export const FilmShader: ShaderDefinition = new FilmShaderDefinition();
