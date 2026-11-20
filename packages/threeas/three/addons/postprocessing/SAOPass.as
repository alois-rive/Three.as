// three.js examples/jsm/postprocessing/SAOPass.js: scalable ambient
// obscurance. A normal and depth prepass (MeshNormalMaterial into a
// HalfFloatType target with a DepthTexture), the SAO shader, a depth
// limited separable blur, then the output (by default the obscurance
// multiplied onto the read buffer: put a RenderPass first).
//
//     composer.addPass(new RenderPass(scene, camera));
//     const sao = new SAOPass(scene, camera, new Vector2(width, height));
//     sao.params.saoKernelRadius = 16;
//     composer.addPass(sao);
//     composer.addPass(new OutputPass());

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget, RenderTargetOptions } from "../../renderers/RenderTarget";
import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { ShaderMaterial } from "../../materials/ShaderMaterial";
import { MeshNormalMaterial } from "../../materials/MeshNormalMaterial";
import { Texture } from "../../textures/Texture";
import { DepthTexture } from "../../textures/DepthTexture";
import { Vector2 } from "../../math/Vector2";
import { Matrix4 } from "../../math/Matrix4";
import { Color } from "../../math/Color";
import {
    HalfFloatType, NearestFilter, NoBlending, MultiplyBlending, DepthStencilFormat, UnsignedInt248Type,
} from "../../constants";
import { CopyShader } from "../shaders/PostShaders";
import { SAOShader } from "../shaders/SAOShader";
import { DepthLimitedBlurShader, BlurShaderUtils } from "../shaders/DepthLimitedBlurShader";
import { Pass, FullScreenQuad } from "./Pass";
import { cameraNear, cameraFar, isPerspective, aoRenderPass, aoRenderOverride } from "./AOPassUtils";

/// SAOPass.OUTPUT: what the pass writes.
export class SAOPassOutput {
    readonly Default: i32 = 0;
    readonly SAO: i32 = 1;
    readonly Normal: i32 = 2;
}

/// SAOPass.params (three.js's params object).
export class SAOPassParams {
    output: i32 = 0;
    saoBias: f64 = 0.5;
    saoIntensity: f64 = 0.18;
    saoScale: f64 = 1;
    saoKernelRadius: f64 = 100;
    saoMinResolution: f64 = 0;
    saoBlur: bool = true;
    /// At most 64 here.
    saoBlurRadius: f64 = 8;
    saoBlurStdDev: f64 = 4;
    saoBlurDepthCutoff: f64 = 0.01;
}

export class SAOPass extends Pass {
    static readonly OUTPUT: SAOPassOutput = new SAOPassOutput();

    scene: Object3D;
    camera: Camera;
    params: SAOPassParams = new SAOPassParams();
    resolution: Vector2;
    saoRenderTarget: RenderTarget;
    blurIntermediateRenderTarget: RenderTarget;
    normalRenderTarget: RenderTarget;
    normalMaterial: MeshNormalMaterial;
    saoMaterial: ShaderMaterial;
    vBlurMaterial: ShaderMaterial;
    hBlurMaterial: ShaderMaterial;
    materialCopy: ShaderMaterial;
    fsQuad: FullScreenQuad;

    private _oldClearColor: Color = new Color();
    private oldClearAlpha: f64 = 1;
    private prevStdDev: f64 = NaN;
    private prevNumSamples: f64 = NaN;

    constructor(scene: Object3D, camera: Camera, resolution: Vector2 = new Vector2(256, 256)) {
        super();
        this.scene = scene;
        this.camera = camera;
        this.clear = true;
        this.needsSwap = false;
        this.resolution = new Vector2(resolution.x, resolution.y);
        const w = <u32>Math.max(1, resolution.x), h = <u32>Math.max(1, resolution.y);

        this.saoRenderTarget = new RenderTarget(w, h, { type: HalfFloatType });
        this.blurIntermediateRenderTarget = this.saoRenderTarget.clone();

        const depthTexture = new DepthTexture(1, 1, UnsignedInt248Type, DepthStencilFormat);
        const o = new RenderTargetOptions();
        o.type = HalfFloatType;
        o.depthTexture = depthTexture;
        this.normalRenderTarget = new RenderTarget(w, h, o);
        this.normalRenderTarget.texture.minFilter = NearestFilter;
        this.normalRenderTarget.texture.magFilter = NearestFilter;

        this.normalMaterial = new MeshNormalMaterial();
        this.normalMaterial.blending = NoBlending;

        const perspective = isPerspective(camera);
        const sao = SAOShader.createMaterial();
        sao.uniform<f64>("perspective").value = perspective;
        sao.uniform<Texture>("tDepth").value = depthTexture;
        sao.uniform<Texture>("tNormal").value = this.normalRenderTarget.texture;
        sao.uniform<Vector2>("size").value.set(resolution.x, resolution.y);
        sao.uniform<Matrix4>("cameraInverseProjectionMatrix").value.copy(camera.projectionMatrixInverse);
        sao.uniform<Matrix4>("cameraProjectionMatrix").value.copy(camera.projectionMatrix);
        sao.blending = NoBlending;
        this.saoMaterial = sao;

        this.vBlurMaterial = this.blurMaterial(this.saoRenderTarget.texture, depthTexture, perspective, resolution);
        this.hBlurMaterial = this.blurMaterial(this.blurIntermediateRenderTarget.texture, depthTexture, perspective,
            resolution);

        // three.js blends the copy with DstColor x source: MultiplyBlending.
        this.materialCopy = CopyShader.createMaterial();
        this.materialCopy.transparent = true;
        this.materialCopy.depthTest = false;
        this.materialCopy.depthWrite = false;
        this.materialCopy.blending = MultiplyBlending;
        this.fsQuad = new FullScreenQuad();
    }

