// three.js examples/jsm/postprocessing/SMAAPass.js: Subpixel Morphological
// Antialiasing (SMAA 1x, medium preset) in three passes: colour edges,
// blending weights (with the area and search lookup textures), then the
// neighbourhood blend. Put it before OutputPass, as three.js's examples.
//
//     composer.addPass(new RenderPass(scene, camera));
//     composer.addPass(new SMAAPass(width * pixelRatio, height * pixelRatio));
//     composer.addPass(new OutputPass());
//
// The area and search textures are three.js's (SMAATextures.as), inflated
// when the pass is made.

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { DataTexture } from "../../textures/DataTexture";
import { Vector2 } from "../../math/Vector2";
import { Color } from "../../math/Color";
import { HalfFloatType } from "../../constants";
import { SMAAEdgesShader, SMAAWeightsShader, SMAABlendShader } from "../shaders/SMAAShader";
import { smaaAreaTexture, smaaSearchTexture } from "./SMAATextures";
import { Pass, FullScreenQuad } from "./Pass";

export class SMAAPass extends Pass {
    edgesRT: RenderTarget;
    weightsRT: RenderTarget;
    areaTexture: DataTexture;
    searchTexture: DataTexture;
    materialEdges: ShaderMaterial;
    materialWeights: ShaderMaterial;
    materialBlend: ShaderMaterial;
    fsQuad: FullScreenQuad = new FullScreenQuad();
    private _oldClearColor: Color = new Color();

    constructor(width: f64, height: f64) {
        super();
        const w = <u32>Math.max(1, width), h = <u32>Math.max(1, height);
        this.edgesRT = new RenderTarget(w, h, { depthBuffer: false, type: HalfFloatType });
        this.edgesRT.texture.name = "SMAAPass.edges";
        this.weightsRT = new RenderTarget(w, h, { depthBuffer: false, type: HalfFloatType });
        this.weightsRT.texture.name = "SMAAPass.weights";

        this.areaTexture = smaaAreaTexture();
        this.areaTexture.name = "SMAAPass.area";
        this.searchTexture = smaaSearchTexture();
        this.searchTexture.name = "SMAAPass.search";

        // Pass 1: edges.
        this.materialEdges = SMAAEdgesShader.createMaterial();
        // Pass 2: weights.
        this.materialWeights = SMAAWeightsShader.createMaterial();
        this.materialWeights.uniform<Texture>("tDiffuse").value = this.edgesRT.texture;
        this.materialWeights.uniform<Texture>("tArea").value = this.areaTexture;
        this.materialWeights.uniform<Texture>("tSearch").value = this.searchTexture;
        // Pass 3: blend.
        this.materialBlend = SMAABlendShader.createMaterial();
        this.materialBlend.uniform<Texture>("tDiffuse").value = this.weightsRT.texture;
        this.setResolution(<f64>w, <f64>h);
    }

    private setResolution(width: f64, height: f64): void {
        const rx = 1 / Math.max(1, width), ry = 1 / Math.max(1, height);
        this.materialEdges.uniform<Vector2>("resolution").value.set(rx, ry);
        this.materialWeights.uniform<Vector2>("resolution").value.set(rx, ry);
        this.materialBlend.uniform<Vector2>("resolution").value.set(rx, ry);
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        const oldAutoClear = renderer.autoClear;
        renderer.getClearColor(this._oldClearColor);
        const oldClearAlpha = renderer.getClearAlpha();
        renderer.autoClear = true;
        // The edge pass discards where there is no edge: start from zero.
        renderer.setClearColor<u32>(0x000000, 0);

        // Pass 1.
        this.materialEdges.uniform<Texture>("tDiffuse").value = readBuffer.texture;
        this.fsQuad.material = this.materialEdges;
        renderer.setRenderTarget(this.edgesRT);
        this.fsQuad.render(renderer);

        // Pass 2.
        this.fsQuad.material = this.materialWeights;
        renderer.setRenderTarget(this.weightsRT);
        this.fsQuad.render(renderer);

        // Pass 3.
        renderer.setClearColor<Color>(this._oldClearColor, oldClearAlpha);
        this.materialBlend.uniform<Texture>("tColor").value = readBuffer.texture;
        this.fsQuad.material = this.materialBlend;
        renderer.setRenderTarget(this.renderToScreen ? null : writeBuffer);
        this.fsQuad.render(renderer);
        renderer.autoClear = oldAutoClear;
    }

    override setSize(width: f64, height: f64): void {
        const w = <u32>Math.max(1, width), h = <u32>Math.max(1, height);
        this.edgesRT.setSize(w, h);
        this.weightsRT.setSize(w, h);
        this.setResolution(<f64>w, <f64>h);
    }

    override dispose(): void {
        this.edgesRT.dispose();
        this.weightsRT.dispose();
        this.areaTexture.dispose();
        this.searchTexture.dispose();
        this.materialEdges.dispose();
        this.materialWeights.dispose();
        this.materialBlend.dispose();
        this.fsQuad.dispose();
    }
}
