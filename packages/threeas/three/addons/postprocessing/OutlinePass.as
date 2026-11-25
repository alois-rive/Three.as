// three.js examples/jsm/postprocessing/OutlinePass.js: outlines the selected
// objects (their meshes), in visibleEdgeColor where seen and hiddenEdgeColor
// where other objects hide them, with edgeStrength, edgeThickness, edgeGlow,
// pulsePeriod (seconds) and an optional patternTexture inside them. The same
// stages as three.js: the non-selected objects' depth, the selection's mask
// tested against it, a half resolution edge detection, two blurs and an
// additive overlay onto the read buffer.
//
//     const outline = new OutlinePass(new Vector2(w, h), scene, camera, [mesh]);
//     outline.visibleEdgeColor.set(0xffaa00);
//     composer.addPass(outline);
//
// The stage materials live in three/shaders/post/outline_*.wgsl. The
// depth of the non-selected objects is a DepthTexture; the mask material
// reads it at its own pixel (three.js projects with textureMatrix, still
// computed here). Skinned and morphed selections are drawn in their rest
// pose; instanced meshes are drawn with their instances.

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget, RenderTargetOptions } from "../../renderers/RenderTarget";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Material } from "../../materials/Material";
import { MeshDepthMaterial } from "../../materials/MeshDepthMaterial";
import { Texture } from "../../textures/Texture";
import { DepthTexture } from "../../textures/DepthTexture";
import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { Scene } from "../../scenes/Scene";
import { ColorOrTexture } from "../../core/ColorOrTexture";
import { Mesh } from "../../objects/Mesh";
import { Sprite } from "../../objects/Sprite";
import { Points } from "../../objects/Points";
import { Line } from "../../objects/Line";
import { Color } from "../../math/Color";
import { Vector2 } from "../../math/Vector2";
import { Matrix4 } from "../../math/Matrix4";
import { HalfFloatType, DoubleSide, NoBlending, AdditiveBlending } from "../../constants";
import { ShaderDefinition, CopyShader, emptyTexture } from "../shaders/PostShaders";
import { Pass, FullScreenQuad } from "./Pass";

// MAX_EDGE_THICKNESS and MAX_EDGE_GLOW are both 4 (outline_blur.wgsl's
// MAX_RADIUS).
const MAX_EDGE_GLOW: f64 = 4;

