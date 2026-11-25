// three.js CubeTexture: six faces (+x, -x, +y, -y, +z, -z). The renderer
// converts it on the GPU into an equirectangular, linear HDR texture
// (redone when a face or `version` changes) and samples that, so cube
// maps work wherever equirectangular ones do (scene.background,
// scene.environment, envMap).

import { Context } from "rive/host";
import { Image } from "rive/image";
import { GPUTextureView } from "rive/gpu";
import { Texture } from "./Texture";
import { CubeReflectionMapping, SRGBColorSpace } from "../constants";

export class CubeTexture extends Texture {
    readonly isCubeTexture: bool = true;
    /// The six face images, in three.js's order.
    images: Array<Image?>;
    /// The faces as textures (internal; a cube render target's faces are
    /// its render target textures).
    faces: Array<Texture> = [];
    private ownedFaces: Array<Texture> = [];
    /// Image cube maps are mirrored in x (three.js's flipEnvMap); faces
    /// rendered by a CubeCamera are not, and their rows run bottom up.
    flipX: bool = true;
    flipRows: bool = false;

    constructor(images: Array<Image?>? = null, mapping: i32 = CubeReflectionMapping) {
        super(null);
        this.images = images != null ? images! : [null, null, null, null, null, null];
        this.mapping = mapping;
        this.flipY = false;
        this.colorSpace = SRGBColorSpace;
        this.premultiplyAlpha = true;   // Rive images are premultiplied
        for (let i = 0; i < 6; i++) {
            const t = new Texture(null);
            this.faces.push(t);
            this.ownedFaces.push(t);
        }
    }

    /// Face `i` as a texture, following `images`.
    faceTexture(i: i32): Texture {
        const face = this.faces[i];
        if (i < this.images.length) {
            const image = this.images[i];
            if (face.image !== image) {
                face.image = image;
                this.version++;
            }
        }
        return face;
    }

    override get width(): u32 { return this.faceTexture(0).width; }
    override get height(): u32 { return this.faceTexture(0).height; }

    override update(context: Context): void {
        for (let i = 0; i < 6; i++) this.faceTexture(i).update(context);
    }

    /// Cube textures are sampled through their equirectangular conversion
    /// (see GPUTextures); this has no single view.
    override getView(): GPUTextureView? { return null; }

    /// Whether every face has something to sample.
    get ready(): bool {
        for (let i = 0; i < 6; i++) if (this.faceTexture(i).getView() == null) return false;
        return true;
    }

    override dispose(): void {
        for (let i = 0; i < this.ownedFaces.length; i++) this.ownedFaces[i].dispose();
        super.dispose();
    }
}
