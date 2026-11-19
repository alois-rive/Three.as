// three.js FramebufferTexture: a texture that
// renderer.copyFramebufferToTexture fills from what was rendered.
//
//     const texture = new FramebufferTexture(128, 128);
//     renderer.render(scene, camera);
//     renderer.copyFramebufferToTexture(texture, new Vector2(x, y));
//     sprite.material.map = texture;
//
// The renderer owns its GPU texture (rgba8, or rgba16float when the first
// copy comes from a HalfFloatType target); its colour space and alpha
// follow the source copied (sRGB and premultiplied from the canvas).

import { Texture } from "./Texture";
import { NearestFilter } from "../constants";

export class FramebufferTexture extends Texture {
    readonly isFramebufferTexture: bool = true;
    private fbWidth: u32;
    private fbHeight: u32;

    constructor(width: u32, height: u32) {
        super(null);
        this.fbWidth = width;
        this.fbHeight = height;
        this.magFilter = NearestFilter;
        this.minFilter = NearestFilter;
        this.generateMipmaps = false;
        this.flipY = true;
        this.premultiplyAlpha = true;
        this.version++;
    }

    override get width(): u32 { return this.fbWidth; }
    override get height(): u32 { return this.fbHeight; }
}
