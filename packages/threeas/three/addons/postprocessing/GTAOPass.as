// three.js examples/jsm/postprocessing/GTAOPass.js: ground truth ambient
// occlusion. A normal and depth prepass (MeshNormalMaterial into a
// HalfFloatType target with a DepthTexture; or a gbuffer of your own, see
// setGBuffer), the GTAO shader, a Poisson denoise, then the output (by
// default the read buffer copied to the write buffer and the denoised
// occlusion multiplied onto it: put a RenderPass first).
//
//     composer.addPass(new RenderPass(scene, camera));
//     const gtao = new GTAOPass(scene, camera, width, height);
//     gtao.updateGtaoMaterial({ radius: 0.5 });
//     composer.addPass(gtao);
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
import { Box3 } from "../../math/Box3";
import {
    HalfFloatType, NearestFilter, NoBlending, MultiplyBlending, DepthStencilFormat, UnsignedInt248Type,
    RepeatWrapping,
} from "../../constants";
import { CopyShader, emptyTexture } from "../shaders/PostShaders";
import { GTAOShader, GTAODepthShader, GTAOBlendShader, generateMagicSquareNoise } from "../shaders/GTAOShader";
import { PoissonDenoiseShader, generatePdSamplePointInitializer } from "../shaders/PoissonDenoiseShader";
import { Pass, FullScreenQuad } from "./Pass";
import {
    cameraNear, cameraFar, isPerspective, hidePointsAndLines, restoreHidden, aoRenderPass, aoRenderOverride,
} from "./AOPassUtils";

/// GTAOPass.OUTPUT: what the pass writes.
export class GTAOPassOutput {
    readonly Off: i32 = -1;
    readonly Default: i32 = 0;
    readonly Diffuse: i32 = 1;
    readonly Depth: i32 = 2;
    readonly Normal: i32 = 3;
    readonly AO: i32 = 4;
    readonly Denoise: i32 = 5;
}

/// GTAOPass's `parameters`: a gbuffer of your own (setGBuffer).
export class GTAOPassParameters {
    depthTexture: DepthTexture? = null;
    normalTexture: Texture? = null;
}

/// updateGtaoMaterial's parameters: NaN (or -1 for samples) leaves a value
/// as it is (three.js: undefined). screenSpaceRadius is always applied.
export class GTAOParameters {
    radius: f64 = NaN;
    distanceExponent: f64 = NaN;
    thickness: f64 = NaN;
    distanceFallOff: f64 = NaN;
    scale: f64 = NaN;
    samples: i32 = -1;
    screenSpaceRadius: bool = false;
}

/// updatePdMaterial's parameters: NaN (or -1 for samples) leaves a value
/// as it is.
export class PoissonDenoiseParameters {
    lumaPhi: f64 = NaN;
    depthPhi: f64 = NaN;
    normalPhi: f64 = NaN;
    radius: f64 = NaN;
    radiusExponent: f64 = NaN;
    rings: f64 = NaN;
    samples: i32 = -1;
}

export class GTAOPass extends Pass {
    static readonly OUTPUT: GTAOPassOutput = new GTAOPassOutput();

    width: f64;
    height: f64;
    camera: Camera;
    scene: Object3D;
    output: i32 = 0;
    blendIntensity: f64 = 1;
    pdRings: f64 = 2;
    pdRadiusExponent: f64 = 2;
    pdSamples: i32 = 16;
    gtaoNoiseTexture: DataTexture;
    pdNoiseTexture: DataTexture;
    gtaoRenderTarget: RenderTarget;
    pdRenderTarget: RenderTarget;
    /// The prepass target (null with a gbuffer of your own).
    normalRenderTarget: RenderTarget? = null;
    depthTexture: DepthTexture;
    normalTexture: Texture? = null;
    gtaoMaterial: ShaderMaterial;
    normalMaterial: MeshNormalMaterial;
    pdMaterial: ShaderMaterial;
    depthRenderMaterial: ShaderMaterial;
    copyMaterial: ShaderMaterial;
    blendMaterial: ShaderMaterial;
    fsQuad: FullScreenQuad;

    private _renderGBuffer: bool = true;
    private _visibilityCache: Array<Object3D> = [];

