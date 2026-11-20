// three.js PMREMGenerator. The renderer prefilters every environment
// (scene.environment, Standard/Physical envMaps and blurred backgrounds)
// into a GGX mip chain on its own, as three.js does for scene.environment,
// so fromEquirectangular / fromCubemap return their texture prepared.
// fromScene renders a scene into a cube map with a CubeCamera, at the start
// of the renderer's next render (scripts render only from draw()).

import { GPURenderer, SceneCapture } from "../renderers/GPURenderer";
import { Texture } from "../textures/Texture";
import { CubeTexture } from "../textures/CubeTexture";
import { Object3D } from "../core/Object3D";
import { CubeCamera } from "../cameras/CubeCamera";
import { WebGLCubeRenderTarget } from "../renderers/WebGLCubeRenderTarget";
import { Event } from "../core/EventDispatcher";
import { PMREM_DISPOSE_EVENT } from "../renderers/gpu/Disposal";
import { EquirectangularReflectionMapping, LinearMipmapLinearFilter, RepeatWrapping } from "../constants";

/// What three.js returns (a render target): `.texture` is the environment.
export class PMREMResult {
    texture: Texture;
    private cubeTarget: WebGLCubeRenderTarget? = null;

    constructor(texture: Texture, cubeTarget: WebGLCubeRenderTarget? = null) {
        this.texture = texture;
        this.cubeTarget = cubeTarget;
    }

    /// Frees the prefiltered environment, as three.js: fromScene's cube
    /// target, or the renderers' PMREM of fromEquirectangular's /
    /// fromCubemap's texture (the texture itself stays; used as an
    /// environment again, it is prefiltered again).
    dispose(): void {
        const t = this.cubeTarget;
        if (t != null) t.dispose();
        else if (this.texture.hasListeners(PMREM_DISPOSE_EVENT)) this.texture.dispatchEvent(new Event(PMREM_DISPOSE_EVENT));
    }
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

    fromCubemap(cubemap: CubeTexture): PMREMResult {
        cubemap.generateMipmaps = true;
        cubemap.minFilter = LinearMipmapLinearFilter;
        return new PMREMResult(cubemap);
    }

    /// The environment `scene` makes around `position` (the origin by
    /// default): a 256 cube map rendered at the next render. `sigma` (a
    /// pre-blur in radians) is not applied.
    fromScene(scene: Object3D, sigma: f64 = 0, near: f64 = 0.1, far: f64 = 100): PMREMResult {
        const target = new WebGLCubeRenderTarget(256);
        const camera = new CubeCamera(near, far, target);
        const r = this.renderer;
        if (r != null) r.queueSceneCapture(new SceneCapture(scene, camera));
        return new PMREMResult(target.texture, target);
    }

    compileEquirectangularShader(): void {}
    compileCubemapShader(): void {}
    dispose(): void {}
}
