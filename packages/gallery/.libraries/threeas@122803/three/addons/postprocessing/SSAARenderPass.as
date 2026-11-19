// three.js examples/jsm/postprocessing/SSAARenderPass.js: supersampling.
// Renders the scene 2^sampleLevel times, each with the camera jittered by a
// sub-pixel view offset (camera.setViewOffset), and adds the renders up
// (CopyShader, additive blending) into the write buffer.
//
//     const ssaa = new SSAARenderPass(scene, camera);
//     ssaa.sampleLevel = 2;            // 4 samples
//     composer.addPass(ssaa);          // in place of a RenderPass
//     composer.addPass(new OutputPass());
//
// https://en.wikipedia.org/wiki/Supersampling

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Object3D } from "../../core/Object3D";
import { Camera, CameraView } from "../../cameras/Camera";
import { Color } from "../../math/Color";
import { HalfFloatType, AdditiveBlending } from "../../constants";
import { CopyShader } from "../shaders/PostShaders";
import { Pass, FullScreenQuad } from "./Pass";

export class SSAARenderPass extends Pass {
    scene: Object3D;
    camera: Camera;
    /// 2^sampleLevel samples (0 to 5): 4 is 16 samples.
    sampleLevel: i32 = 4;
    /// Vary the sample weights so their rounding errors cancel out.
    unbiased: bool = true;
    stencilBuffer: bool = false;
    /// The clear colour of each sample render (an sRGB hex) and its alpha.
    clearColor: u32;
    clearAlpha: f64;
    sampleRenderTarget: RenderTarget? = null;
    copyMaterial: ShaderMaterial;
    protected fsQuad: FullScreenQuad;
    protected _oldClearColor: Color = new Color();
    protected viewOffset: CameraView = new CameraView();
    protected originalViewOffset: CameraView = new CameraView();

    constructor(scene: Object3D, camera: Camera, clearColor: u32 = 0x000000, clearAlpha: f64 = 0) {
        super();
        this.scene = scene;
        this.camera = camera;
        this.clearColor = clearColor;
        this.clearAlpha = clearAlpha;
        const m = CopyShader.createMaterial();
        m.transparent = true;
        m.depthTest = false;
        m.depthWrite = false;
        m.blending = AdditiveBlending;
        this.copyMaterial = m;
        this.fsQuad = new FullScreenQuad(m);
    }

    override dispose(): void {
        const s = this.sampleRenderTarget;
        if (s != null) s.dispose();
        this.sampleRenderTarget = null;
        this.copyMaterial.dispose();
        this.fsQuad.dispose();
    }

    override setSize(width: f64, height: f64): void {
        const s = this.sampleRenderTarget;
        if (s != null) s.setSize(<u32>Math.max(1, width), <u32>Math.max(1, height));
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        let sample = this.sampleRenderTarget;
        if (sample == null) {
            sample = new RenderTarget(readBuffer.width, readBuffer.height,
                { type: HalfFloatType });
            sample.texture.name = "SSAARenderPass.sample";
            this.sampleRenderTarget = sample;
        }
        const level = max<i32>(0, min<i32>(this.sampleLevel, 5));
        const jitterOffsets = JitterVectors[level];
        const count = jitterOffsets.length / 2;

        const autoClear = renderer.autoClear;
        renderer.autoClear = false;
        renderer.getClearColor(this._oldClearColor);
        const oldClearAlpha = renderer.getClearAlpha();

        const baseSampleWeight = 1.0 / <f64>count;
        const roundingRange = 1.0 / 32.0;
        this.copyMaterial.uniform<Texture>("tDiffuse").value = sample.texture;

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

        // Render the scene several times, each jittered by a sub-pixel offset,
        // and accumulate the results.
        for (let i = 0; i < count; i++) {
            const jx = <f64>jitterOffsets[i * 2], jy = <f64>jitterOffsets[i * 2 + 1];
            this.camera.setViewOffset(viewOffset.fullWidth, viewOffset.fullHeight,
                viewOffset.offsetX + jx * 0.0625, viewOffset.offsetY + jy * 0.0625,   // 0.0625 = 1 / 16
                viewOffset.width, viewOffset.height);
            let sampleWeight = baseSampleWeight;
            if (this.unbiased) {
                // Weights spread uniformly around the mean, so rounding errors cancel.
                const uniformCenteredDistribution = -0.5 + (<f64>i + 0.5) / <f64>count;
                sampleWeight += roundingRange * uniformCenteredDistribution;
            }
            this.copyMaterial.uniform<f64>("opacity").value = sampleWeight;
            renderer.setClearColor<u32>(this.clearColor, this.clearAlpha);
            renderer.setRenderTarget(sample);
            renderer.clear();
            renderer.render(this.scene, this.camera);

            renderer.setRenderTarget(this.renderToScreen ? null : writeBuffer);
            if (i == 0) {
                renderer.setClearColor<u32>(0x000000, 0.0);
                renderer.clear();
            }
            this.fsQuad.render(renderer);
        }

        if (original.enabled) {
            this.camera.setViewOffset(original.fullWidth, original.fullHeight, original.offsetX, original.offsetY,
                original.width, original.height);
        } else {
            this.camera.clearViewOffset();
        }
        renderer.autoClear = autoClear;
        renderer.setClearColor<Color>(this._oldClearColor, oldClearAlpha);
    }
}

/// The jitter offsets of each sample level (x, y pairs on a [-8, 8)
/// integer grid, scaled by 1 / 16 when used), as three.js's _JitterVectors.
/// Sample patterns: https://msdn.microsoft.com/en-us/library/windows/desktop/ff476218%28v=vs.85%29.aspx
export const JitterVectors: Array<Array<i32>> = [
    [0, 0],
    [4, 4, -4, -4],
    [-2, -6, 6, -2, -6, 2, 2, 6],
    [1, -3, -1, 3, 5, 1, -3, -5, -5, 5, -7, -1, 3, 7, 7, -7],
    [1, 1, -1, -3, -3, 2, 4, -1, -5, -2, 2, 5, 5, 3, 3, -5,
        -2, 6, 0, -7, -4, -6, -6, 4, -8, 0, 7, -4, 6, 7, -7, -8],
    [-4, -7, -7, -5, -3, -5, -5, -4, -1, -4, -2, -2, -6, -1, -4, 0,
        -7, 1, -1, 2, -6, 3, -3, 3, -7, 6, -3, 6, -5, 7, -1, 7,
        5, -7, 1, -6, 6, -5, 4, -4, 2, -3, 7, -2, 1, -1, 4, -1,
        2, 1, 6, 2, 0, 4, 4, 4, 2, 5, 7, 5, 5, 6, 3, 7],
];
