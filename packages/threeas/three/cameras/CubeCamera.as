// three.js CubeCamera: six 90-degree cameras rendering the scene around
// its position into a WebGLCubeRenderTarget, e.g. for dynamic
// reflections: `material.envMap = cubeRenderTarget.texture`, then
// `cubeCamera.update(renderer, scene)` each frame (hide the reflecting
// object first, as three.js examples do).

import { Object3D } from "../core/Object3D";
import { PerspectiveCamera } from "./PerspectiveCamera";
import { WebGLCubeRenderTarget } from "../renderers/WebGLCubeRenderTarget";
import { GPURenderer } from "../renderers/GPURenderer";
import { RenderTarget } from "../renderers/RenderTarget";

export class CubeCamera extends Object3D {
    readonly isCubeCamera: bool = true;
    renderTarget: WebGLCubeRenderTarget;
    cameras: Array<PerspectiveCamera> = [];

    constructor(near: f64, far: f64, renderTarget: WebGLCubeRenderTarget) {
        super();
        this.type = "CubeCamera";
        this.renderTarget = renderTarget;
        // three.js's face cameras (its WebGL coordinate system).
        const dirs: StaticArray<f64> = [1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1];
        const ups: StaticArray<f64> = [0, -1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, 0, -1, 0, 0, -1, 0];
        for (let i = 0; i < 6; i++) {
            const cam = new PerspectiveCamera(90, 1, near, far);
            cam.layers = this.layers;   // shared, as three.js: later layer changes reach every face
            cam.up.set(ups[i * 3], ups[i * 3 + 1], ups[i * 3 + 2]);
            cam.lookAt<f64>(dirs[i * 3], dirs[i * 3 + 1], dirs[i * 3 + 2]);
            this.add(cam);
            this.cameras.push(cam);
        }
    }

    /// Renders the six faces of `scene` from this camera's position.
    update(renderer: GPURenderer, scene: Object3D): void {
        if (this.parent == null) this.updateMatrixWorld();
        const current: RenderTarget? = renderer.getRenderTarget();
        for (let i = 0; i < 6; i++) {
            renderer.setRenderTarget(this.renderTarget.faces[i]);
            renderer.render(scene, this.cameras[i]);
        }
        renderer.setRenderTarget(current);
        this.renderTarget.texture.version++;
    }
}
