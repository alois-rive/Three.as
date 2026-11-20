// three.js examples/jsm/postprocessing/BokehPass.js: depth of field with a
// bokeh blur (BokehShader). The scene's depth comes from a render of it
// (with a MeshDepthMaterial override, as three.js) into a target whose
// DepthTexture the shader reads exactly (three.js reads RGBA-packed depth).
//
//     composer.addPass(new BokehPass(scene, camera, { focus: 6, aperture: 0.005, maxblur: 0.01 }));

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget, RenderTargetOptions } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Material } from "../../materials/Material";
import { MeshDepthMaterial } from "../../materials/MeshDepthMaterial";
import { Texture } from "../../textures/Texture";
import { DepthTexture } from "../../textures/DepthTexture";
import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { Scene } from "../../scenes/Scene";
import { Color } from "../../math/Color";
import { HalfFloatType, NearestFilter, NoBlending } from "../../constants";
import { BokehShader } from "../shaders/BokehShader";
import { Pass, FullScreenQuad } from "./Pass";

/// BokehPass's params (three.js: { focus, aperture, maxblur }).
export class BokehPassParameters {
    /// The distance to the plane in focus, in world units.
    focus: f64 = 1.0;
    /// Bigger: a shallower depth of field.
    aperture: f64 = 0.025;
    /// The largest blur, in uv units.
    maxblur: f64 = 1.0;
}

function nearOf(camera: Camera): f64 {
    if (camera instanceof PerspectiveCamera) return (camera as PerspectiveCamera).near;
    if (camera instanceof OrthographicCamera) return (camera as OrthographicCamera).near;
    return 0.1;
}

function farOf(camera: Camera): f64 {
    if (camera instanceof PerspectiveCamera) return (camera as PerspectiveCamera).far;
    if (camera instanceof OrthographicCamera) return (camera as OrthographicCamera).far;
    return 2000;
}

export class BokehPass extends Pass {
    scene: Object3D;
    camera: Camera;
    renderTargetDepth: RenderTarget;
    materialDepth: MeshDepthMaterial = new MeshDepthMaterial();
    materialBokeh: ShaderMaterial;
    uniforms: Map<string, UniformBase>;
    private fsQuad: FullScreenQuad;
    private _oldClearColor: Color = new Color();

    constructor(scene: Object3D, camera: Camera, params: BokehPassParameters? = null) {
        super();
        this.scene = scene;
        this.camera = camera;
        const p = params != null ? params! : new BokehPassParameters();
        const o = new RenderTargetOptions();
        o.type = HalfFloatType;
        o.depthTexture = new DepthTexture(1, 1);
        this.renderTargetDepth = new RenderTarget(1, 1, o);   // resized by setSize
        this.renderTargetDepth.texture.name = "BokehPass.depth";
        this.renderTargetDepth.texture.minFilter = NearestFilter;
        this.renderTargetDepth.texture.magFilter = NearestFilter;
        this.materialDepth.blending = NoBlending;
        this.materialBokeh = BokehShader.createMaterial();
        this.uniforms = this.materialBokeh.uniforms;
        this.uniform<Texture>("tDepth").value = this.renderTargetDepth.depthTexture!;
        this.uniform<f64>("focus").value = p.focus;
        this.uniform<f64>("aspect").value = camera instanceof PerspectiveCamera ? (camera as PerspectiveCamera).aspect : 1;
        this.uniform<f64>("aperture").value = p.aperture;
        this.uniform<f64>("maxblur").value = p.maxblur;
        this.uniform<f64>("nearClip").value = nearOf(camera);
        this.uniform<f64>("farClip").value = farOf(camera);
        this.uniform<f64>("perspective").value = camera instanceof OrthographicCamera ? 0 : 1;
        this.fsQuad = new FullScreenQuad(this.materialBokeh);
    }

    /// The uniform `name`, typed (three.js: pass.uniforms.name).
    uniform<T>(name: string): Uniform<T> {
        return this.uniforms.get(name) as Uniform<T>;
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        // The depth.
        const scene = this.scene;
        const isScene = scene instanceof Scene;
        let oldOverrideMaterial: Material? = null;
        if (isScene) {
            oldOverrideMaterial = (scene as Scene).overrideMaterial;
            (scene as Scene).overrideMaterial = this.materialDepth;
        }
        renderer.getClearColor(this._oldClearColor);
        const oldClearAlpha = renderer.getClearAlpha();
        const oldAutoClear = renderer.autoClear;
        renderer.autoClear = true;
        renderer.setClearColor<u32>(0xffffff);
        renderer.setClearAlpha(1.0);
        renderer.setRenderTarget(this.renderTargetDepth);
        renderer.render(scene, this.camera);

        // The bokeh composite.
        this.uniform<Texture>("tColor").value = readBuffer.texture;
        this.uniform<f64>("nearClip").value = nearOf(this.camera);
        this.uniform<f64>("farClip").value = farOf(this.camera);
        this.uniform<f64>("perspective").value = this.camera instanceof OrthographicCamera ? 0 : 1;
        renderer.setRenderTarget(this.renderToScreen ? null : writeBuffer);
        this.fsQuad.render(renderer);

        if (isScene) (scene as Scene).overrideMaterial = oldOverrideMaterial;
        renderer.setClearColor<Color>(this._oldClearColor, oldClearAlpha);
        renderer.autoClear = oldAutoClear;
    }

    override setSize(width: f64, height: f64): void {
        this.uniform<f64>("aspect").value = width / Math.max(1, height);
        this.renderTargetDepth.setSize(<u32>Math.max(1, width), <u32>Math.max(1, height));
    }

    override dispose(): void {
        this.renderTargetDepth.dispose();
        this.materialDepth.dispose();
        this.materialBokeh.dispose();
        this.fsQuad.dispose();
    }
}