    private blurMaterial(diffuse: Texture, depth: Texture, perspective: f64, resolution: Vector2): ShaderMaterial {
        const m = DepthLimitedBlurShader.createMaterial();
        m.uniform<f64>("perspective").value = perspective;
        m.uniform<Texture>("tDiffuse").value = diffuse;
        m.uniform<Texture>("tDepth").value = depth;
        m.uniform<Vector2>("size").value.set(resolution.x, resolution.y);
        m.blending = NoBlending;
        return m;
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
                    maskActive: bool): void {
        // The read buffer first when rendering to the screen.
        if (this.renderToScreen) {
            this.materialCopy.blending = NoBlending;
            this.materialCopy.uniform<Texture>("tDiffuse").value = readBuffer.texture;
            aoRenderPass(renderer, this.fsQuad, this.materialCopy, null);
        }
        renderer.getClearColor(this._oldClearColor);
        this.oldClearAlpha = renderer.getClearAlpha();
        const oldAutoClear = renderer.autoClear;
        renderer.autoClear = false;

        const p = this.params;
        const near = cameraNear(this.camera), far = cameraFar(this.camera);
        const perspective = isPerspective(this.camera);
        const sao = this.saoMaterial;
        sao.uniform<f64>("bias").value = p.saoBias;
        sao.uniform<f64>("intensity").value = p.saoIntensity;
        sao.uniform<f64>("scale").value = p.saoScale;
        sao.uniform<f64>("kernelRadius").value = p.saoKernelRadius;
        sao.uniform<f64>("minResolution").value = p.saoMinResolution;
        sao.uniform<f64>("perspective").value = perspective;
        sao.uniform<f64>("cameraNear").value = near;
        sao.uniform<f64>("cameraFar").value = far;
        // The projection as it is now (three.js copies it on setSize).
        sao.uniform<Matrix4>("cameraProjectionMatrix").value.copy(this.camera.projectionMatrix);
        sao.uniform<Matrix4>("cameraInverseProjectionMatrix").value.copy(this.camera.projectionMatrixInverse);

        const depthCutoff = p.saoBlurDepthCutoff * (far - near);
        const blurs: StaticArray<ShaderMaterial> = [this.vBlurMaterial, this.hBlurMaterial];
        for (let i = 0; i < 2; i++) {
            blurs[i].uniform<f64>("perspective").value = perspective;
            blurs[i].uniform<f64>("depthCutoff").value = depthCutoff;
            blurs[i].uniform<f64>("cameraNear").value = near;
            blurs[i].uniform<f64>("cameraFar").value = far;
        }
        p.saoBlurRadius = Math.floor(p.saoBlurRadius);
        if (this.prevStdDev != p.saoBlurStdDev || this.prevNumSamples != p.saoBlurRadius) {
            BlurShaderUtils.configure(this.vBlurMaterial, <i32>p.saoBlurRadius, p.saoBlurStdDev, new Vector2(0, 1));
            BlurShaderUtils.configure(this.hBlurMaterial, <i32>p.saoBlurRadius, p.saoBlurStdDev, new Vector2(1, 0));
            this.prevStdDev = p.saoBlurStdDev;
            this.prevNumSamples = p.saoBlurRadius;
        }

        // Normals and depth.
        aoRenderOverride(renderer, this.scene, this.camera, this.normalMaterial, this.normalRenderTarget, 0x7777ff, 1.0);
        // SAO.
        aoRenderPass(renderer, this.fsQuad, sao, this.saoRenderTarget, 0xffffff, 1.0);
        // Blur.
        if (p.saoBlur) {
            aoRenderPass(renderer, this.fsQuad, this.vBlurMaterial, this.blurIntermediateRenderTarget, 0xffffff, 1.0);
            aoRenderPass(renderer, this.fsQuad, this.hBlurMaterial, this.saoRenderTarget, 0xffffff, 1.0);
        }
        // Output.
        const copy = this.materialCopy;
        copy.uniform<Texture>("tDiffuse").value = p.output == SAOPass.OUTPUT.Normal
            ? this.normalRenderTarget.texture : this.saoRenderTarget.texture;
        copy.blending = p.output == SAOPass.OUTPUT.Default ? MultiplyBlending : NoBlending;
        aoRenderPass(renderer, this.fsQuad, copy, this.renderToScreen ? null : readBuffer);

        renderer.setClearColor<Color>(this._oldClearColor, this.oldClearAlpha);
        renderer.autoClear = oldAutoClear;
    }

    override setSize(width: f64, height: f64): void {
        const w = <u32>Math.max(1, width), h = <u32>Math.max(1, height);
        this.saoRenderTarget.setSize(w, h);
        this.blurIntermediateRenderTarget.setSize(w, h);
        this.normalRenderTarget.setSize(w, h);
        this.resolution.set(width, height);
        this.saoMaterial.uniform<Vector2>("size").value.set(width, height);
        this.saoMaterial.uniform<Matrix4>("cameraInverseProjectionMatrix").value.copy(this.camera.projectionMatrixInverse);
        this.saoMaterial.uniform<Matrix4>("cameraProjectionMatrix").value.copy(this.camera.projectionMatrix);
        this.vBlurMaterial.uniform<Vector2>("size").value.set(width, height);
        this.hBlurMaterial.uniform<Vector2>("size").value.set(width, height);
    }

    override dispose(): void {
        this.saoRenderTarget.dispose();
        this.blurIntermediateRenderTarget.dispose();
        this.normalRenderTarget.dispose();
        this.normalMaterial.dispose();
        this.saoMaterial.dispose();
        this.vBlurMaterial.dispose();
        this.hBlurMaterial.dispose();
        this.materialCopy.dispose();
        this.fsQuad.dispose();
    }
}