class PrepareMaskDefinition extends ShaderDefinition {
    constructor() { super("OutlinePass.prepareMask", "three/shaders/post/outline_mask"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("depthTexture", new Uniform<Texture>(new DepthTexture(1, 1)));
        m.set("cameraNearFar", new Uniform<Vector2>(new Vector2(0.5, 0.5)));
        m.set("perspective", new Uniform<f64>(1));
        return m;
    }
}

class EdgeDetectionDefinition extends ShaderDefinition {
    constructor() { super("OutlinePass.edgeDetection", "three/shaders/post/outline_edge"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("maskTexture", new Uniform<Texture>(emptyTexture()));
        m.set("texSize", new Uniform<Vector2>(new Vector2(0.5, 0.5)));
        m.set("visibleEdgeColor", new Uniform<Color>(new Color(1, 1, 1)));
        m.set("hiddenEdgeColor", new Uniform<Color>(new Color(1, 1, 1)));
        return m;
    }
}

class SeperableBlurDefinition extends ShaderDefinition {
    constructor() { super("OutlinePass.separableBlur", "three/shaders/post/outline_blur"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("colorTexture", new Uniform<Texture>(emptyTexture()));
        m.set("texSize", new Uniform<Vector2>(new Vector2(0.5, 0.5)));
        m.set("direction", new Uniform<Vector2>(new Vector2(0.5, 0.5)));
        m.set("kernelRadius", new Uniform<f64>(1.0));
        return m;
    }
}

class OverlayDefinition extends ShaderDefinition {
    constructor() { super("OutlinePass.overlay", "three/shaders/post/outline_overlay"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("maskTexture", new Uniform<Texture>(emptyTexture()));
        m.set("edgeTexture1", new Uniform<Texture>(emptyTexture()));
        m.set("edgeTexture2", new Uniform<Texture>(emptyTexture()));
        m.set("patternTexture", new Uniform<Texture>(emptyTexture()));
        m.set("edgeStrength", new Uniform<f64>(1.0));
        m.set("edgeGlow", new Uniform<f64>(1.0));
        m.set("usePatternTexture", new Uniform<f64>(0.0));
        return m;
    }
}

const _prepareMask = new PrepareMaskDefinition();
const _edgeDetection = new EdgeDetectionDefinition();
const _separableBlur = new SeperableBlurDefinition();
const _overlay = new OverlayDefinition();

function halfTarget(width: u32, height: u32, depth: bool): RenderTarget {
    const o = new RenderTargetOptions();
    o.type = HalfFloatType;
    if (depth) o.depthTexture = new DepthTexture(width, height);
    const rt = new RenderTarget(max<u32>(1, width), max<u32>(1, height), o);
    rt.texture.generateMipmaps = false;
    return rt;
}

function u<T>(m: ShaderMaterial, name: string): Uniform<T> {
    return m.uniforms.get(name) as Uniform<T>;
}

function isOrtho(c: Camera): bool { return c instanceof OrthographicCamera; }

function half(v: u32): u32 { return <u32>Math.max(1, Math.round(<f64>v / 2)); }

export class OutlinePass extends Pass {
    renderScene: Object3D;
    renderCamera: Camera;
    selectedObjects: Array<Object3D>;
    visibleEdgeColor: Color = new Color(1, 1, 1);
    hiddenEdgeColor: Color = new Color(0.1, 0.04, 0.02);
    edgeGlow: f64 = 0.0;
    usePatternTexture: bool = false;
    patternTexture: Texture? = null;
    edgeThickness: f64 = 1.0;
    edgeStrength: f64 = 3.0;
    downSampleRatio: f64 = 2;
    /// Seconds per pulse (0: no pulse).
    pulsePeriod: f64 = 0;
    resolution: Vector2;
    textureMatrix: Matrix4 = new Matrix4();

    renderTargetMaskBuffer: RenderTarget;
    renderTargetDepthBuffer: RenderTarget;
    renderTargetMaskDownSampleBuffer: RenderTarget;
    renderTargetBlurBuffer1: RenderTarget;
    renderTargetBlurBuffer2: RenderTarget;
    renderTargetEdgeBuffer1: RenderTarget;
    renderTargetEdgeBuffer2: RenderTarget;
    depthMaterial: MeshDepthMaterial = new MeshDepthMaterial();
    prepareMaskMaterial: ShaderMaterial;
    edgeDetectionMaterial: ShaderMaterial;
    /// The blurs: three.js reuses one material per resolution for both
    /// directions; here each direction has its own (a material's uniforms
    /// are uploaded once per render).
    separableBlurMaterial1: ShaderMaterial;
    separableBlurMaterial1Y: ShaderMaterial;
    separableBlurMaterial2: ShaderMaterial;
    separableBlurMaterial2Y: ShaderMaterial;
    overlayMaterial: ShaderMaterial;
    materialCopy: ShaderMaterial;
    private materialScreenCopy: ShaderMaterial;
    private fsQuad: FullScreenQuad = new FullScreenQuad();
    private _oldClearColor: Color = new Color();
    private oldClearAlpha: f64 = 1;
    private tempPulseColor1: Color = new Color();
    private tempPulseColor2: Color = new Color();
    private time: f64 = 0;
    // Meshes under the selected objects (by id), and saved visibilities.
    private _selectionCache: Map<i32, bool> = new Map<i32, bool>();
    private _selectedMeshes: Array<Object3D> = [];
    private _visibilityCache: Map<i32, bool> = new Map<i32, bool>();
    private _stack: Array<Object3D> = [];

