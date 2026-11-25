// three.js examples/jsm/postprocessing/TAARenderPass.js: temporal
// anti-aliasing. While `accumulate` is set (the scene and camera still),
// each frame renders 2^sampleLevel more jittered samples of the 32-sample
// pattern and blends their running sum over the first, unjittered frame;
// after 32 samples the image is fully supersampled. Without `accumulate`
// it renders as an SSAARenderPass (sampleLevel defaults to 0: one sample).
//
//     const taa = new TAARenderPass(scene, camera);
//     composer.addPass(taa);
//     // when the view stops moving:
//     taa.accumulate = true;           // false again as soon as it moves
//
// No motion vectors (three.js has none either): moving scenes smear while
// accumulating.

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { Texture } from "../../textures/Texture";
import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { HalfFloatType, AdditiveBlending } from "../../constants";
import { ShaderMaterial } from "../../materials/ShaderMaterial";
import { CopyShader } from "../shaders/PostShaders";
import { SSAARenderPass, JitterVectors } from "./SSAARenderPass";

export class TAARenderPass extends SSAARenderPass {
    /// Accumulate samples across frames (set it while nothing moves).
    accumulate: bool = false;
    /// Samples accumulated so far (-1: none, restart).
    accumulateIndex: i32 = -1;
    holdRenderTarget: RenderTarget? = null;
    private copySampleMaterial: ShaderMaterial;
    private copyHoldMaterial: ShaderMaterial;

    constructor(scene: Object3D, camera: Camera, clearColor: u32 = 0x000000, clearAlpha: f64 = 0) {
        super(scene, camera, clearColor, clearAlpha);
        this.sampleLevel = 0;
        this.copySampleMaterial = makeTaaCopyMaterial();
        this.copyHoldMaterial = makeTaaCopyMaterial();
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        if (!this.accumulate) {
            this.fsQuad.material = this.copyMaterial;
            super.render(renderer, writeBuffer, readBuffer, deltaTime, maskActive);
            this.accumulateIndex = -1;
            return;
        }
        const jitterOffsets = JitterVectors[5];
        const count = jitterOffsets.length / 2;
        let sample = this.sampleRenderTarget;
        if (sample == null) {
            sample = new RenderTarget(readBuffer.width, readBuffer.height, { type: HalfFloatType });
            sample.texture.name = "TAARenderPass.sample";
            this.sampleRenderTarget = sample;
        }
        let hold = this.holdRenderTarget;
        if (hold == null) {
            hold = new RenderTarget(readBuffer.width, readBuffer.height, { type: HalfFloatType });
            hold.texture.name = "TAARenderPass.hold";
            this.holdRenderTarget = hold;
        }
        if (this.accumulateIndex == -1) {
            // The first frame: an ordinary (SSAA) render, held.
            const toScreen = this.renderToScreen;
            this.renderToScreen = false;
            this.fsQuad.material = this.copyMaterial;
            super.render(renderer, hold, readBuffer, deltaTime, maskActive);
            this.renderToScreen = toScreen;
            this.accumulateIndex = 0;
        }

        const autoClear = renderer.autoClear;
        renderer.autoClear = false;
        renderer.getClearColor(this._oldClearColor);
        const oldClearAlpha = renderer.getClearAlpha();
        const sampleWeight = 1.0 / <f64>count;

        if (this.accumulateIndex >= 0 && this.accumulateIndex < count) {
            const viewOffset = this.viewOffset;
            viewOffset.fullWidth = <f64>readBuffer.width;
            viewOffset.fullHeight = <f64>readBuffer.height;
            viewOffset.offsetX = 0;
            viewOffset.offsetY = 0;
            viewOffset.width = <f64>readBuffer.width;
            viewOffset.height = <f64>readBuffer.height;
            const cv = this.camera.view;
            const original = this.originalViewOffset;
            original.enabled = cv != null && cv.enabled;
            if (original.enabled) {
                original.copy(cv!);
                viewOffset.copy(cv!);
            }

            this.fsQuad.material = this.copyMaterial;
            this.copyMaterial.uniform<f64>("opacity").value = sampleWeight;
            this.copyMaterial.uniform<Texture>("tDiffuse").value = writeBuffer.texture;
            // Several jittered samples a frame, added into the sample target.
            const numSamplesPerFrame = 1 << <u32>max<i32>(0, min<i32>(this.sampleLevel, 5));
            for (let i = 0; i < numSamplesPerFrame; i++) {
                const j = this.accumulateIndex;
                this.camera.setViewOffset(viewOffset.fullWidth, viewOffset.fullHeight,
                    viewOffset.offsetX + <f64>jitterOffsets[j * 2] * 0.0625,
                    viewOffset.offsetY + <f64>jitterOffsets[j * 2 + 1] * 0.0625,   // 0.0625 = 1 / 16
                    viewOffset.width, viewOffset.height);
                renderer.setRenderTarget(writeBuffer);
                renderer.setClearColor<u32>(this.clearColor, this.clearAlpha);
                renderer.clear();
                renderer.render(this.scene, this.camera);

                renderer.setRenderTarget(sample);
                if (this.accumulateIndex == 0) {
                    renderer.setClearColor<u32>(0x000000, 0.0);
                    renderer.clear();
                }
                this.fsQuad.render(renderer);
                this.accumulateIndex++;
                if (this.accumulateIndex >= count) break;
            }
            if (original.enabled) {
                this.camera.setViewOffset(original.fullWidth, original.fullHeight, original.offsetX, original.offsetY,
                    original.width, original.height);
            } else {
                this.camera.clearViewOffset();
            }
        }

        renderer.setClearColor<u32>(this.clearColor, this.clearAlpha);
        const accumulationWeight = <f64>this.accumulateIndex * sampleWeight;
        const out: RenderTarget? = this.renderToScreen ? null : writeBuffer;
        if (accumulationWeight > 0) {
            this.copySampleMaterial.uniform<f64>("opacity").value = 1.0;
            this.copySampleMaterial.uniform<Texture>("tDiffuse").value = sample.texture;
            this.fsQuad.material = this.copySampleMaterial;
            renderer.setRenderTarget(out);
            renderer.clear();
            this.fsQuad.render(renderer);
        }
        if (accumulationWeight < 1.0) {
            this.copyHoldMaterial.uniform<f64>("opacity").value = 1.0 - accumulationWeight;
            this.copyHoldMaterial.uniform<Texture>("tDiffuse").value = hold.texture;
            this.fsQuad.material = this.copyHoldMaterial;
            renderer.setRenderTarget(out);
            this.fsQuad.render(renderer);
        }
        this.fsQuad.material = this.copyMaterial;
        renderer.autoClear = autoClear;
        renderer.setClearColor(this._oldClearColor, oldClearAlpha);
    }

    override setSize(width: f64, height: f64): void {
        super.setSize(width, height);
        const h = this.holdRenderTarget;
        if (h != null) h.setSize(<u32>Math.max(1, width), <u32>Math.max(1, height));
        this.accumulateIndex = -1;
    }

    override dispose(): void {
        super.dispose();
        const h = this.holdRenderTarget;
        if (h != null) h.dispose();
        this.holdRenderTarget = null;
        this.copySampleMaterial.dispose();
        this.copyHoldMaterial.dispose();
    }
}

function makeTaaCopyMaterial(): ShaderMaterial {
    const m = CopyShader.createMaterial();
    m.transparent = true;
    m.depthTest = false;
    m.depthWrite = false;
    m.blending = AdditiveBlending;
    return m;
}
