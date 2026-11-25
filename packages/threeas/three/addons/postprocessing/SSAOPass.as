// three.js examples/jsm/postprocessing/SSAOPass.js: screen space ambient
// occlusion. A normal and depth prepass (MeshNormalMaterial into a
// HalfFloatType target with a DepthTexture), the SSAO shader over a
// hemisphere kernel, a 5 x 5 blur, then the output (by default the blurred
// occlusion multiplied onto the read buffer: put a RenderPass first).
//
//     composer.addPass(new RenderPass(scene, camera));
//     const ssao = new SSAOPass(scene, camera, width, height);
//     ssao.kernelRadius = 0.5;
//     composer.addPass(ssao);
//     composer.addPass(new OutputPass());

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget, RenderTargetOptions } from "../../renderers/RenderTarget";
import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { ShaderMaterial } from "../../materials/ShaderMaterial";
import { MeshNormalMaterial } from "../../materials/MeshNormalMaterial";
import { Texture } from "../../textures/Texture";
import { DataTexture } from "../../textures/DataTexture";
import { DepthTexture } from "../../textures/DepthTexture";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Matrix4 } from "../../math/Matrix4";
import { MathUtils } from "../../math/MathUtils";
import {
    HalfFloatType, FloatType, RGBAFormat, NearestFilter, RepeatWrapping, NoBlending, MultiplyBlending,
    DepthStencilFormat, UnsignedInt248Type,
} from "../../constants";
import { CopyShader } from "../shaders/PostShaders";
import { SSAOShader, SSAODepthShader, SSAOBlurShader, SSAO_MAX_KERNEL_SIZE } from "../shaders/SSAOShader";
import { Pass, FullScreenQuad } from "./Pass";
import {
    cameraNear, cameraFar, isPerspective, hidePointsAndLines, restoreHidden, aoRenderPass, aoRenderOverride,
} from "./AOPassUtils";

/// SSAOPass.OUTPUT: what the pass writes.
export class SSAOPassOutput {
    readonly Default: i32 = 0;
    readonly SSAO: i32 = 1;
    readonly Blur: i32 = 2;
    readonly Depth: i32 = 3;
    readonly Normal: i32 = 4;
}

export class SSAOPass extends Pass {
    static readonly OUTPUT: SSAOPassOutput = new SSAOPassOutput();

    width: f64;
    height: f64;
    camera: Camera;
    scene: Object3D;
    kernelRadius: f64 = 8;
    /// The hemisphere samples (three.js's kernel), at most 32.
    kernel: Array<Vector3> = [];
    noiseTexture: DataTexture;
    output: i32 = 0;
    minDistance: f64 = 0.005;
    maxDistance: f64 = 0.1;

    normalRenderTarget: RenderTarget;
    ssaoRenderTarget: RenderTarget;
    blurRenderTarget: RenderTarget;
    ssaoMaterial: ShaderMaterial;
    normalMaterial: MeshNormalMaterial;
    blurMaterial: ShaderMaterial;
    depthRenderMaterial: ShaderMaterial;
    copyMaterial: ShaderMaterial;
    private screenCopyMaterial: ShaderMaterial;
    fsQuad: FullScreenQuad;

    private _visibilityCache: Array<Object3D> = [];
    private _kernelDirty: bool = true;
    private _writtenKernelSize: i32 = -1;

