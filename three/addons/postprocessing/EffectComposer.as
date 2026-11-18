// three.js examples/jsm/postprocessing/EffectComposer.js: runs passes over
// two ping-pong render targets. The targets are HalfFloatType (linear HDR),
// as three.js's default; render the last pass to the screen with an
// OutputPass (tone mapping and sRGB). Masks (MaskPass) are not supported.

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { Vector2 } from "../../math/Vector2";
import { HalfFloatType } from "../../constants";
import { Pass } from "./Pass";

export class EffectComposer {
    renderer: GPURenderer;
    renderTarget1: RenderTarget;
    renderTarget2: RenderTarget;
    writeBuffer: RenderTarget;
    readBuffer: RenderTarget;
    /// Render the last enabled pass to the screen.
    renderToScreen: bool = true;
    passes: Array<Pass> = [];

    private _pixelRatio: f64;
    private _width: f64;
    private _height: f64;
    private _size: Vector2 = new Vector2();

    constructor(renderer: GPURenderer, renderTarget: RenderTarget? = null) {
        this.renderer = renderer;
        this._pixelRatio = renderer.getPixelRatio();
        renderer.getSize(this._size);
        this._width = this._size.x;
        this._height = this._size.y;
        let rt: RenderTarget;
        if (renderTarget == null) {
            rt = new RenderTarget(<u32>Math.max(1, this._width * this._pixelRatio),
                <u32>Math.max(1, this._height * this._pixelRatio), { type: HalfFloatType });
        } else {
            rt = renderTarget!;
        }
        this.renderTarget1 = rt;
        this.renderTarget2 = rt.clone();
        this.writeBuffer = this.renderTarget1;
        this.readBuffer = this.renderTarget2;
    }

    swapBuffers(): void {
        const tmp = this.readBuffer;
        this.readBuffer = this.writeBuffer;
        this.writeBuffer = tmp;
    }

    addPass(pass: Pass): void {
        this.passes.push(pass);
        pass.setSize(this._width * this._pixelRatio, this._height * this._pixelRatio);
    }

    insertPass(pass: Pass, index: i32): void {
        const list: Array<Pass> = [];
        for (let i = 0; i < this.passes.length; i++) {
            if (i == index) list.push(pass);
            list.push(this.passes[i]);
        }
        if (index >= this.passes.length) list.push(pass);
        this.passes = list;
        pass.setSize(this._width * this._pixelRatio, this._height * this._pixelRatio);
    }

    removePass(pass: Pass): void {
        const index = this.passes.indexOf(pass);
        if (index >= 0) this.passes.splice(index, 1);
    }

    isLastEnabledPass(passIndex: i32): bool {
        for (let i = passIndex + 1; i < this.passes.length; i++) {
            if (this.passes[i].enabled) return false;
        }
        return true;
    }

    /// Runs the passes. `deltaTime` is in seconds (ThreeLayout.delta).
    render(deltaTime: f64 = 0): void {
        // Follow the renderer's size, as three.js's composer does on resize.
        this.renderer.getSize(this._size);
        const ratio = this.renderer.getPixelRatio();
        if (this._size.x != this._width || this._size.y != this._height || ratio != this._pixelRatio) {
            this._pixelRatio = ratio;
            this.setSize(this._size.x, this._size.y);
        }
        const current = this.renderer.getRenderTarget();
        for (let i = 0; i < this.passes.length; i++) {
            const pass = this.passes[i];
            if (!pass.enabled) continue;
            pass.renderToScreen = this.renderToScreen && this.isLastEnabledPass(i);
            pass.render(this.renderer, this.writeBuffer, this.readBuffer, deltaTime, false);
            if (pass.needsSwap) this.swapBuffers();
        }
        this.renderer.setRenderTarget(current);
    }

    reset(renderTarget: RenderTarget? = null): void {
        if (renderTarget == null) {
            this.renderer.getSize(this._size);
            this._pixelRatio = this.renderer.getPixelRatio();
            this._width = this._size.x;
            this._height = this._size.y;
            this.renderTarget1.setSize(<u32>(this._width * this._pixelRatio), <u32>(this._height * this._pixelRatio));
            this.renderTarget2.setSize(<u32>(this._width * this._pixelRatio), <u32>(this._height * this._pixelRatio));
        } else {
            this.renderTarget1.dispose();
            this.renderTarget2.dispose();
            this.renderTarget1 = renderTarget!;
            this.renderTarget2 = renderTarget!.clone();
        }
        this.writeBuffer = this.renderTarget1;
        this.readBuffer = this.renderTarget2;
    }

    setSize(width: f64, height: f64): void {
        this._width = width;
        this._height = height;
        const w = <u32>Math.max(1, width * this._pixelRatio);
        const h = <u32>Math.max(1, height * this._pixelRatio);
        this.renderTarget1.setSize(w, h);
        this.renderTarget2.setSize(w, h);
        for (let i = 0; i < this.passes.length; i++) this.passes[i].setSize(<f64>w, <f64>h);
    }

    setPixelRatio(pixelRatio: f64): void {
        this._pixelRatio = pixelRatio;
        this.setSize(this._width, this._height);
    }

    dispose(): void {
        this.renderTarget1.dispose();
        this.renderTarget2.dispose();
        for (let i = 0; i < this.passes.length; i++) this.passes[i].dispose();
    }
}
