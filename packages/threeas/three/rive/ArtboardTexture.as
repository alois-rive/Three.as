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
// model (`artboard.data()`) or forward pointer events to it. `dispose()`
// releases the canvas and the instance it made (not an artboard passed
// with `instance = false`); the texture draws nothing afterwards.

import { Context } from "rive/host";
import { Artboard } from "rive/artboard";
import { Canvas } from "rive/canvas";
import { Mat2D } from "rive/mat2d";
import { PointerEvent } from "rive/events";
import { Vector } from "rive/vector";
import { Texture } from "../textures/Texture";
import { Vector2 } from "../math/Vector2";

// ArtboardTextures made and not disposed (ArtboardTexture.live()).
let _live: i32 = 0;
const _pointerTypes: StaticArray<string> = ["down", "move", "up", "exit"];

export class ArtboardTexture extends Texture {
    readonly isArtboardTexture: bool = true;
    /// The artboard instance drawn.
    readonly artboard: Artboard;
    /// Canvas clear colour, a Rive Color (0xAARRGGBB). Transparent by
    /// default; the artboard's own background, if any, covers it.
    clearColor: u32 = 0;
    /// Takes pointer events at a UV (ThreeLayout forwards the pointer's
    /// raycast hits on meshes using this texture as their map).
    interactive: bool = true;

    private requestedWidth: u32;
    private requestedHeight: u32;
    private canvas: Canvas? = null;
    private drawnVersion: i32 = -1;
    private counted: bool = true;
    private wasHit: bool = false;
    // Whether it made the instance (and releases it on dispose).
    private ownsArtboard: bool;
    /// Whether dispose() ran: the artboard may be released, nothing draws,
    /// advances or takes pointer events.
    disposed: bool = false;

    /// How many ArtboardTextures exist (made and not disposed): with none,
    /// ThreeLayout does no pointer picking at all.
    static live(): i32 { return _live; }

    /// Instances `artboard` (with `viewModel` bound, if given) and draws it
    /// at `width` x `height` pixels; 0 takes the artboard's own size.
    constructor(artboard: Artboard, width: u32 = 0, height: u32 = 0, instance: bool = true) {
        super(null);
        this.artboard = instance ? artboard.instance() : artboard;
        this.ownsArtboard = instance;
        this.requestedWidth = width;
        this.requestedHeight = height;
        this.premultiplyAlpha = true;
        this.colorSpace = "srgb";
        this.artboard.advance(0);
        _live++;
    }

    /// Advances the artboard (and its state machine) by `seconds`. Returns
    /// what Artboard.advance returns: true while it keeps changing.
    advance(seconds: f64): bool {
        if (this.disposed) return false;
        const changed = this.artboard.advance(seconds);
        if (changed) this.version++;
        return changed;
    }

    /// Forwards a pointer press at texture coordinate `uv` (a raycast hit's
    /// uv) to the artboard; true when something in it was hit.
    pointerDown(uv: Vector2, id: f64 = 0): bool { return this.forward(0, uv, id); }
    pointerMove(uv: Vector2, id: f64 = 0): bool { return this.forward(1, uv, id); }
    pointerUp(uv: Vector2, id: f64 = 0): bool { return this.forward(2, uv, id); }
    pointerExit(uv: Vector2, id: f64 = 0): bool { return this.forward(3, uv, id); }

    /// The artboard point at texture coordinate `uv`.
    artboardPoint(uv: Vector2): Vector {
        const b = this.artboard.bounds();
        const v = this.flipY ? 1 - uv.y : uv.y;
        return Vector.xy(b.v0.x + <f32>uv.x * (b.v1.x - b.v0.x), b.v0.y + <f32>v * (b.v1.y - b.v0.y));
    }

    private forward(kind: i32, uv: Vector2, id: f64): bool {
        if (this.disposed) return false;
        const p = this.artboardPoint(uv);
        const event = new PointerEvent(id, p, p, _pointerTypes[kind]);
        let hit: f64 = 0;
        if (kind == 0) hit = this.artboard.pointerDown(event);
        else if (kind == 1) hit = this.artboard.pointerMove(event);
        else if (kind == 2) hit = this.artboard.pointerUp(event);
        else hit = this.artboard.pointerExit(event);
        const isHit = hit != 0;
        if (isHit || this.wasHit || kind != 1) this.version++;   // a hover/unhover or press may change what it draws
        this.wasHit = isHit && kind != 3;
        return isHit;
    }

    override get width(): u32 {
        if (this.requestedWidth > 0) return this.requestedWidth;
        if (this.disposed) return 1;
        const b = this.artboard.bounds();
        return <u32>Math.max(1, Math.ceil(<f64>(b.v1.x - b.v0.x)));
    }

    override get height(): u32 {
        if (this.requestedHeight > 0) return this.requestedHeight;
        if (this.disposed) return 1;
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
        if (this.disposed) return;
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
            this.image = canvas.image;
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

    /// Releases the canvas and, when it made it, the artboard instance
    /// (Rive-only: three.js's dispose frees GPU memory only). Calling it
    /// again only queues the texture again.
    override dispose(): void {
        const canvas = this.canvas;
        if (canvas != null) canvas.release();
        this.canvas = null;
        this.image = null;
        if (this.counted) _live--;
        this.counted = false;
        if (!this.disposed && this.ownsArtboard) this.artboard.release();
        this.disposed = true;
        super.dispose();
    }
}
