// three.js PMREMGenerator, as a shim: three.js prefilters an environment
// into a GGX-convolved mip chain; here the renderer samples the
// equirectangular texture's own mip chain by roughness, so
// fromEquirectangular only prepares the texture (mapping, mipmaps).
// fromScene / fromCubemap are not ported.

import { GPURenderer } from "../renderers/GPURenderer";
import { Texture } from "../textures/Texture";
import { EquirectangularReflectionMapping, LinearMipmapLinearFilter, RepeatWrapping } from "../constants";

/// What three.js returns (a render target): `.texture` is the environment.
export class PMREMResult {
    texture: Texture;

    constructor(texture: Texture) {
        this.texture = texture;
    }

    dispose(): void {}
}

export class PMREMGenerator {
    renderer: GPURenderer?;

    constructor(renderer: GPURenderer? = null) {
        this.renderer = renderer;
    }

    fromEquirectangular(equirectangular: Texture): PMREMResult {
        equirectangular.mapping = EquirectangularReflectionMapping;
        equirectangular.generateMipmaps = true;
        equirectangular.minFilter = LinearMipmapLinearFilter;
        equirectangular.wrapS = RepeatWrapping;
        return new PMREMResult(equirectangular);
    }

    compileEquirectangularShader(): void {}
    compileCubemapShader(): void {}
    dispose(): void {}
}