    static BlurDirectionX: Vector2 = new Vector2(1.0, 0.0);
    static BlurDirectionY: Vector2 = new Vector2(0.0, 1.0);

    constructor(resolution: Vector2?, scene: Object3D, camera: Camera, selectedObjects: Array<Object3D> = []) {
        super();
        this.renderScene = scene;
        this.renderCamera = camera;
        this.selectedObjects = selectedObjects;
        this.resolution = resolution != null ? new Vector2(resolution.x, resolution.y) : new Vector2(256, 256);
        const rx = <u32>Math.max(1, this.resolution.x), ry = <u32>Math.max(1, this.resolution.y);
        const resx = <u32>Math.max(1, Math.round(this.resolution.x / this.downSampleRatio));
        const resy = <u32>Math.max(1, Math.round(this.resolution.y / this.downSampleRatio));
        this.renderTargetMaskBuffer = halfTarget(rx, ry, false);
        this.renderTargetMaskBuffer.texture.name = "OutlinePass.mask";
        this.depthMaterial.side = DoubleSide;
        this.depthMaterial.blending = NoBlending;
        this.prepareMaskMaterial = _prepareMask.createMaterial();
        this.prepareMaskMaterial.side = DoubleSide;
        this.prepareMaskMaterial.depthTest = true;
        this.prepareMaskMaterial.depthWrite = true;
        this.renderTargetDepthBuffer = halfTarget(rx, ry, true);
        this.renderTargetDepthBuffer.texture.name = "OutlinePass.depth";
        this.renderTargetMaskDownSampleBuffer = halfTarget(resx, resy, false);
        this.renderTargetMaskDownSampleBuffer.texture.name = "OutlinePass.depthDownSample";
        this.renderTargetBlurBuffer1 = halfTarget(resx, resy, false);
        this.renderTargetBlurBuffer1.texture.name = "OutlinePass.blur1";
        this.renderTargetBlurBuffer2 = halfTarget(half(resx), half(resy), false);
        this.renderTargetBlurBuffer2.texture.name = "OutlinePass.blur2";
        this.edgeDetectionMaterial = _edgeDetection.createMaterial();
        this.renderTargetEdgeBuffer1 = halfTarget(resx, resy, false);
        this.renderTargetEdgeBuffer1.texture.name = "OutlinePass.edge1";
        this.renderTargetEdgeBuffer2 = halfTarget(half(resx), half(resy), false);
        this.renderTargetEdgeBuffer2.texture.name = "OutlinePass.edge2";
        this.separableBlurMaterial1 = _separableBlur.createMaterial();
        this.separableBlurMaterial1Y = _separableBlur.createMaterial();
        this.separableBlurMaterial2 = _separableBlur.createMaterial();
        this.separableBlurMaterial2Y = _separableBlur.createMaterial();
        this.setBlurSizes(<f64>resx, <f64>resy);
        u<f64>(this.separableBlurMaterial1, "kernelRadius").value = 1;
        u<f64>(this.separableBlurMaterial2, "kernelRadius").value = MAX_EDGE_GLOW;
        u<f64>(this.separableBlurMaterial2Y, "kernelRadius").value = MAX_EDGE_GLOW;
        this.overlayMaterial = _overlay.createMaterial();
        this.overlayMaterial.blending = AdditiveBlending;
        this.overlayMaterial.transparent = true;
        this.materialCopy = CopyShader.createMaterial();
        this.materialScreenCopy = CopyShader.createMaterial();
        this.needsSwap = false;
    }

    private setBlurSizes(resx: f64, resy: f64): void {
        u<Vector2>(this.separableBlurMaterial1, "texSize").value.set(resx, resy);
        u<Vector2>(this.separableBlurMaterial1Y, "texSize").value.set(resx, resy);
        const hx = Math.round(resx / 2), hy = Math.round(resy / 2);
        u<Vector2>(this.separableBlurMaterial2, "texSize").value.set(hx, hy);
        u<Vector2>(this.separableBlurMaterial2Y, "texSize").value.set(hx, hy);
    }

