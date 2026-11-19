// three.js examples/jsm/postprocessing/GlitchPass.js: random digital
// glitches (DigitalGlitch) every 120 to 240 frames, or every frame with
// `goWild`. Its displacement heightmap is a dt_size x dt_size float
// DataTexture of random values, as three.js. Frames are counted, as in
// three.js (deltaTime is not used).
//
//     composer.addPass(new GlitchPass());

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { DataTexture } from "../../textures/DataTexture";
import { MathUtils } from "../../math/MathUtils";
import { RedFormat, FloatType } from "../../constants";
import { DigitalGlitch } from "../shaders/DigitalGlitch";
import { Pass, FullScreenQuad } from "./Pass";

export class GlitchPass extends Pass {
    material: ShaderMaterial;
    uniforms: Map<string, UniformBase>;
    heightMap: DataTexture;
    goWild: bool = false;
    curF: i32 = 0;
    randX: i32 = 120;
    private fsQuad: FullScreenQuad;

    constructor(dt_size: i32 = 64) {
        super();
        this.material = DigitalGlitch.createMaterial();
        this.uniforms = this.material.uniforms;
        this.heightMap = this.generateHeightmap(dt_size);
        this.uniform<Texture>("tDisp").value = this.heightMap;
        this.fsQuad = new FullScreenQuad(this.material);
        this.generateTrigger();
    }

    /// The uniform `name`, typed (three.js: pass.uniforms.name).
    uniform<T>(name: string): Uniform<T> {
        return this.uniforms.get(name) as Uniform<T>;
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        this.uniform<Texture>("tDiffuse").value = readBuffer.texture;
        this.uniform<f64>("seed").value = Math.random();
        this.uniform<f64>("byp").value = 0;
        if (this.curF % this.randX == 0 || this.goWild) {
            this.uniform<f64>("amount").value = Math.random() / 30;
            this.uniform<f64>("angle").value = MathUtils.randFloat(-Math.PI, Math.PI);
            this.uniform<f64>("seed_x").value = MathUtils.randFloat(-1, 1);
            this.uniform<f64>("seed_y").value = MathUtils.randFloat(-1, 1);
            this.uniform<f64>("distortion_x").value = MathUtils.randFloat(0, 1);
            this.uniform<f64>("distortion_y").value = MathUtils.randFloat(0, 1);
            this.curF = 0;
            this.generateTrigger();
        } else if (<f64>(this.curF % this.randX) < <f64>this.randX / 5) {
            this.uniform<f64>("amount").value = Math.random() / 90;
            this.uniform<f64>("angle").value = MathUtils.randFloat(-Math.PI, Math.PI);
            this.uniform<f64>("distortion_x").value = MathUtils.randFloat(0, 1);
            this.uniform<f64>("distortion_y").value = MathUtils.randFloat(0, 1);
            this.uniform<f64>("seed_x").value = MathUtils.randFloat(-0.3, 0.3);
            this.uniform<f64>("seed_y").value = MathUtils.randFloat(-0.3, 0.3);
        } else if (!this.goWild) {
            this.uniform<f64>("byp").value = 1;
        }
        this.curF++;
        if (this.renderToScreen) {
            renderer.setRenderTarget(null);
            this.fsQuad.render(renderer);
        } else {
            renderer.setRenderTarget(writeBuffer);
            if (this.clear) renderer.clear();
            this.fsQuad.render(renderer);
        }
    }

    generateTrigger(): void {
        this.randX = MathUtils.randInt(120, 240);
    }

    generateHeightmap(dt_size: i32): DataTexture {
        const length = dt_size * dt_size;
        const data = new Float32Array(length);
        for (let i = 0; i < length; i++) data[i] = <f32>MathUtils.randFloat(0, 1);
        const texture = new DataTexture(data, <u32>dt_size, <u32>dt_size, RedFormat, FloatType);
        texture.needsUpdate = true;
        return texture;
    }

    override dispose(): void {
        this.material.dispose();
        this.heightMap.dispose();
        this.fsQuad.dispose();
    }
}
