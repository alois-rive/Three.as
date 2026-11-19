// Helpers shared by SSAOPass, SAOPass and GTAOPass (three.js repeats them
// in each pass): camera range and kind, hiding points and lines for the
// normal prepass, and the passes' renderPass / renderOverride.

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { Material } from "../../materials/Material";
import { Points } from "../../objects/Points";
import { Line } from "../../objects/Line";
import { Scene } from "../../scenes/Scene";
import { Color } from "../../math/Color";
import { FullScreenQuad } from "./Pass";

/// The camera's near plane (Perspective / OrthographicCamera; else 0.1).
export function cameraNear(camera: Camera): f64 {
    if (camera instanceof PerspectiveCamera) return (camera as PerspectiveCamera).near;
    if (camera instanceof OrthographicCamera) return (camera as OrthographicCamera).near;
    return 0.1;
}

/// The camera's far plane (Perspective / OrthographicCamera; else 2000).
export function cameraFar(camera: Camera): f64 {
    if (camera instanceof PerspectiveCamera) return (camera as PerspectiveCamera).far;
    if (camera instanceof OrthographicCamera) return (camera as OrthographicCamera).far;
    return 2000;
}

/// 1 for a perspective camera (three.js's PERSPECTIVE_CAMERA define).
export function isPerspective(camera: Camera): f64 {
    return camera instanceof OrthographicCamera ? 0 : 1;
}

/// Hides the visible points and lines under `scene` (they do not take part
/// in ambient occlusion), remembering them in `hidden`.
export function hidePointsAndLines(scene: Object3D, hidden: Array<Object3D>): void {
    hidden.length = 0;
    const stack: Array<Object3D> = [scene];
    while (stack.length > 0) {
        const o = stack.pop();
        if ((o instanceof Points || o instanceof Line) && o.visible) {
            o.visible = false;
            hidden.push(o);
        }
        const children = o.children;
        for (let i = 0; i < children.length; i++) stack.push(children[i]);
    }
}

/// Shows again what hidePointsAndLines hid.
export function restoreHidden(hidden: Array<Object3D>): void {
    for (let i = 0; i < hidden.length; i++) hidden[i].visible = true;
    hidden.length = 0;
}

const _originalClearColor = new Color();

/// The passes' renderPass: `material` on the fullscreen quad into
/// `renderTarget` (null: the screen), cleared first to `clearColor` (an
/// sRGB hex; -1: no clear) and `clearAlpha`.
export function aoRenderPass(renderer: GPURenderer, quad: FullScreenQuad, material: Material,
                             renderTarget: RenderTarget?, clearColor: i64 = -1, clearAlpha: f64 = 0): void {
    renderer.getClearColor(_originalClearColor);
    const originalClearAlpha = renderer.getClearAlpha();
    const originalAutoClear = renderer.autoClear;
    renderer.setRenderTarget(renderTarget);
    renderer.autoClear = false;
    if (clearColor >= 0) {
        renderer.setClearColor<u32>(<u32>clearColor);
        renderer.setClearAlpha(clearAlpha);
        renderer.clear();
    }
    quad.material = material;
    quad.render(renderer);
    renderer.autoClear = originalAutoClear;
    renderer.setClearColor<Color>(_originalClearColor);
    renderer.setClearAlpha(originalClearAlpha);
}

/// The passes' renderOverride: `scene` with `overrideMaterial` into
/// `renderTarget`, cleared first.
export function aoRenderOverride(renderer: GPURenderer, scene: Object3D, camera: Camera, overrideMaterial: Material,
                                 renderTarget: RenderTarget?, clearColor: i64 = -1, clearAlpha: f64 = 0): void {
    renderer.getClearColor(_originalClearColor);
    const originalClearAlpha = renderer.getClearAlpha();
    const originalAutoClear = renderer.autoClear;
    renderer.setRenderTarget(renderTarget);
    renderer.autoClear = false;
    if (clearColor >= 0) {
        renderer.setClearColor<u32>(<u32>clearColor);
        renderer.setClearAlpha(clearAlpha);
        renderer.clear();
    }
    let old: Material? = null;
    if (scene instanceof Scene) {
        old = (scene as Scene).overrideMaterial;
        (scene as Scene).overrideMaterial = overrideMaterial;
    }
    renderer.render(scene, camera);
    if (scene instanceof Scene) (scene as Scene).overrideMaterial = old;
    renderer.autoClear = originalAutoClear;
    renderer.setClearColor<Color>(_originalClearColor);
    renderer.setClearAlpha(originalClearAlpha);
}
