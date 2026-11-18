// three.js CubeTextureLoader over Rive image assets: `load(names)` takes the
// six image asset names (+x, -x, +y, -y, +z, -z; no extensions) and returns
// a CubeTexture that samples once they have decoded. `setPath` prefixes
// every name.

import { Context } from "rive/host";
import { Image } from "rive/image";
import { CubeTexture } from "../textures/CubeTexture";

export class CubeTextureLoader {
    context: Context;
    path: string = "";

    constructor(context: Context) {
        this.context = context;
    }

    setPath(path: string): CubeTextureLoader {
        this.path = path;
        return this;
    }

    load(names: Array<string>): CubeTexture {
        const images: Array<Image?> = [];
        for (let i = 0; i < 6; i++) {
            const name = i < names.length ? this.path + names[i] : "";
            const image = name.length > 0 ? this.context.image(name) : null;
            if (image == null) this.context.log("three: CubeTextureLoader: no image asset named '" + name + "'");
            images.push(image);
        }
        const texture = new CubeTexture(images);
        texture.name = names.length > 0 ? names[0] : "";
        return texture;
    }
}
