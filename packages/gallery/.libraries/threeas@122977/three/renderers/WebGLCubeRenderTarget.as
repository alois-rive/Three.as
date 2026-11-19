// three.js WebGLCubeRenderTarget: six render targets, one per cube face,
// whose `texture` is a CubeTexture over them (for CubeCamera). Faces are
// HalfFloatType by default (linear HDR; three.js defaults to
// UnsignedByteType).

import { RenderTarget, RenderTargetOptions } from "./RenderTarget";
import { CubeTexture } from "../textures/CubeTexture";
import { HalfFloatType, LinearMipmapLinearFilter, NoColorSpace } from "../constants";

export class WebGLCubeRenderTarget {
    readonly isWebGLCubeRenderTarget: bool = true;
    width: u32;
    height: u32;
    faces: Array<RenderTarget> = [];
    texture: CubeTexture = new CubeTexture();

    constructor(size: u32 = 1, options: RenderTargetOptions? = null) {
        this.width = size;
        this.height = size;
        let o = options;
        if (o == null) {
            o = new RenderTargetOptions();
            o.type = HalfFloatType;
        }
        for (let i = 0; i < 6; i++) {
            const rt = new RenderTarget(size, size, o);
            this.faces.push(rt);
            this.texture.faces[i] = rt.texture;
        }
        const t = this.texture;
        t.flipX = false;
        t.flipRows = true;
        t.colorSpace = o!.type == HalfFloatType || o!.type != 1009 ? NoColorSpace : t.colorSpace;
        t.premultiplyAlpha = true;
        t.generateMipmaps = true;
        t.minFilter = LinearMipmapLinearFilter;
    }

    setSize(width: u32, height: u32): void {
        this.width = width;
        this.height = height;
        for (let i = 0; i < 6; i++) this.faces[i].setSize(width, height);
        this.texture.version++;
    }

    dispose(): void {
        for (let i = 0; i < 6; i++) this.faces[i].dispose();
    }
}

export { WebGLCubeRenderTarget as CubeRenderTarget };
