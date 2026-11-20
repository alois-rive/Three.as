// three.js examples/jsm/postprocessing/RenderPixelatedPass.js: renders the
// scene at 1 / pixelSize resolution (with a depth texture) and its normals
// (MeshNormalMaterial), then draws it back up, darkening depth edges and
// lightening normal edges. It renders the scene itself: use it in place of
// a RenderPass.
//
//     composer.addPass(new RenderPixelatedPass(6, scene, camera));

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget, RenderTargetOptions } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { MeshNormalMaterial } from "../../materials/MeshNormalMaterial";
import { Material } from "../../materials/Material";
import { Texture } from "../../textures/Texture";
import { DepthTexture } from "../../textures/DepthTexture";
import { Scene } from "../../scenes/Scene";
import { ColorOrTexture } from "../../core/ColorOrTexture";
import { Camera } from "../../cameras/Camera";
import { Vector2 } from "../../math/Vector2";
import { Vector4 } from "../../math/Vector4";
import { HalfFloatType, NearestFilter } from "../../constants";
import { ShaderDefinition, emptyTexture } from "../shaders/PostShaders";
import { Pass, FullScreenQuad } from "./Pass";

class PixelatedShaderDefinition extends ShaderDefinition {
    constructor() { super("RenderPixelatedShader", "three/shaders/post/pixelated"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("tDepth", new Uniform<Texture>(new DepthTexture()));
        m.set("tNormal", new Uniform<Texture>(emptyTexture()));
        m.set("resolution", new Uniform<Vector4>(new Vector4(1, 1, 1, 1)));
        m.set("normalEdgeStrength", new Uniform<f64>(0));
        m.set("depthEdgeStrength", new Uniform<f64>(0));
        return m;
    }
}

const PixelatedShader: ShaderDefinition = new PixelatedShaderDefinition();

/// RenderPixelatedPass's options.
export class RenderPixelatedPassOptions {
    normalEdgeStrength: f64 = 0.3;
    depthEdgeStrength: f64 = 0.4;
}

export class RenderPixelatedPass extends Pass {
    pixelSize: f64;
    resolution: Vector2 = new Vector2();
    renderResolution: Vector2 = new Vector2();
    pixelatedMaterial: ShaderMaterial;
    normalMaterial: MeshNormalMaterial = new MeshNormalMaterial();
    scene: Scene;
    camera: Camera;
    normalEdgeStrength: f64;
    depthEdgeStrength: f64;
    beautyRenderTarget: RenderTarget;
    normalRenderTarget: RenderTarget;
    private fsQuad: FullScreenQuad;

    constructor(pixelSize: f64, scene: Scene, camera: Camera, options: RenderPixelatedPassOptions? = null) {
        super();
        this.pixelSize = pixelSize;
        this.pixelatedMaterial = this.createPixelatedMaterial();
        this.fsQuad = new FullScreenQuad(this.pixelatedMaterial);
        this.scene = scene;
        this.camera = camera;
        const o = options != null ? options! : new RenderPixelatedPassOptions();
        this.normalEdgeStrength = o.normalEdgeStrength;
        this.depthEdgeStrength = o.depthEdgeStrength;

        const beauty = new RenderTargetOptions();
        beauty.type = HalfFloatType;
        beauty.depthTexture = new DepthTexture();
        this.beautyRenderTarget = new RenderTarget(1, 1, beauty);
        this.beautyRenderTarget.texture.minFilter = NearestFilter;
        this.beautyRenderTarget.texture.magFilter = NearestFilter;
        const normal = new RenderTargetOptions();
        normal.type = HalfFloatType;
        this.normalRenderTarget = new RenderTarget(1, 1, normal);
        this.normalRenderTarget.texture.minFilter = NearestFilter;
        this.normalRenderTarget.texture.magFilter = NearestFilter;
    }

    override dispose(): void {
        this.beautyRenderTarget.dispose();
        this.normalRenderTarget.dispose();
        this.pixelatedMaterial.dispose();
        this.normalMaterial.dispose();
        this.fsQuad.dispose();
    }

    override setSize(width: f64, height: f64): void {
        this.resolution.set(width, height);
        const x = Math.max(1, Math.floor(width / this.pixelSize));
        const y = Math.max(1, Math.floor(height / this.pixelSize));
        this.renderResolution.set(x, y);
        this.beautyRenderTarget.setSize(<u32>x, <u32>y);
        this.normalRenderTarget.setSize(<u32>x, <u32>y);
        (this.pixelatedMaterial.uniforms.get("resolution") as Uniform<Vector4>).value.set(x, y, 1 / x, 1 / y);
    }

    setPixelSize(pixelSize: f64): void {
        this.pixelSize = pixelSize;
        this.setSize(this.resolution.x, this.resolution.y);
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        const uniforms = this.pixelatedMaterial.uniforms;
        (uniforms.get("normalEdgeStrength") as Uniform<f64>).value = this.normalEdgeStrength;
        (uniforms.get("depthEdgeStrength") as Uniform<f64>).value = this.depthEdgeStrength;

        renderer.setRenderTarget(this.beautyRenderTarget);
        renderer.render(this.scene, this.camera);

        const overrideMaterialOld: Material? = this.scene.overrideMaterial;
        const backgroundOld: ColorOrTexture? = this.scene.background;
        renderer.setRenderTarget(this.normalRenderTarget);
        this.scene.overrideMaterial = this.normalMaterial;
        this.scene.background = null;
        renderer.render(this.scene, this.camera);
        this.scene.overrideMaterial = overrideMaterialOld;
        this.scene.background = backgroundOld;

        (uniforms.get("tDiffuse") as Uniform<Texture>).value = this.beautyRenderTarget.texture;
        (uniforms.get("tDepth") as Uniform<Texture>).value = this.beautyRenderTarget.depthTexture!;
        (uniforms.get("tNormal") as Uniform<Texture>).value = this.normalRenderTarget.texture;

        if (this.renderToScreen) {
            renderer.setRenderTarget(null);
        } else {
            renderer.setRenderTarget(writeBuffer);
            if (this.clear) renderer.clear();
        }
        this.fsQuad.render(renderer);
    }

    createPixelatedMaterial(): ShaderMaterial {
        return PixelatedShader.createMaterial();
    }
}