    constructor(scene: Object3D, camera: Camera, width: f64 = 512, height: f64 = 512, kernelSize: i32 = 32) {
        super();
        this.width = width;
        this.height = height;
        this.clear = true;
        this.needsSwap = false;
        this.camera = camera;
        this.scene = scene;

        this.generateSampleKernel(kernelSize);
        this.noiseTexture = this.generateRandomKernelRotations();

        // The normal render target, with a depth texture.
        const depthTexture = new DepthTexture(1, 1, UnsignedInt248Type, DepthStencilFormat);
        const o = new RenderTargetOptions();
        o.type = HalfFloatType;
        o.depthTexture = depthTexture;
        this.normalRenderTarget = new RenderTarget(<u32>width, <u32>height, o);
        this.normalRenderTarget.texture.minFilter = NearestFilter;
        this.normalRenderTarget.texture.magFilter = NearestFilter;
        this.ssaoRenderTarget = new RenderTarget(<u32>width, <u32>height, { type: HalfFloatType });
        this.blurRenderTarget = this.ssaoRenderTarget.clone();

        // The SSAO material.
        const ssao = SSAOShader.createMaterial();
        ssao.uniform<f64>("kernelSize").value = <f64>this.kernel.length;
        ssao.uniform<Texture>("tNormal").value = this.normalRenderTarget.texture;
        ssao.uniform<Texture>("tDepth").value = depthTexture;
        ssao.uniform<Texture>("tNoise").value = this.noiseTexture;
        ssao.uniform<f64>("cameraNear").value = cameraNear(camera);
        ssao.uniform<f64>("cameraFar").value = cameraFar(camera);
        ssao.uniform<f64>("perspective").value = isPerspective(camera);
        ssao.uniform<Vector2>("resolution").value.set(width, height);
        ssao.uniform<Matrix4>("cameraProjectionMatrix").value.copy(camera.projectionMatrix);
        ssao.uniform<Matrix4>("cameraInverseProjectionMatrix").value.copy(camera.projectionMatrixInverse);
        this.ssaoMaterial = ssao;
        this.writeKernel();

        this.normalMaterial = new MeshNormalMaterial();
        this.normalMaterial.blending = NoBlending;

        const blur = SSAOBlurShader.createMaterial();
        blur.uniform<Texture>("tDiffuse").value = this.ssaoRenderTarget.texture;
        blur.uniform<Vector2>("resolution").value.set(width, height);
        this.blurMaterial = blur;

        const depth = SSAODepthShader.createMaterial();
        depth.uniform<Texture>("tDepth").value = depthTexture;
        depth.uniform<f64>("cameraNear").value = cameraNear(camera);
        depth.uniform<f64>("cameraFar").value = cameraFar(camera);
        depth.uniform<f64>("perspective").value = isPerspective(camera);
        this.depthRenderMaterial = depth;

        // three.js blends the copy with DstColor x source: MultiplyBlending.
        this.copyMaterial = CopyShader.createMaterial();
        this.copyMaterial.transparent = true;
        this.screenCopyMaterial = CopyShader.createMaterial();
        this.screenCopyMaterial.transparent = true;
        this.screenCopyMaterial.blending = NoBlending;
        this.fsQuad = new FullScreenQuad();
    }

    override dispose(): void {
        this.normalRenderTarget.dispose();
        this.ssaoRenderTarget.dispose();
        this.blurRenderTarget.dispose();
        this.normalMaterial.dispose();
        this.blurMaterial.dispose();
        this.copyMaterial.dispose();
        this.screenCopyMaterial.dispose();
        this.depthRenderMaterial.dispose();
        this.ssaoMaterial.dispose();
        this.noiseTexture.dispose();
        this.fsQuad.dispose();
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
                    maskActive: bool): void {
        // Normals and depth (meshes only: points and lines do not occlude).
        this.overrideVisibility();
        aoRenderOverride(renderer, this.scene, this.camera, this.normalMaterial, this.normalRenderTarget, 0x7777ff, 1.0);
        this.restoreVisibility();

        // SSAO (the kernel and the camera's projection as they are now).
        if (this._kernelDirty || this.kernel.length != this._writtenKernelSize) this.writeKernel();
        const perspective = isPerspective(this.camera);
        const m = this.ssaoMaterial;
        m.uniform<f64>("kernelRadius").value = this.kernelRadius;
        m.uniform<f64>("minDistance").value = this.minDistance;
        m.uniform<f64>("maxDistance").value = this.maxDistance;
        m.uniform<f64>("perspective").value = perspective;
        m.uniform<f64>("cameraNear").value = cameraNear(this.camera);
        m.uniform<f64>("cameraFar").value = cameraFar(this.camera);
        m.uniform<Matrix4>("cameraProjectionMatrix").value.copy(this.camera.projectionMatrix);
        m.uniform<Matrix4>("cameraInverseProjectionMatrix").value.copy(this.camera.projectionMatrixInverse);
        aoRenderPass(renderer, this.fsQuad, m, this.ssaoRenderTarget);

        // Blur.
        aoRenderPass(renderer, this.fsQuad, this.blurMaterial, this.blurRenderTarget);

        // Output.
        const target: RenderTarget? = this.renderToScreen ? null : readBuffer;
        const copy = this.copyMaterial;
        const out = this.output;
        if (out == SSAOPass.OUTPUT.SSAO) {
            copy.uniform<Texture>("tDiffuse").value = this.ssaoRenderTarget.texture;
            copy.blending = NoBlending;
            aoRenderPass(renderer, this.fsQuad, copy, target);
        } else if (out == SSAOPass.OUTPUT.Blur) {
            copy.uniform<Texture>("tDiffuse").value = this.blurRenderTarget.texture;
            copy.blending = NoBlending;
            aoRenderPass(renderer, this.fsQuad, copy, target);
        } else if (out == SSAOPass.OUTPUT.Depth) {
            this.depthRenderMaterial.uniform<f64>("perspective").value = perspective;
            this.depthRenderMaterial.uniform<f64>("cameraNear").value = cameraNear(this.camera);
            this.depthRenderMaterial.uniform<f64>("cameraFar").value = cameraFar(this.camera);
            aoRenderPass(renderer, this.fsQuad, this.depthRenderMaterial, target);
        } else if (out == SSAOPass.OUTPUT.Normal) {
            copy.uniform<Texture>("tDiffuse").value = this.normalRenderTarget.texture;
            copy.blending = NoBlending;
            aoRenderPass(renderer, this.fsQuad, copy, target);
        } else if (out == SSAOPass.OUTPUT.Default) {
            if (this.renderToScreen) {
                this.screenCopyMaterial.uniform<Texture>("tDiffuse").value = readBuffer.texture;
                aoRenderPass(renderer, this.fsQuad, this.screenCopyMaterial, null);
            }
            copy.uniform<Texture>("tDiffuse").value = this.blurRenderTarget.texture;
            copy.blending = MultiplyBlending;
            aoRenderPass(renderer, this.fsQuad, copy, target);
        }
    }

