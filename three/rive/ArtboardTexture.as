// A live Rive artboard as a texture: a three.js-style Texture that draws
// an instance of an artboard into its own canvas. Use it as any material's
// `map`, for screens, signs, labels or a UI on a 3D surface.
//
//     @input screen: Artboard? = null;
//     ...
//     const texture = new ArtboardTexture(screen!, 512, 512);
//     const material = new MeshStandardMaterial({ map: texture });
//     ...
//     override advance(seconds: f64): bool {
//         texture.advance(seconds);   // plays its state machine
//         ...
//
// The canvas is redrawn on the frame after an advance that reported a
// change (or `needsUpdate = true`), not every frame: a still artboard
// costs nothing. `artboard` is the instance: read its nodes, bind its view
// model (`artboard.data()`) or forward pointer events to it.

import { Context } from "rive/host";
import { Artboard } from "rive/artboard";
import { Canvas } from "rive/canvas";
import { Mat2D } from "rive/mat2d";
import { Texture } from "../textures/Texture";

export class ArtboardTexture extends Texture {
    readonly isArtboardTexture: bool = true;
    /// The artboard instance drawn.
    readonly artboard: Artboard;
    /// Canvas clear colour, a Rive Color (0xAARRGGBB). Transparent by
    /// default; the artboard's own background, if any, covers it.
    clearColor: u32 = 0;

    private requestedWidth: u32;
    private requestedHeight: u32;
    private canvas: Canvas? = null;
    private drawnVersion: i32 = -1;

    /// Instances `artboard` (with `viewModel` bound, if given) and draws it
    /// at `width` x `height` pixels; 0 takes the artboard's own size.
    constructor(artboard: Artboard, width: u32 = 0, height: u32 = 0, instance: bool = true) {
        super(null);
        this.artboard = instance ? artboard.instance() : artboard;
        this.requestedWidth = width;
        this.requestedHeight = height;
        this.premultiplyAlpha = true;
        this.colorSpace = "srgb";
        this.artboard.advance(0);
    }

    /// Advances the artboard (and its state machine) by `seconds`. Returns
    /// what Artboard.advance returns: true while it keeps changing.
    advance(seconds: f64): bool {
        const changed = this.artboard.advance(seconds);
        if (changed) this.version++;
        return changed;
    }

    override get width(): u32 {
        if (this.requestedWidth > 0) return this.requestedWidth;
        const b = this.artboard.bounds();
        return <u32>Math.max(1, Math.ceil(<f64>(b.v1.x - b.v0.x)));
    }

    override get height(): u32 {
        if (this.requestedHeight > 0) return this.requestedHeight;
        const b = this.artboard.bounds();
        return <u32>Math.max(1, Math.ceil(<f64>(b.v1.y - b.v0.y)));
    }

    /// Resizes the canvas (pixels; 0 takes the artboard's size).
    setSize(width: u32, height: u32): void {
        this.requestedWidth = width;
        this.requestedHeight = height;
        this.version++;
    }

    override update(context: Context): void {
        const w = this.width, h = this.height;
        let canvas = this.canvas;
        if (canvas == null) {
            canvas = context.canvas(w, h);
            if (canvas == null) return;
            this.canvas = canvas;
            this.image = canvas.image;
            this.drawnVersion = -1;
        } else if (canvas.width != w || canvas.height != h) {
            if (!canvas.resize(w, h)) return;
            this.drawnVersion = -1;
        }
        if (this.drawnVersion == this.version) return;
        const r = canvas.beginFrame(this.clearColor);
        if (r == null) return;
        const b = this.artboard.bounds();
        const bw = b.v1.x - b.v0.x, bh = b.v1.y - b.v0.y;
        const sx: f32 = bw > 0 ? <f32>w / bw : 1;
        const sy: f32 = bh > 0 ? <f32>h / bh : 1;
        r.save();
        r.transform(Mat2D(sx, 0, 0, sy, -b.v0.x * sx, -b.v0.y * sy));
        this.artboard.draw(r);
        r.restore();
        canvas.endFrame();
        this.drawnVersion = this.version;
    }

    override dispose(): void {
        const canvas = this.canvas;
        if (canvas != null) canvas.release();
        this.canvas = null;
        this.image = null;
        super.dispose();
    }
}