    override dispose(): void {
        this.renderTargetMaskBuffer.dispose();
        this.renderTargetDepthBuffer.dispose();
        this.renderTargetMaskDownSampleBuffer.dispose();
        this.renderTargetBlurBuffer1.dispose();
        this.renderTargetBlurBuffer2.dispose();
        this.renderTargetEdgeBuffer1.dispose();
        this.renderTargetEdgeBuffer2.dispose();
        this.depthMaterial.dispose();
        this.prepareMaskMaterial.dispose();
        this.edgeDetectionMaterial.dispose();
        this.separableBlurMaterial1.dispose();
        this.separableBlurMaterial1Y.dispose();
        this.separableBlurMaterial2.dispose();
        this.separableBlurMaterial2Y.dispose();
        this.overlayMaterial.dispose();
        this.materialCopy.dispose();
        this.materialScreenCopy.dispose();
        this.fsQuad.dispose();
    }

    override setSize(width: f64, height: f64): void {
        const w = <u32>Math.max(1, width), h = <u32>Math.max(1, height);
        this.renderTargetMaskBuffer.setSize(w, h);
        this.renderTargetDepthBuffer.setSize(w, h);
        let resx = Math.max(1, Math.round(width / this.downSampleRatio));
        let resy = Math.max(1, Math.round(height / this.downSampleRatio));
        this.renderTargetMaskDownSampleBuffer.setSize(<u32>resx, <u32>resy);
        this.renderTargetBlurBuffer1.setSize(<u32>resx, <u32>resy);
        this.renderTargetEdgeBuffer1.setSize(<u32>resx, <u32>resy);
        this.setBlurSizes(resx, resy);
        resx = Math.max(1, Math.round(resx / 2));
        resy = Math.max(1, Math.round(resy / 2));
        this.renderTargetBlurBuffer2.setSize(<u32>resx, <u32>resy);
        this.renderTargetEdgeBuffer2.setSize(<u32>resx, <u32>resy);
    }

    /// The meshes under the selected objects.
    updateSelectionCache(): void {
        const cache = this._selectionCache;
        cache.clear();
        this._selectedMeshes.length = 0;
        const stack = this._stack;
        for (let i = 0; i < this.selectedObjects.length; i++) {
            stack.length = 0;
            stack.push(this.selectedObjects[i]);
            while (stack.length > 0) {
                const o = stack.pop();
                if (o instanceof Mesh && !cache.has(o.id)) {
                    cache.set(o.id, true);
                    this._selectedMeshes.push(o);
                }
                for (let k = 0; k < o.children.length; k++) stack.push(o.children[k]);
            }
        }
    }

    changeVisibilityOfSelectedObjects(bVisible: bool): void {
        const cache = this._visibilityCache;
        for (let i = 0; i < this._selectedMeshes.length; i++) {
            const mesh = this._selectedMeshes[i];
            if (bVisible) {
                if (cache.has(mesh.id)) mesh.visible = cache.get(mesh.id);
            } else {
                cache.set(mesh.id, mesh.visible);
                mesh.visible = bVisible;
            }
        }
    }

    changeVisibilityOfNonSelectedObjects(bVisible: bool): void {
        const visibilityCache = this._visibilityCache;
        const selectionCache = this._selectionCache;
        const stack = this._stack;
        stack.length = 0;
        stack.push(this.renderScene);
        while (stack.length > 0) {
            const object = stack.pop();
            if (object instanceof Mesh || object instanceof Sprite) {
                // Only meshes and sprites are outlined.
                if (!selectionCache.has(object.id)) {
                    const visibility = object.visible;
                    if (!bVisible || (visibilityCache.has(object.id) && visibilityCache.get(object.id))) {
                        object.visible = bVisible;
                    }
                    visibilityCache.set(object.id, visibility);
                }
            } else if (object instanceof Points || object instanceof Line) {
                // Points and lines are hidden so they do not affect the outline.
                if (bVisible) {
                    if (visibilityCache.has(object.id)) object.visible = visibilityCache.get(object.id);
                } else {
                    visibilityCache.set(object.id, object.visible);
                    object.visible = bVisible;
                }
            }
            for (let k = 0; k < object.children.length; k++) stack.push(object.children[k]);
        }
    }

