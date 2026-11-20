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
import { Event } from "../core/EventDispatcher";
import { MathUtils } from "../math/MathUtils";
import { Source } from "./Source";
import { Dynamic } from "rive/dynamic";
import {
    JSONMeta, jsonMetadata, setNumber, setString, setBool, setNumbers, isEmptyTable,
} from "../core/JSON";
import {
    ClampToEdgeWrapping, LinearFilter, LinearMipmapLinearFilter, NoColorSpace, SRGBColorSpace,
    RGBAFormat, UnsignedByteType, UVMapping,
} from "../constants";

let _textureId: i32 = 0;

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
    /// Where the image came from (see Source), for toJSON.
    source: Source = new Source();
    private _uuid: string = "";
    private _userData: Dynamic? = null;

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

    /// A random uuid, made on first use.
    get uuid(): string {
        if (this._uuid.length == 0) this._uuid = MathUtils.generateUUID();
        return this._uuid;
    }
    set uuid(value: string) { this._uuid = value; }

    /// A `Dynamic` table, as three.js's userData (see Object3D.userData).
    get userData(): Dynamic {
        let d = this._userData;
        if (d == null) {
            d = Dynamic.newTable();
            this._userData = d;
        }
        return d!;
    }
    set userData(value: Dynamic) { this._userData = value; }

    /// three.js's JSON: { metadata, uuid, name, image (the source's uuid),
    /// mapping, channel, repeat, offset, center, rotation, wrap, format,
    /// type, colorSpace, minFilter, magFilter, anisotropy, flipY,
    /// generateMipmaps, premultiplyAlpha, unpackAlignment, userData }. The
    /// image goes to `meta.images` (see imageToJSON); with a `meta`, the
    /// texture goes to `meta.textures` and is written once.
    toJSON(meta: JSONMeta? = null): Dynamic {
        const isRootObject = meta == null;
        if (meta != null && meta.textures.has(this.uuid)) return meta.textures.get(this.uuid);
        const output = Dynamic.newTable();
        output.set("metadata", jsonMetadata("Texture", "Texture.toJSON"));
        setString(output, "uuid", this.uuid);
        setString(output, "name", this.name);
        const image = this.imageToJSON();
        if (image != null) {
            const uuid = Dynamic.asString(image.get("uuid"));
            if (meta != null && !meta.images.has(uuid)) meta.images.set(uuid, image);
            setString(output, "image", uuid);
        }
        setNumber(output, "mapping", <f64>this.mapping);
        setNumber(output, "channel", <f64>this.channel);
        setNumbers(output, "repeat", [this.repeat.x, this.repeat.y]);
        setNumbers(output, "offset", [this.offset.x, this.offset.y]);
        setNumbers(output, "center", [this.center.x, this.center.y]);
        setNumber(output, "rotation", this.rotation);
        setNumbers(output, "wrap", [<f64>this.wrapS, <f64>this.wrapT]);
        setNumber(output, "format", <f64>this.format);
        setNumber(output, "type", <f64>this.type);
        setString(output, "colorSpace", this.colorSpace);
        setNumber(output, "minFilter", <f64>this.minFilter);
        setNumber(output, "magFilter", <f64>this.magFilter);
        setNumber(output, "anisotropy", <f64>this.anisotropy);
        setBool(output, "flipY", this.flipY);
        setBool(output, "generateMipmaps", this.generateMipmaps);
        // Images (decoded by Rive, premultiplied) are straight-alpha files
        // to three.js, whose premultiplyAlpha asks the upload to premultiply.
        setBool(output, "premultiplyAlpha", this.source.url.length > 0 || this.source.urls.length > 0
            ? false : this.premultiplyAlpha);
        setNumber(output, "unpackAlignment", 4);
        if (!isEmptyTable(this._userData)) output.set("userData", this._userData);
        if (!isRootObject) meta!.textures.set(this.uuid, output);
        return output;
    }

    /// The JSON of the image: the source's { uuid, url } (DataTexture
    /// writes its texels when it has no url), or null when there is
    /// nothing to write (a canvas, an artboard, an image without a known
    /// url).
    imageToJSON(): Dynamic? {
        return this.source.toJSON();
    }

    /// Whether getView() is a float (rgba16float) texture (internal: mip
    /// chains keep its format).
    get isHDRSource(): bool { return false; }

    /// Mip levels getView() has of its own (compressed textures; 1 else).
    get mipLevelCount(): u32 { return 1; }

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
            // (Bind groups made over the old view hold it while they live.)
            const old = this.cachedView;
            if (old != null) old.release();
            this.cachedView = image.view();
            this.cachedFor = image;
            this.cachedW = image.width;
            this.cachedH = image.height;
        }
        return this.cachedView;
    }

    /// Frees GPU resources the renderers made for this texture (at their
    /// next render): dispatches "dispose", as three.js.
    dispose(): void {
        const view = this.cachedView;
        if (view != null) view.release();
        this.cachedView = null;
        this.cachedFor = null;
        this.cachedW = 0;
        this.cachedH = 0;
        if (this.hasListeners("dispose")) this.dispatchEvent(new Event("dispose"));
    }
}
