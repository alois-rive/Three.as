// three.js examples/jsm/postprocessing/MaskPass.js: MaskPass and
// ClearMaskPass. Between the two, the composer's passes only change what is
// inside the mask scene's silhouette (outside it with `inverse`).
//
// three.js draws the mask into the stencil buffer and stencil-tests later
// passes. Rive's passes keep no stencil from one pass to the next, so here
// MaskPass renders the mask scene in white into a mask texture
// (`maskTarget`, the composer's size), and EffectComposer draws each masked
// pass's previous content back outside it (see EffectComposer.render).

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget, RenderTargetOptions } from "../../renderers/RenderTarget";
import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { MeshBasicMaterial } from "../../materials/MeshBasicMaterial";
import { Material } from "../../materials/Material";
import { ColorOrTexture } from "../../core/ColorOrTexture";
import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { Scene } from "../../scenes/Scene";
import { Color } from "../../math/Color";
import { Texture } from "../../textures/Texture";
import { HalfFloatType } from "../../constants";
import { ShaderDefinition, emptyTexture } from "../shaders/PostShaders";
import { Pass } from "./Pass";

/// The composer's mask composite (three/shaders/post/mask.wgsl): draws
/// tDiffuse where tMask is not covered (covered, with inverse).
class MaskCompositeShaderDefinition extends ShaderDefinition {
    constructor() { super("MaskCompositeShader", "three/shaders/post/mask"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("inverse", new Uniform<f64>(0));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("tMask", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

export const MaskCompositeShader: ShaderDefinition = new MaskCompositeShaderDefinition();

export class MaskPass extends Pass {
    readonly isMaskPass: bool = true;
    scene: Object3D;
    camera: Camera;
    /// Mask outside the scene's silhouette instead of inside.
    inverse: bool = false;
    /// The mask: the scene in white over black (made at the composer's size).
    maskTarget: RenderTarget;
    private maskMaterial: MeshBasicMaterial = new MeshBasicMaterial({ color: 0xffffff });
    private _oldClearColor: Color = new Color();

    constructor(scene: Object3D, camera: Camera) {
        super();
        this.scene = scene;
        this.camera = camera;
        this.clear = true;
        this.needsSwap = false;
        const o = new RenderTargetOptions();
        o.type = HalfFloatType;
        this.maskTarget = new RenderTarget(1, 1, o);
        this.maskMaterial.toneMapped = false;
        this.maskMaterial.fog = false;
    }

    override setSize(width: f64, height: f64): void {
        this.maskTarget.setSize(<u32>Math.max(1, width), <u32>Math.max(1, height));
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        // The silhouette only: no background, every object white.
        let oldOverride: Material? = null;
        let oldBackground: ColorOrTexture? = null;
        const scene = this.scene;
        if (scene instanceof Scene) {
            const s = scene as Scene;
            oldOverride = s.overrideMaterial;
            oldBackground = s.background;
            s.overrideMaterial = this.maskMaterial;
            s.background = null;
        }
        renderer.getClearColor(this._oldClearColor);
        const oldAlpha = renderer.getClearAlpha();
        const oldAutoClear = renderer.autoClear;
        renderer.setClearColor<u32>(0x000000, 0);
        renderer.autoClear = this.clear;
        renderer.setRenderTarget(this.maskTarget);
        renderer.render(scene, this.camera);
        renderer.autoClear = oldAutoClear;
        renderer.setClearColor<Color>(this._oldClearColor, oldAlpha);
        if (scene instanceof Scene) {
            const s = scene as Scene;
            s.overrideMaterial = oldOverride;
            s.background = oldBackground;
        }
    }

    override dispose(): void {
        this.maskTarget.dispose();
        this.maskMaterial.dispose();
    }
}

export class ClearMaskPass extends Pass {
    readonly isClearMaskPass: bool = true;

    constructor() {
        super();
        this.needsSwap = false;
    }

    /// Nothing to draw: the composer ends the mask after this pass.
    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {}
}