    updateTextureMatrix(): void {
        this.textureMatrix.set(0.5, 0.0, 0.0, 0.5,
            0.0, 0.5, 0.0, 0.5,
            0.0, 0.0, 0.5, 0.5,
            0.0, 0.0, 0.0, 1.0);
        this.textureMatrix.multiply(this.renderCamera.projectionMatrix);
        this.textureMatrix.multiply(this.renderCamera.matrixWorldInverse);
    }

    private quad(renderer: GPURenderer, material: ShaderMaterial, target: RenderTarget?): void {
        this.fsQuad.material = material;
        renderer.setRenderTarget(target);
        this.fsQuad.render(renderer);
    }

    override render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
            maskActive: bool): void {
        this.time += deltaTime;
        if (this.selectedObjects.length > 0) {
            renderer.getClearColor(this._oldClearColor);
            this.oldClearAlpha = renderer.getClearAlpha();
            const oldAutoClear = renderer.autoClear;
            renderer.autoClear = true;
            renderer.setClearColor<u32>(0xffffff, 1);
            this.updateSelectionCache();
            const scene = this.renderScene;
            const isScene = scene instanceof Scene;

            // Make the selected objects invisible.
            this.changeVisibilityOfSelectedObjects(false);
            let currentBackground: ColorOrTexture? = null;
            let currentOverrideMaterial: Material? = null;
            if (isScene) {
                currentBackground = (scene as Scene).background;
                currentOverrideMaterial = (scene as Scene).overrideMaterial;
                (scene as Scene).background = null;
            }

            // 1. The non-selected objects into the depth buffer.
            if (isScene) (scene as Scene).overrideMaterial = this.depthMaterial;
            renderer.setRenderTarget(this.renderTargetDepthBuffer);
            renderer.render(scene, this.renderCamera);

            // Make the selected objects visible.
            this.changeVisibilityOfSelectedObjects(true);
            this._visibilityCache.clear();
            this.updateTextureMatrix();

            // Only the selected objects, tested against that depth.
            this.changeVisibilityOfNonSelectedObjects(false);
            const cam = this.renderCamera;
            const near = cam instanceof PerspectiveCamera ? (cam as PerspectiveCamera).near
                : cam instanceof OrthographicCamera ? (cam as OrthographicCamera).near : 0.1;
            const far = cam instanceof PerspectiveCamera ? (cam as PerspectiveCamera).far
                : cam instanceof OrthographicCamera ? (cam as OrthographicCamera).far : 2000;
            const pm = this.prepareMaskMaterial;
            u<Vector2>(pm, "cameraNearFar").value.set(near, far);
            u<f64>(pm, "perspective").value = isOrtho(cam) ? 0 : 1;
            u<Texture>(pm, "depthTexture").value = this.renderTargetDepthBuffer.depthTexture!;
            if (isScene) (scene as Scene).overrideMaterial = pm;
            renderer.setRenderTarget(this.renderTargetMaskBuffer);
            renderer.render(scene, this.renderCamera);
            if (isScene) (scene as Scene).overrideMaterial = currentOverrideMaterial;
            this.changeVisibilityOfNonSelectedObjects(true);
            this._visibilityCache.clear();
            this._selectionCache.clear();
            this._selectedMeshes.length = 0;
            if (isScene) (scene as Scene).background = currentBackground;

            // 2. Downsample to half resolution.
            u<Texture>(this.materialCopy, "tDiffuse").value = this.renderTargetMaskBuffer.texture;
            this.quad(renderer, this.materialCopy, this.renderTargetMaskDownSampleBuffer);

            this.tempPulseColor1.copy(this.visibleEdgeColor);
            this.tempPulseColor2.copy(this.hiddenEdgeColor);
            if (this.pulsePeriod > 0) {
                // three.js: cos(performance.now() * 0.01 / pulsePeriod), in ms.
                const scalar = (1 + 0.25) / 2 + Math.cos(this.time * 1000 * 0.01 / this.pulsePeriod) * (1.0 - 0.25) / 2;
                this.tempPulseColor1.multiplyScalar(scalar);
                this.tempPulseColor2.multiplyScalar(scalar);
            }

            // 3. Edge detection.
            const ed = this.edgeDetectionMaterial;
            u<Texture>(ed, "maskTexture").value = this.renderTargetMaskDownSampleBuffer.texture;
            u<Vector2>(ed, "texSize").value.set(<f64>this.renderTargetMaskDownSampleBuffer.width,
                <f64>this.renderTargetMaskDownSampleBuffer.height);
            u<Color>(ed, "visibleEdgeColor").value.copy(this.tempPulseColor1);
            u<Color>(ed, "hiddenEdgeColor").value.copy(this.tempPulseColor2);
            this.quad(renderer, ed, this.renderTargetEdgeBuffer1);

            // 4. Blur at half resolution...
            const b1 = this.separableBlurMaterial1, b1y = this.separableBlurMaterial1Y;
            u<Texture>(b1, "colorTexture").value = this.renderTargetEdgeBuffer1.texture;
            u<Vector2>(b1, "direction").value.copy(OutlinePass.BlurDirectionX);
            u<f64>(b1, "kernelRadius").value = this.edgeThickness;
            this.quad(renderer, b1, this.renderTargetBlurBuffer1);
            u<Texture>(b1y, "colorTexture").value = this.renderTargetBlurBuffer1.texture;
            u<Vector2>(b1y, "direction").value.copy(OutlinePass.BlurDirectionY);
            u<f64>(b1y, "kernelRadius").value = this.edgeThickness;
            this.quad(renderer, b1y, this.renderTargetEdgeBuffer1);

            // ... and at quarter resolution.
            const b2 = this.separableBlurMaterial2, b2y = this.separableBlurMaterial2Y;
            u<Texture>(b2, "colorTexture").value = this.renderTargetEdgeBuffer1.texture;
            u<Vector2>(b2, "direction").value.copy(OutlinePass.BlurDirectionX);
            this.quad(renderer, b2, this.renderTargetBlurBuffer2);
            u<Texture>(b2y, "colorTexture").value = this.renderTargetBlurBuffer2.texture;
            u<Vector2>(b2y, "direction").value.copy(OutlinePass.BlurDirectionY);
            this.quad(renderer, b2y, this.renderTargetEdgeBuffer2);

            // Blend additively over the input.
            const ov = this.overlayMaterial;
            u<Texture>(ov, "maskTexture").value = this.renderTargetMaskBuffer.texture;
            u<Texture>(ov, "edgeTexture1").value = this.renderTargetEdgeBuffer1.texture;
            u<Texture>(ov, "edgeTexture2").value = this.renderTargetEdgeBuffer2.texture;
            const pattern = this.patternTexture;
            u<Texture>(ov, "patternTexture").value = pattern != null ? pattern! : emptyTexture();
            u<f64>(ov, "edgeStrength").value = this.edgeStrength;
            u<f64>(ov, "edgeGlow").value = this.edgeGlow;
            u<f64>(ov, "usePatternTexture").value = this.usePatternTexture && pattern != null ? 1 : 0;
            renderer.autoClear = false;
            this.quad(renderer, ov, readBuffer);

            renderer.setClearColor<Color>(this._oldClearColor, this.oldClearAlpha);
            renderer.autoClear = oldAutoClear;
        }
        if (this.renderToScreen) {
            u<Texture>(this.materialScreenCopy, "tDiffuse").value = readBuffer.texture;
            this.quad(renderer, this.materialScreenCopy, null);
        }
    }
}
