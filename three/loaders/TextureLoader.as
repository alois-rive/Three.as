// three.js TextureLoader, over Rive image assets: `load(name)` returns a
// Texture of the ImageAsset called `name` (no extension). The image may
// still be decoding (on the web, until after init); it samples once ready.
// Returns a texture with no image when the asset does not exist.

import { Context } from "rive/host";
import { Texture } from "../textures/Texture";

export class TextureLoader {
    context: Context;

    constructor(context: Context) {
        this.context = context;
    }

    load(name: string): Texture {
        const texture = new Texture(this.context.image(name));
        texture.name = name;
        if (texture.image == null) this.context.log("three: TextureLoader: no image asset named '" + name + "'");
        return texture;
    }
}
