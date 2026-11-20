// three.js TextureLoader, over Rive: `load(name)` returns a Texture of the
// ImageAsset called `name` (no extension). The image may still be decoding
// (on the web, until after init); it samples once ready. Returns a texture
// with no image when the asset does not exist.
//
// `loadAsync(url)` also fetches an https: url (or reads the blob asset of
// that name) and decodes it: it resolves with the texture once its pixels
// are in.

import { Context, DecodedImage, ImageDecodeListener } from "rive/host";
import { Promise } from "rive/promise";
import { Texture } from "../textures/Texture";
import { DataTexture } from "../textures/DataTexture";
import { Loader } from "./Loader";
import { LoadingManager } from "./LoadingManager";
import { LoaderUtils } from "./LoaderUtils";
import { fetchBytes } from "./FileLoader";
import { LinearFilter, LinearMipmapLinearFilter, SRGBColorSpace } from "../constants";

/// Fills a texture when its image decodes, and settles a promise.
export class TextureDecodeListener extends ImageDecodeListener {
    texture: DataTexture;
    promise: Promise<Texture> = new Promise<Texture>();

    constructor(texture: DataTexture) {
        super();
        this.texture = texture;
    }

    override onImageDecoded(image: DecodedImage): void {
        const t = this.texture;
        t.data = Uint8Array.wrap(image.data);
        t.dataWidth = image.width;
        t.dataHeight = image.height;
        t.needsUpdate = true;
        this.promise.resolve(t);
        removePending(this);
    }

    override onImageDecodeFailed(message: string): void {
        this.promise.reject(message);
        removePending(this);
    }
}

// Decodes in flight (kept alive until they report).
const pending: Array<TextureDecodeListener> = [];

function removePending(l: TextureDecodeListener): void {
    const i = pending.indexOf(l);
    if (i >= 0) pending.splice(i, 1);
}

/// A texture for encoded image bytes (PNG, JPEG, WebP), filled when they
/// decode: three.js's image-backed texture, as a DataTexture.
export function decodeTexture(context: Context, bytes: ArrayBuffer, flipY: bool): TextureDecodeListener {
    const texture = new DataTexture(new Uint8Array(0), 0, 0);
    texture.flipY = flipY;
    texture.premultiplyAlpha = true;   // decoded images are premultiplied
    texture.generateMipmaps = true;
    texture.magFilter = LinearFilter;
    texture.minFilter = LinearMipmapLinearFilter;
    const listener = new TextureDecodeListener(texture);
    pending.push(listener);
    context.decodeImage(bytes, listener);
    return listener;
}

export class TextureLoader extends Loader {
    constructor(context: Context, manager: LoadingManager? = null) {
        super(context, manager);
    }

    load(name: string): Texture {
        const context = this.context!;
        const texture = new Texture(context.image(this.path + name));
        texture.name = name;
        texture.source.url = this.path + name;
        texture.colorSpace = SRGBColorSpace;
        if (texture.image == null) context.log("three: TextureLoader: no image asset named '" + this.path + name + "'");
        return texture;
    }

    /// The image at `url` (an https: url, else a blob asset's encoded bytes;
    /// an image asset's name resolves at once).
    loadAsync(url: string): Promise<Texture> {
        return loadTextureAsync(this, url);
    }
}

async function loadTextureAsync(loader: TextureLoader, url: string): Promise<Texture> {
    const context = loader.context!;
    const resolved = LoaderUtils.resolveURL(url, loader.path);
    if (!LoaderUtils.isURL(resolved) && context.image(resolved) != null) return loader.load(url);
    const bytes = await fetchBytes(loader, url);
    const texture = await decodeTexture(context, bytes, true).promise;
    texture.name = url;
    texture.source.url = resolved;
    texture.colorSpace = SRGBColorSpace;
    return texture;
}