    constructor(scene: Object3D, camera: Camera, width: f64 = 512, height: f64 = 512,
                parameters: GTAOPassParameters? = null, aoParameters: GTAOParameters? = null,
                pdParameters: PoissonDenoiseParameters? = null) {
        super();
        this.width = width;
        this.height = height;
        this.clear = true;
        this.camera = camera;
        this.scene = scene;

        this.gtaoNoiseTexture = generateMagicSquareNoise();
        this.pdNoiseTexture = this.generateNoise();

        const w = <u32>Math.max(1, width), h = <u32>Math.max(1, height);
        this.gtaoRenderTarget = new RenderTarget(w, h, { type: HalfFloatType });
        this.pdRenderTarget = this.gtaoRenderTarget.clone();

        const gtao = GTAOShader.createMaterial();
        gtao.uniform<f64>("perspective").value = isPerspective(camera);
        gtao.uniform<Texture>("tNoise").value = this.gtaoNoiseTexture;
        gtao.uniform<Vector2>("resolution").value.set(width, height);
        gtao.uniform<f64>("cameraNear").value = cameraNear(camera);
        gtao.uniform<f64>("cameraFar").value = cameraFar(camera);
        this.gtaoMaterial = gtao;

        this.normalMaterial = new MeshNormalMaterial();
        this.normalMaterial.blending = NoBlending;

        const pd = PoissonDenoiseShader.createMaterial();
        pd.uniform<Texture>("tDiffuse").value = this.gtaoRenderTarget.texture;
        pd.uniform<Texture>("tNoise").value = this.pdNoiseTexture;
        pd.uniform<Vector2>("resolution").value.set(width, height);
        pd.uniform<f64>("lumaPhi").value = 10;
        pd.uniform<f64>("depthPhi").value = 2;
        pd.uniform<f64>("normalPhi").value = 3;
        pd.uniform<f64>("radius").value = 8;
        pd.depthTest = false;
        pd.depthWrite = false;
        this.pdMaterial = pd;

        const depth = GTAODepthShader.createMaterial();
        depth.uniform<f64>("cameraNear").value = cameraNear(camera);
        depth.uniform<f64>("cameraFar").value = cameraFar(camera);
        depth.uniform<f64>("perspective").value = isPerspective(camera);
        this.depthRenderMaterial = depth;

        // three.js blends these with DstColor x source: MultiplyBlending.
        this.copyMaterial = CopyShader.createMaterial();
        this.copyMaterial.transparent = true;
        this.blendMaterial = GTAOBlendShader.createMaterial();
        this.blendMaterial.transparent = true;
        this.blendMaterial.blending = MultiplyBlending;

        this.fsQuad = new FullScreenQuad();

        // Placeholder until setGBuffer.
        this.depthTexture = new DepthTexture();
        const p = parameters;
        if (p != null && p.depthTexture != null) this.setGBuffer(p.depthTexture, p.normalTexture);
        else this.setGBuffer(null, null);
        if (aoParameters != null) this.updateGtaoMaterial(aoParameters);
        if (pdParameters != null) this.updatePdMaterial(pdParameters);
    }

    override dispose(): void {
        this.gtaoNoiseTexture.dispose();
        this.pdNoiseTexture.dispose();
        const n = this.normalRenderTarget;
        if (n != null) n.dispose();
        this.gtaoRenderTarget.dispose();
        this.pdRenderTarget.dispose();
        this.normalMaterial.dispose();
        this.pdMaterial.dispose();
        this.copyMaterial.dispose();
        this.depthRenderMaterial.dispose();
        this.gtaoMaterial.dispose();
        this.blendMaterial.dispose();
        this.fsQuad.dispose();
    }

    /// The denoised occlusion.
    get gtaoMap(): Texture { return this.pdRenderTarget.texture; }

    /// Uses your own depth (a DepthTexture) and, optionally, packed view
    /// normals (normal * 0.5 + 0.5, e.g. an attachment of a multiple render
    /// target) instead of the pass's prepass; without normals they are
    /// reconstructed from depth. null, null: the pass's own prepass.
    setGBuffer(depthTexture: DepthTexture?, normalTexture: Texture? = null): void {
        // The prepass target made by an earlier call (and its depth texture)
        // goes (three.js drops it without dispose).
        const previous = this.normalRenderTarget;
        if (previous != null) previous.dispose();
        this.normalRenderTarget = null;
        if (depthTexture != null) {
            this.depthTexture = depthTexture;
            this.normalTexture = normalTexture;
            this._renderGBuffer = false;
        } else {
            this.depthTexture = new DepthTexture(1, 1, UnsignedInt248Type, DepthStencilFormat);
            const o = new RenderTargetOptions();
            o.type = HalfFloatType;
            o.depthTexture = this.depthTexture;
            const rt = new RenderTarget(<u32>Math.max(1, this.width), <u32>Math.max(1, this.height), o);
            rt.texture.minFilter = NearestFilter;
            rt.texture.magFilter = NearestFilter;
            this.normalRenderTarget = rt;
            this.normalTexture = rt.texture;
            this._renderGBuffer = true;
        }
        const normalVectorType: f64 = this.normalTexture != null ? 1 : 0;
        const normal = this.normalTexture != null ? this.normalTexture! : emptyTexture();
        this.gtaoMaterial.uniform<f64>("normalVectorType").value = normalVectorType;
        this.gtaoMaterial.uniform<Texture>("tNormal").value = normal;
        this.gtaoMaterial.uniform<Texture>("tDepth").value = this.depthTexture;
        this.pdMaterial.uniform<f64>("normalVectorType").value = normalVectorType;
        this.pdMaterial.uniform<Texture>("tNormal").value = normal;
        this.pdMaterial.uniform<Texture>("tDepth").value = this.depthTexture;
        this.depthRenderMaterial.uniform<Texture>("tDepth").value = this.depthTexture;
    }

