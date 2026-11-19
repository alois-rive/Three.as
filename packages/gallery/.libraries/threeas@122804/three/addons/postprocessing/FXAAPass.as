// three.js examples/jsm/postprocessing/FXAAPass.js: a ShaderPass of
// FXAAShader that keeps its resolution uniform in step with the size.

import { Vector2 } from "../../math/Vector2";
import { Uniform } from "../../materials/ShaderMaterial";
import { FXAAShader } from "../shaders/PostShaders";
import { ShaderPass } from "./ShaderPass";

export class FXAAPass extends ShaderPass {
    constructor() {
        super(FXAAShader);
    }

    override setSize(width: f64, height: f64): void {
        (this.uniforms.get("resolution") as Uniform<Vector2>).value.set(1 / Math.max(1, width), 1 / Math.max(1, height));
    }
}
