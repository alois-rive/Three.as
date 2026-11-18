// three.js Texture. `image` is a Rive `Image`: an image asset
// (`context.image(name)`, see TextureLoader), a canvas's image, or any
// image a script holds. The renderer samples it through `Image.view()`.
//
// Rive images are premultiplied and stored top row first, so a Texture
// made from one keeps three.js's `flipY = true` behaviour (UV v = 0 at the
// bottom) and unpremultiplies when sampling. Unlike three.js, a texture
// made from a Rive image defaults to SRGBColorSpace.

import { Context } from "rive/host";
import { Image } from "rive/image";
import { GPUTextureView } from "rive/gpu";
import { Vector2 } from "../math/Vector2";
import { Matrix3 } from "../math/Matrix3";
import { ColorOrTexture } from "../core/ColorOrTexture";
import {
    ClampToEdgeWrapping, LinearFilter, LinearMipmapLinearFilter, NoColorSpace, SRGBColorSpace,
    RGBAFormat, UnsignedByteType, UVMapping,
} from "../constants";

let _textureId: i32 = 0;

/// Textures disposed since the renderer last looked (ids). Internal.
export const disposedTextures: Array<i32> = [];

export class Texture extends ColorOrTexture {
    readonly isTexture: bool = true;
    id: i32;
    name: string = "";
    /// The Rive image sampled, or null (a texture with nothing to show
    /// samples white).
    image: Image? = null;

    mapping: i32 = UVMapping;
    wrapS: i32 = ClampToEdgeWrapping;
    wrapT: i32 = ClampToEdgeWrapping;
    magFilter: i32 = LinearFilter;
    minFilter: i32 = LinearMipmapLinearFilter;
    anisotropy: i32 = 1;
    format: i32 = RGBAFormat;
    type: i32 = UnsignedByteType;

    /// UV transform, as three.js: `matrix` is made from offset, repeat,
    /// rotation (radians) and center when matrixAutoUpdate is set.
    offset: Vector2 = new Vector2(0, 0);
    repeat: Vector2 = new Vector2(1, 1);
    center: Vector2 = new Vector2(0, 0);
    rotation: f64 = 0;
    matrixAutoUpdate: bool = true;
    matrix: Matrix3 = new Matrix3();
    /// The UV set read: 0 "uv", 1 "uv1" (2 and 3 read "uv1" too).
    channel: i32 = 0;

    generateMipmaps: bool = true;
    /// The image's first row is the top (v = 1); false for data laid out
    /// bottom row first.
    flipY: bool = true;
    /// Whether the texels are premultiplied by alpha. True for Rive images
    /// and canvases; the shader unpremultiplies them.
    premultiplyAlpha: bool = false;
    colorSpace: string = NoColorSpace;
    /// Bumped by `needsUpdate = true`.
    version: i32 = 0;

    private cachedView: GPUTextureView? = null;
    private cachedFor: Image? = null;
    private cachedW: u32 = 0;
    private cachedH: u32 = 0;

    constructor(image: Image? = null) {
        super();
        this.id = _textureId++;
        this.image = image;
        if (image != null) {
            this.premultiplyAlpha = true;
            this.colorSpace = SRGBColorSpace;
        }
    }

    /// Whether getView() is a float (rgba16float) texture (internal: mip
    /// chains keep its format).
    get isHDRSource(): bool { return false; }

    /// Rebuilds `matrix` from offset, repeat, rotation and center.
    updateMatrix(): void {
        this.matrix.setUvTransform(this.offset.x, this.offset.y, this.repeat.x, this.repeat.y, this.rotation,
            this.center.x, this.center.y);
    }

    set needsUpdate(value: bool) { if (value) this.version++; }

    get width(): u32 { const i = this.image; return i != null ? i.width : 0; }
    get height(): u32 { const i = this.image; return i != null ? i.height : 0; }

    /// Called by the renderer, while drawing, on every texture a visible
    /// material uses, before the 3D passes. Subclasses that draw or upload
    /// do it here.
    update(context: Context): void {}

    /// The view the renderer binds, or null while there is nothing to
    /// sample (an image still decoding).
    getView(): GPUTextureView? {
        const image = this.image;
        if (image == null || image.width == 0 || image.height == 0) return null;
        if (this.cachedView == null || this.cachedFor !== image
                || this.cachedW != image.width || this.cachedH != image.height) {
            this.cachedView = image.view();
            this.cachedFor = image;
            this.cachedW = image.width;
            this.cachedH = image.height;
        }
        return this.cachedView;
    }

    /// Frees GPU resources the renderer made for this texture.
    dispose(): void {
        disposedTextures.push(this.id);
    }
}