    /// Limits the occlusion to a world box (null: everywhere).
    setSceneClipBox(box: Box3?): void {
        if (box != null) {
            this.gtaoMaterial.uniform<f64>("sceneClipBox").value = 1;
            this.gtaoMaterial.uniform<Vector3>("sceneBoxMin").value.copy(box.min);
            this.gtaoMaterial.uniform<Vector3>("sceneBoxMax").value.copy(box.max);
        } else {
            this.gtaoMaterial.uniform<f64>("sceneClipBox").value = 0;
        }
    }

    updateGtaoMaterial(parameters: GTAOParameters): void {
        const m = this.gtaoMaterial;
        if (!isNaN(parameters.radius)) m.uniform<f64>("radius").value = parameters.radius;
        if (!isNaN(parameters.distanceExponent)) m.uniform<f64>("distanceExponent").value = parameters.distanceExponent;
        if (!isNaN(parameters.thickness)) m.uniform<f64>("thickness").value = parameters.thickness;
        if (!isNaN(parameters.distanceFallOff)) m.uniform<f64>("distanceFallOff").value = parameters.distanceFallOff;
        if (!isNaN(parameters.scale)) m.uniform<f64>("scale").value = parameters.scale;
        if (parameters.samples > 0) m.uniform<f64>("samples").value = <f64>parameters.samples;
        m.uniform<f64>("screenSpaceRadius").value = parameters.screenSpaceRadius ? 1 : 0;
    }

