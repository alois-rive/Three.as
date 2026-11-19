// three.js examples/jsm/postprocessing/RenderPass.js: renders a scene into
// the read buffer (linear HDR), for the next passes.

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { Material } from "../../materials/Material";
import { Color } from "../../math/Color";
import { Scene } from "../../scenes/Scene";
import { Pass } from "./Pass";

export class RenderPass extends Pass {
    scene: Object3D;
    camera: Camera;
    overrideMaterial: Material? = null;
    clearColor: Color? = null;
    clearAlpha: f64 = 0;
    clearDepth: bool = false;
    private _oldClearColor: Color = new Color();

    constructor(scene: Object3D, camera: Camera, overrideMaterial: Material? = null, clearColor: Color? = null,
            clearAlpha: f64 = 0) {
        super();
        this.scene = scene;
        this.camera = camera;
        this.overrideMaterial = overrideMaterial;
        this.clearColor = clearColor;
        this.clearAlpha = clearAlpha;
        this.clear = true;
        this.needsSwap = false;
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        const oldAutoClear = renderer.autoClear;
        renderer.autoClear = this.clear;
        let oldOverride: Material? = null;
        const scene = this.scene;
        if (this.overrideMaterial != null && scene instanceof Scene) {
            oldOverride = (scene as Scene).overrideMaterial;
            (scene as Scene).overrideMaterial = this.overrideMaterial;
        }
        let oldAlpha: f64 = 0;
        const cc = this.clearColor;
        if (cc != null) {
            renderer.getClearColor(this._oldClearColor);
            oldAlpha = renderer.getClearAlpha();
            renderer.setClearColor<Color>(cc, this.clearAlpha);
        }
        renderer.setRenderTarget(this.renderToScreen ? null : readBuffer);
        renderer.render(scene, this.camera);
        if (cc != null) renderer.setClearColor<Color>(this._oldClearColor, oldAlpha);
        if (this.overrideMaterial != null && scene instanceof Scene) (scene as Scene).overrideMaterial = oldOverride;
        renderer.autoClear = oldAutoClear;
    }
}
