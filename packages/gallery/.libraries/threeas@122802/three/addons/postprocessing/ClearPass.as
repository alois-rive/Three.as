// three.js examples/jsm/postprocessing/ClearPass.js: clears the read
// buffer (or the screen) to `clearColor` / `clearAlpha` (it does not swap).
// As three.js, a clearColor of 0 (black) keeps the renderer's clear colour.

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { Color } from "../../math/Color";
import { Pass } from "./Pass";

export class ClearPass extends Pass {
    /// An sRGB hex colour (0: the renderer's).
    clearColor: u32;
    clearAlpha: f64;
    private _oldClearColor: Color = new Color();

    constructor(clearColor: u32 = 0x000000, clearAlpha: f64 = 0) {
        super();
        this.needsSwap = false;
        this.clearColor = clearColor;
        this.clearAlpha = clearAlpha;
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        let oldClearAlpha: f64 = 0;
        const set = this.clearColor != 0;
        if (set) {
            renderer.getClearColor(this._oldClearColor);
            oldClearAlpha = renderer.getClearAlpha();
            renderer.setClearColor<u32>(this.clearColor, this.clearAlpha);
        }
        renderer.setRenderTarget(this.renderToScreen ? null : readBuffer);
        renderer.clear();
        if (set) renderer.setClearColor<Color>(this._oldClearColor, oldClearAlpha);
    }
}