    updatePdMaterial(parameters: PoissonDenoiseParameters): void {
        const m = this.pdMaterial;
        let updateShader = false;
        if (!isNaN(parameters.lumaPhi)) m.uniform<f64>("lumaPhi").value = parameters.lumaPhi;
        if (!isNaN(parameters.depthPhi)) m.uniform<f64>("depthPhi").value = parameters.depthPhi;
        if (!isNaN(parameters.normalPhi)) m.uniform<f64>("normalPhi").value = parameters.normalPhi;
        if (!isNaN(parameters.radius)) m.uniform<f64>("radius").value = parameters.radius;
        if (!isNaN(parameters.radiusExponent) && parameters.radiusExponent != this.pdRadiusExponent) {
            this.pdRadiusExponent = parameters.radiusExponent;
            updateShader = true;
        }
        if (!isNaN(parameters.rings) && parameters.rings != this.pdRings) {
            this.pdRings = parameters.rings;
            updateShader = true;
        }
        if (parameters.samples > 0 && parameters.samples != this.pdSamples) {
            this.pdSamples = parameters.samples;
            updateShader = true;
        }
        if (updateShader) {
            m.uniform<f64>("samples").value = <f64>this.pdSamples;
            m.uniform<Float32Array>("poissonDisk").value =
                generatePdSamplePointInitializer(this.pdSamples, this.pdRings, this.pdRadiusExponent);
        }
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
                    maskActive: bool): void {
        // Normals and depth (meshes only: points and lines do not occlude).
        const nrt = this.normalRenderTarget;
        if (this._renderGBuffer && nrt != null) {
            hidePointsAndLines(this.scene, this._visibilityCache);
            aoRenderOverride(renderer, this.scene, this.camera, this.normalMaterial, nrt, 0x7777ff, 1.0);
            restoreHidden(this._visibilityCache);
        }

        // AO.
        const camera = this.camera;
        const g = this.gtaoMaterial;
        g.uniform<f64>("cameraNear").value = cameraNear(camera);
        g.uniform<f64>("cameraFar").value = cameraFar(camera);
        g.uniform<Matrix4>("cameraProjectionMatrix").value.copy(camera.projectionMatrix);
        g.uniform<Matrix4>("cameraProjectionMatrixInverse").value.copy(camera.projectionMatrixInverse);
        g.uniform<Matrix4>("cameraWorldMatrix").value.copy(camera.matrixWorld);
        aoRenderPass(renderer, this.fsQuad, g, this.gtaoRenderTarget, 0xffffff, 1.0);

        // Poisson denoise.
        this.pdMaterial.uniform<Matrix4>("cameraProjectionMatrixInverse").value.copy(camera.projectionMatrixInverse);
        aoRenderPass(renderer, this.fsQuad, this.pdMaterial, this.pdRenderTarget, 0xffffff, 1.0);

        // Output.
        const target: RenderTarget? = this.renderToScreen ? null : writeBuffer;
        const copy = this.copyMaterial;
        const out = this.output;
        if (out == GTAOPass.OUTPUT.Diffuse) {
            copy.uniform<Texture>("tDiffuse").value = readBuffer.texture;
            copy.blending = NoBlending;
            aoRenderPass(renderer, this.fsQuad, copy, target);
        } else if (out == GTAOPass.OUTPUT.AO) {
            copy.uniform<Texture>("tDiffuse").value = this.gtaoRenderTarget.texture;
            copy.blending = NoBlending;
            aoRenderPass(renderer, this.fsQuad, copy, target);
        } else if (out == GTAOPass.OUTPUT.Denoise) {
            copy.uniform<Texture>("tDiffuse").value = this.pdRenderTarget.texture;
            copy.blending = NoBlending;
            aoRenderPass(renderer, this.fsQuad, copy, target);
        } else if (out == GTAOPass.OUTPUT.Depth) {
            this.depthRenderMaterial.uniform<f64>("cameraNear").value = cameraNear(camera);
            this.depthRenderMaterial.uniform<f64>("cameraFar").value = cameraFar(camera);
            aoRenderPass(renderer, this.fsQuad, this.depthRenderMaterial, target);
        } else if (out == GTAOPass.OUTPUT.Normal) {
            copy.uniform<Texture>("tDiffuse").value = this.normalTexture != null ? this.normalTexture! : emptyTexture();
            copy.blending = NoBlending;
            aoRenderPass(renderer, this.fsQuad, copy, target);
        } else if (out == GTAOPass.OUTPUT.Default) {
            copy.uniform<Texture>("tDiffuse").value = readBuffer.texture;
            copy.blending = NoBlending;
            aoRenderPass(renderer, this.fsQuad, copy, target);
            this.blendMaterial.uniform<f64>("intensity").value = this.blendIntensity;
            this.blendMaterial.uniform<Texture>("tDiffuse").value = this.pdRenderTarget.texture;
            aoRenderPass(renderer, this.fsQuad, this.blendMaterial, target);
        }
    }

    override setSize(width: f64, height: f64): void {
        this.width = width;
        this.height = height;
        const w = <u32>Math.max(1, width), h = <u32>Math.max(1, height);
        this.gtaoRenderTarget.setSize(w, h);
        const n = this.normalRenderTarget;
        if (n != null) n.setSize(w, h);
        this.pdRenderTarget.setSize(w, h);
        this.gtaoMaterial.uniform<Vector2>("resolution").value.set(width, height);
        this.gtaoMaterial.uniform<Matrix4>("cameraProjectionMatrix").value.copy(this.camera.projectionMatrix);
        this.gtaoMaterial.uniform<Matrix4>("cameraProjectionMatrixInverse").value.copy(this.camera.projectionMatrixInverse);
        this.pdMaterial.uniform<Vector2>("resolution").value.set(width, height);
        this.pdMaterial.uniform<Matrix4>("cameraProjectionMatrixInverse").value.copy(this.camera.projectionMatrixInverse);
    }

    overrideVisibility(): void { hidePointsAndLines(this.scene, this._visibilityCache); }
    restoreVisibility(): void { restoreHidden(this._visibilityCache); }

    /// A size x size RGBA8 repeating noise texture for the denoise
    /// rotations (three.js samples SimplexNoise on a grid; these are
    /// uniform random values).
    generateNoise(size: i32 = 64): DataTexture {
        const data = new Uint8Array(size * size * 4);
        for (let i = 0; i < data.length; i++) data[i] = <u8>(Math.random() * 255);
        const t = new DataTexture(data, <u32>size, <u32>size);
        t.wrapS = RepeatWrapping;
        t.wrapT = RepeatWrapping;
        t.needsUpdate = true;
        return t;
    }
}
