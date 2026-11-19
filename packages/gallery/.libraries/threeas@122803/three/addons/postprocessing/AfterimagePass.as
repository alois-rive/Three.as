// three.js examples/jsm/postprocessing/AfterimagePass.js: each frame is drawn
// over the previous result faded by `damp` (AfterimageShader), leaving
// trails behind moving objects. The two history targets are HalfFloatType,
// sized by setSize (the composer calls it).
//
//     composer.addPass(new AfterimagePass(0.9));

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget, RenderTargetOptions } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Color } from "../../math/Color";
import { HalfFloatType, NearestFilter } from "../../constants";
import { AfterimageShader } from "../shaders/AfterimageShader";
import { CopyShader } from "../shaders/PostShaders";
import { Pass, FullScreenQuad } from "./Pass";

function historyTarget(): RenderTarget {
    const o = new RenderTargetOptions();
    o.type = HalfFloatType;
    const rt = new RenderTarget(1, 1, o);
    rt.texture.magFilter = NearestFilter;
    return rt;
}

export class AfterimagePass extends Pass {
    uniforms: Map<string, UniformBase>;
    textureComp: RenderTarget = historyTarget();
    textureOld: RenderTarget = historyTarget();
    compFsMaterial: ShaderMaterial;
    copyFsMaterial: ShaderMaterial;
    private compFsQuad: FullScreenQuad;
    private copyFsQuad: FullScreenQuad;
    private historyCleared: i32 = -1;
    private _oldClearColor: Color = new Color();

    constructor(damp: f64 = 0.96) {
        super();
        this.compFsMaterial = AfterimageShader.createMaterial();
        this.uniforms = this.compFsMaterial.uniforms;
        this.uniform<f64>("damp").value = damp;
        this.compFsQuad = new FullScreenQuad(this.compFsMaterial);
        this.copyFsMaterial = CopyShader.createMaterial();
        this.copyFsQuad = new FullScreenQuad(this.copyFsMaterial);
    }

    /// The uniform `name`, typed (three.js: pass.uniforms.name).
    uniform<T>(name: string): Uniform<T> {
        return this.uniforms.get(name) as Uniform<T>;
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        if (this.historyCleared != this.textureOld.version) {
            // A new history starts transparent black (WebGL zero-fills new
            // targets; GPU textures here start undefined).
            renderer.getClearColor(this._oldClearColor);
            const oldAlpha = renderer.getClearAlpha();
            renderer.setClearColor<u32>(0x000000, 0);
            renderer.setRenderTarget(this.textureOld);
            renderer.clear();
            renderer.setClearColor<Color>(this._oldClearColor, oldAlpha);
            this.historyCleared = this.textureOld.version;
        }
        this.uniform<Texture>("tOld").value = this.textureOld.texture;
        this.uniform<Texture>("tNew").value = readBuffer.texture;
        renderer.setRenderTarget(this.textureComp);
        this.compFsQuad.render(renderer);
        (this.copyFsMaterial.uniforms.get("tDiffuse") as Uniform<Texture>).value = this.textureComp.texture;
        if (this.renderToScreen) {
            renderer.setRenderTarget(null);
            this.copyFsQuad.render(renderer);
        } else {
            renderer.setRenderTarget(writeBuffer);
            if (this.clear) renderer.clear();
            this.copyFsQuad.render(renderer);
        }
        // Swap: textureOld holds the latest image for the next frame.
        const temp = this.textureOld;
        this.textureOld = this.textureComp;
        this.textureComp = temp;
    }

    override setSize(width: f64, height: f64): void {
        const w = <u32>Math.max(1, width), h = <u32>Math.max(1, height);
        this.textureComp.setSize(w, h);
        this.textureOld.setSize(w, h);
    }

    override dispose(): void {
        this.textureComp.dispose();
        this.textureOld.dispose();
        this.compFsMaterial.dispose();
        this.copyFsMaterial.dispose();
        this.compFsQuad.dispose();
        this.copyFsQuad.dispose();
    }
}
