// three.js CanvasTexture, over a Rive 2D `Canvas` (`context.canvas(w, h)`):
// draw into the canvas with beginFrame/endFrame, and the material samples
// what it drew. Rive's equivalent of drawing on an HTML canvas.

import { Canvas } from "rive/canvas";
import { Texture } from "./Texture";

export class CanvasTexture extends Texture {
    readonly isCanvasTexture: bool = true;
    canvas: Canvas;

    constructor(canvas: Canvas) {
        super(canvas.image);
        this.canvas = canvas;
    }
}
