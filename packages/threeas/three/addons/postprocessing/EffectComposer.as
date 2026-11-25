// three.js examples/jsm/postprocessing/EffectComposer.js: runs passes over
// two ping-pong render targets. The targets are HalfFloatType (linear HDR),
// as three.js's default; render the last pass to the screen with an
// OutputPass (tone mapping and sRGB).
//
// Masks (MaskPass ... ClearMaskPass): three.js stencil-tests the passes in
// between; Rive keeps no stencil across passes, so the composer restores
// what each of them changed outside the mask (MaskPass.maskTarget): a
// swapping pass gets the read buffer back outside the mask (three.js's
// NOTEQUAL copy), a non-swapping one (RenderPass, TexturePass, ClearPass)
// the read buffer as it was before it ran. Passes that render to the
// screen are not masked (three.js's stencil is the targets' too).

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { Vector2 } from "../../math/Vector2";
import { HalfFloatType } from "../../constants";
import { CopyShader } from "../shaders/PostShaders";
import { Pass, FullScreenQuad } from "./Pass";
import { ShaderPass } from "./ShaderPass";
import { MaskPass, ClearMaskPass, MaskCompositeShader } from "./MaskPass";

export class EffectComposer {
    renderer: GPURenderer;
    renderTarget1: RenderTarget;
    renderTarget2: RenderTarget;
    writeBuffer: RenderTarget;
    readBuffer: RenderTarget;
    /// Render the last enabled pass to the screen.
    renderToScreen: bool = true;
    passes: Array<Pass> = [];
    /// A CopyShader pass (three.js's; the mask emulation backs buffers up
    /// with it).
    copyPass: ShaderPass;

    private _pixelRatio: f64;
    private _width: f64;
    private _height: f64;
    private _size: Vector2 = new Vector2();
    // The mask in effect, its backup buffer and composite.
    private mask: MaskPass? = null;
    private maskBackup: RenderTarget? = null;
    private maskMaterial: ShaderMaterial;
    private maskQuad: FullScreenQuad;

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
        this.copyPass = new ShaderPass(CopyShader);
        this.maskMaterial = MaskCompositeShader.createMaterial();
        this.maskQuad = new FullScreenQuad(this.maskMaterial);
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
        const len = this.passes.length;
        let idx = index < 0 ? len + index : index;
        if (idx < 0) idx = 0;
        if (idx > len) idx = len;
        const list: Array<Pass> = [];
        for (let i = 0; i < len; i++) {
            if (i == idx) list.push(pass);
            list.push(this.passes[i]);
        }
        if (idx >= len) list.push(pass);
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

    /// Whether a mask is in effect after `pass` ran (three.js's
    /// `pass instanceof MaskPass / ClearMaskPass` checks).
    static maskActiveAfter(pass: Pass, maskActive: bool): bool {
        if (pass instanceof MaskPass) return true;
        if (pass instanceof ClearMaskPass) return false;
        return maskActive;
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
        let maskActive = false;
        this.mask = null;
        for (let i = 0; i < this.passes.length; i++) {
            const pass = this.passes[i];
            if (!pass.enabled) continue;
            pass.renderToScreen = this.renderToScreen && this.isLastEnabledPass(i);
            // Under a mask, what the pass changes outside it is put back.
            const masked = maskActive && this.mask != null && !pass.renderToScreen
                && !(pass instanceof MaskPass) && !(pass instanceof ClearMaskPass);
            let backup: RenderTarget? = null;
            if (masked && !pass.needsSwap) backup = this.backupReadBuffer(deltaTime);
            pass.render(this.renderer, this.writeBuffer, this.readBuffer, deltaTime, maskActive);
            if (pass.needsSwap) {
                if (masked) this.restoreOutsideMask(this.readBuffer.texture, this.writeBuffer);
                this.swapBuffers();
            } else if (backup != null) {
                this.restoreOutsideMask(backup.texture, this.readBuffer);
            }
            maskActive = EffectComposer.maskActiveAfter(pass, maskActive);
            if (pass instanceof MaskPass) this.mask = pass as MaskPass;
            else if (!maskActive) this.mask = null;
        }
        this.mask = null;
        this.renderer.setRenderTarget(current);
    }

    /// A copy of the read buffer (before a non-swapping pass draws into it).
    private backupReadBuffer(deltaTime: f64): RenderTarget {
        let backup = this.maskBackup;
        if (backup == null) {
            backup = this.readBuffer.clone();
            this.maskBackup = backup;
        }
        backup.setSize(this.readBuffer.width, this.readBuffer.height);
        this.copyPass.renderToScreen = false;
        this.copyPass.render(this.renderer, backup, this.readBuffer, deltaTime, false);
        return backup;
    }

    /// Draws `source` into `target` outside the mask (inside with inverse).
    private restoreOutsideMask(source: Texture, target: RenderTarget): void {
        const mask = this.mask!;
        const u = this.maskMaterial.uniforms;
        (u.get("inverse") as Uniform<f64>).value = mask.inverse ? 1 : 0;
        (u.get("tDiffuse") as Uniform<Texture>).value = source;
        (u.get("tMask") as Uniform<Texture>).value = mask.maskTarget.texture;
        const renderer = this.renderer;
        const oldAutoClear = renderer.autoClear;
        renderer.autoClear = false;
        renderer.setRenderTarget(target);
        this.maskQuad.render(renderer);
        renderer.autoClear = oldAutoClear;
    }

    reset(renderTarget: RenderTarget? = null): void {
        if (renderTarget == null) {
            this.renderer.getSize(this._size);
            this._pixelRatio = this.renderer.getPixelRatio();
            this._width = this._size.x;
            this._height = this._size.y;
            const w = <u32>Math.max(1, this._width * this._pixelRatio);
            const h = <u32>Math.max(1, this._height * this._pixelRatio);
            this.renderTarget1.setSize(w, h);
            this.renderTarget2.setSize(w, h);
            const backup = this.maskBackup;
            if (backup != null) backup.setSize(w, h);
        } else {
            this.renderTarget1.dispose();
            this.renderTarget2.dispose();
            const backup = this.maskBackup;
            if (backup != null) {
                backup.dispose();
                this.maskBackup = null;
            }
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
        const backup = this.maskBackup;
        if (backup != null) backup.setSize(w, h);
        for (let i = 0; i < this.passes.length; i++) this.passes[i].setSize(<f64>w, <f64>h);
    }

    setPixelRatio(pixelRatio: f64): void {
        this._pixelRatio = pixelRatio;
        this.setSize(this._width, this._height);
    }

    dispose(): void {
        this.renderTarget1.dispose();
        this.renderTarget2.dispose();
        const backup = this.maskBackup;
        if (backup != null) backup.dispose();
        this.maskBackup = null;
        this.mask = null;
        this.copyPass.dispose();
        this.maskMaterial.dispose();
        this.maskQuad.dispose();
        for (let i = 0; i < this.passes.length; i++) this.passes[i].dispose();
    }
}