    override setSize(width: f64, height: f64): void {
        this.width = width;
        this.height = height;
        const w = <u32>Math.max(1, width), h = <u32>Math.max(1, height);
        this.ssaoRenderTarget.setSize(w, h);
        this.normalRenderTarget.setSize(w, h);
        this.blurRenderTarget.setSize(w, h);
        this.ssaoMaterial.uniform<Vector2>("resolution").value.set(width, height);
        this.ssaoMaterial.uniform<Matrix4>("cameraProjectionMatrix").value.copy(this.camera.projectionMatrix);
        this.ssaoMaterial.uniform<Matrix4>("cameraInverseProjectionMatrix").value.copy(this.camera.projectionMatrixInverse);
        this.blurMaterial.uniform<Vector2>("resolution").value.set(width, height);
    }

    /// Fills `kernel` with `kernelSize` (at most 32) samples in the +z
    /// hemisphere, denser near the centre.
    generateSampleKernel(kernelSize: i32): void {
        const kernel = this.kernel;
        kernel.length = 0;
        const n = min<i32>(kernelSize, SSAO_MAX_KERNEL_SIZE);
        for (let i = 0; i < n; i++) {
            const sample = new Vector3();
            sample.x = Math.random() * 2 - 1;
            sample.y = Math.random() * 2 - 1;
            sample.z = Math.random();
            sample.normalize();
            let scale = <f64>i / <f64>n;
            scale = MathUtils.lerp(0.1, 1, scale * scale);
            sample.multiplyScalar(scale);
            kernel.push(sample);
        }
        this._kernelDirty = true;
    }

    /// A 4 x 4 repeating texture of random rotations (three.js samples
    /// SimplexNoise at random points; this takes random 2D vectors in XY).
    generateRandomKernelRotations(): DataTexture {
        const width = 4, height = 4;
        const size = width * height;
        const data = new Float32Array(size * 4);
        for (let i = 0; i < size; i++) {
            const j = i * 4;
            data[j] = <f32>(Math.random() * 2 - 1);
            data[j + 1] = <f32>(Math.random() * 2 - 1);
            data[j + 2] = 0;
            data[j + 3] = 1;
        }
        const t = new DataTexture(data, <u32>width, <u32>height, RGBAFormat, FloatType);
        t.wrapS = RepeatWrapping;
        t.wrapT = RepeatWrapping;
        t.needsUpdate = true;
        return t;
    }

    overrideVisibility(): void { hidePointsAndLines(this.scene, this._visibilityCache); }
    restoreVisibility(): void { restoreHidden(this._visibilityCache); }

    // The kernel into the shader's vec4 array.
    private writeKernel(): void {
        const a = this.ssaoMaterial.uniform<Float32Array>("kernel").value;
        a.fill(0);
        const count = min<i32>(this.kernel.length, SSAO_MAX_KERNEL_SIZE);
        for (let i = 0; i < count; i++) {
            const k = this.kernel[i];
            a[i * 4] = <f32>k.x;
            a[i * 4 + 1] = <f32>k.y;
            a[i * 4 + 2] = <f32>k.z;
        }
        this.ssaoMaterial.uniform<f64>("kernelSize").value = <f64>count;
        this._kernelDirty = false;
        this._writtenKernelSize = this.kernel.length;
    }
}
